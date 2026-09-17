{{
  config(
    materialized = 'table'
  )
}}

-- Does the warehouse still match the source it claims to mirror?
--
-- Three routes carry the same orders into three places:
--
--   Postgres    the operational database, read live
--   ClickHouse  the CDC staging layer, via Debezium and Kafka
--   S3          Parquet, via an export job and Spark
--
-- Every dashboard in this platform reads the middle one. If change capture
-- drops rows, every one of those dashboards is wrong in the same direction at
-- once, and none of them can tell — because they all come from the same chain.
--
-- This model is the only thing here that compares the chain against its
-- source. It is also the reason dbt was given three sources rather than one:
-- on most projects this question goes unasked precisely because answering it
-- needs a second connection nobody set up.
--
-- A gap of a few rows is normal and expected. Capture runs a second or two
-- behind, and the counts are taken at slightly different moments. A gap that
-- persists across runs, or grows, is not.

with pg as (

    select
        toDate(created_at)  as order_date,
        count()             as pg_orders,
        sum(total_amount)   as pg_revenue
    from {{ ref('stg_pg_orders') }}
    group by order_date

),

warehouse as (

    select
        order_date          as order_date,
        count()             as cdc_orders,
        sum(total_amount)   as cdc_revenue
    from {{ ref('stg_orders') }}
    group by order_date

),

lake as (

    -- Only the days Spark has actually processed. Object storage holds
    -- whatever was exported, which is normally a subset — so a null here
    -- means "not exported yet", not "missing".
    select
        order_date          as order_date,
        count()             as s3_orders,
        sum(total_amount)   as s3_revenue
    from {{ ref('stg_s3_orders') }}
    group by order_date

),

days as (

    select order_date from pg
    union distinct
    select order_date from warehouse
    union distinct
    select order_date from lake

)

-- ---------------------------------------------------------------------------
--  Every column is aliased, including the ones that look like they need no
--  alias
-- ---------------------------------------------------------------------------
--  `select d.order_date` does not produce a column called order_date here.
--  ClickHouse's analyzer keeps the qualifier, so the result carries a column
--  literally named `d.order_date`, and anything referring to order_date
--  afterwards fails with
--
--      Unknown expression identifier `order_date`
--
--  The model builds perfectly — it is the tests and every downstream query
--  that break, which makes it look like the tests are wrong rather than the
--  naming. Aliasing each one costs a word and removes the whole class.
-- ---------------------------------------------------------------------------
select
    d.order_date        as order_date,

    pg.pg_orders        as pg_orders,
    w.cdc_orders        as cdc_orders,
    l.s3_orders         as s3_orders,

    -- Signed on purpose. Which direction the discrepancy runs matters:
    -- the warehouse holding fewer rows than the source means capture is
    -- behind or lossy; holding more means something is duplicated, which is a
    -- different and worse problem.
    toInt64(w.cdc_orders) - toInt64(pg.pg_orders)   as cdc_minus_pg,

    pg.pg_revenue       as pg_revenue,
    w.cdc_revenue       as cdc_revenue,
    l.s3_revenue        as s3_revenue,
    w.cdc_revenue - pg.pg_revenue                    as revenue_gap,

    -- A verdict, so a dashboard or an alert can filter on one column instead
    -- of re-deriving the rule. The threshold is a count, not a percentage:
    -- on a quiet day two missing rows out of ten matter more than two out of
    -- ten thousand, and a percentage would hide exactly that.
    multiIf(
        pg.pg_orders is null,                                   'not in source',
        w.cdc_orders is null,                                    'missing from warehouse',
        w.cdc_orders = pg.pg_orders,                             'exact',
        abs(toInt64(w.cdc_orders) - toInt64(pg.pg_orders)) <= 5, 'within tolerance',
                                                                 'DIVERGED'
    )                                                as verdict,

    now()                                            as checked_at

from days d
left join pg        as pg on pg.order_date = d.order_date
left join warehouse as w  on w.order_date  = d.order_date
left join lake      as l  on l.order_date  = d.order_date
order by order_date desc
