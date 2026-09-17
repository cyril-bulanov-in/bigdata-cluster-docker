{{
  config(
    materialized = 'table',
    order_by = '(day, category)'
  )
}}

-- Revenue per day and category.
--
-- ---------------------------------------------------------------------------
--  The same mart the job in 04-etl computes, written the other way
-- ---------------------------------------------------------------------------
--  That job is still there and still runs. Keeping both is the point: they
--  read the same source rows and must produce the same numbers, so the test
--  in tests/mart_matches_job.sql compares them row by row — a direct check of
--  whether this project reproduces the hand-written pipeline rather than
--  merely resembling it.
--
--  What the two versions do NOT share is everything around the SQL. The job
--  owns its own connection handling, parameter binding, idempotent re-runs,
--  and a read-back that verifies the write. Here all of that is the tool's
--  problem, and the file is the query and nothing else.
--
--  That is the honest comparison between the approaches: not that dbt is
--  shorter, but that the ninety lines of Python around the query were
--  infrastructure rather than logic — and infrastructure is worth having once
--  rather than per job.
-- ---------------------------------------------------------------------------

with items as (

    select
        i.order_id      as order_id,
        i.product_id    as product_id,
        i.quantity      as quantity,
        i.line_total    as line_total
    from {{ ref('stg_order_items') }} as i

),

orders as (

    -- Cancelled orders are excluded, matching the job. An order that was
    -- placed and then cancelled is not revenue, and counting it would make
    -- every total drift upward from the day it was cancelled onward.
    select
        o.order_id      as order_id,
        o.order_date    as order_date
    from {{ ref('stg_orders') }} as o
    where o.is_cancelled = 0

),

products as (

    select
        p.product_id    as product_id,
        p.category      as category
    from {{ ref('stg_products') }} as p

)

select
    o.order_date                    as day,
    p.category                      as category,

    count(distinct i.order_id)      as orders,
    sum(i.quantity)                 as items,
    sum(i.line_total)               as revenue,

    -- Kept so a re-run is traceable. The table is replaced wholesale on every
    -- build, so this is the time the numbers were computed rather than a
    -- version column.
    now()                           as computed_at

from items as i
inner join orders   as o on o.order_id   = i.order_id
inner join products as p on p.product_id = i.product_id

group by day, category
