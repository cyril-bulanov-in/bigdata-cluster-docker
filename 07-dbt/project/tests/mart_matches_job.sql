-- Does the dbt mart agree with the hand-written job?
--
-- Both compute revenue per day and category from the same source rows:
-- analytics.daily_sales_by_category is written by the job in 04-etl, and
-- marts_marts.daily_sales_by_category by this project.
--
-- Any row returned is a day and category where they disagree.
--
-- ---------------------------------------------------------------------------
--  What "the same day" turns out to mean
-- ---------------------------------------------------------------------------
--  This took three attempts, and each wrong answer was instructive.
--
--  The first version compared every shared day and reported eighteen
--  mismatches. One was real — the job counted cancelled orders as revenue and
--  this project did not — and the job was fixed. The rest were an artefact:
--  the job writes a snapshot of one day when someone runs it, while this
--  model rebuilds every day on every build, so a day still receiving orders
--  reads differently depending on when each was computed.
--
--  The second version restricted the comparison to days before the job's last
--  run, on the theory that a past day has stopped changing. It has not. An
--  order placed on the 14th can be cancelled on the 17th, and cancelling it
--  changes the 14th's revenue. Calendar days close; their data does not.
--
--  So the test is which rows have moved, not which dates have passed: compare
--  a day only if no order belonging to it has been updated since the job
--  computed it. That is exact, and it is the same question a production
--  pipeline has to answer before it can call a partition final.
-- ---------------------------------------------------------------------------

{{ config(severity = 'warn') }}

{% set source_db = env_var('SOURCE_DATABASE', 'analytics') %}

with job as (

    select
        day                 as day,
        category            as category,
        orders              as orders,
        items               as items,
        revenue             as revenue,
        computed_at         as computed_at
    from {{ source_db }}.daily_sales_by_category final

),

-- The most recent change to any order belonging to each day. An order that
-- was placed on a day and cancelled a week later shows up here with the later
-- timestamp, which is exactly the case the previous version of this test
-- mishandled.
last_change as (

    select
        order_date          as day,
        max(updated_at)     as last_changed_at
    from {{ ref('stg_orders') }}
    group by order_date

),

dbt_mart as (

    select
        day                 as day,
        category            as category,
        orders              as orders,
        items               as items,
        revenue             as revenue
    from {{ ref('daily_sales_by_category') }}

)

select
    j.day                   as day,
    j.category              as category,
    j.orders                as job_orders,
    d.orders                as dbt_orders,
    j.revenue               as job_revenue,
    d.revenue               as dbt_revenue,
    j.computed_at           as job_computed_at,
    lc.last_changed_at      as last_changed_at

from job as j
inner join dbt_mart    as d  on d.day  = j.day and d.category = j.category
inner join last_change as lc on lc.day = j.day

-- Only days that had genuinely stopped moving when the job ran. A day whose
-- orders changed afterwards is not a disagreement between the two
-- implementations; it is two photographs taken at different times.
where lc.last_changed_at < j.computed_at

  -- Revenue is a Decimal, so this is exact and not a tolerance. Within a day
  -- that both saw identically, any drift at all means the two definitions
  -- differ — which is the whole point of keeping both.
  and (j.orders  != d.orders
    or j.items   != d.items
    or j.revenue != d.revenue)
