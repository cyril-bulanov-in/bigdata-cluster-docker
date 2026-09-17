{{
  config(
    materialized = 'table',
    order_by = '(country_code, customer_id)'
  )
}}

-- One row per customer: what they have bought, and when they last did.
--
-- The model that makes the dependency graph a tree rather than a list. It
-- joins three staging models and is read by nothing, which is what a leaf of
-- a dimensional model looks like — the shape `dbt docs` is worth generating
-- for.
--
-- Also the first model here whose grain is not a date. Everything else is per
-- day; this is per customer, which means a re-run recomputes history rather
-- than appending to it. Fine at this size, and the reason it is a table
-- rebuilt wholesale rather than an incremental model: incremental would be
-- faster and would need a rule for what to do when an old order changes
-- status, which is a decision worth making deliberately rather than by
-- default.

with customers as (

    select
        c.customer_id   as customer_id,
        c.country_code  as country_code,
        c.signup_date   as signup_date
    from {{ ref('stg_customers') }} as c

),

orders as (

    select
        o.customer_id   as customer_id,
        o.order_id      as order_id,
        o.order_date    as order_date,
        o.total_amount  as total_amount,
        o.is_cancelled  as is_cancelled,
        o.is_complete   as is_complete
    from {{ ref('stg_orders') }} as o

),

items as (

    select
        i.order_id      as order_id,
        i.quantity      as quantity
    from {{ ref('stg_order_items') }} as i

),

items_per_order as (

    select
        order_id        as order_id,
        sum(quantity)   as items
    from items
    group by order_id

)

select
    c.customer_id                                   as customer_id,
    c.country_code                                  as country_code,
    c.signup_date                                   as signup_date,

    count(o.order_id)                               as orders_placed,

    -- Counted separately rather than as a share, because a customer with one
    -- cancelled order out of one is not the same story as fifty out of a
    -- hundred, and a percentage renders both as 100 and 50 with no way back.
    sum(o.is_cancelled)                             as orders_cancelled,
    sum(o.is_complete)                              as orders_completed,

    -- Cancelled orders excluded from money, included in counts above. The
    -- distinction matters: they are real events and not real revenue.
    sum(if(o.is_cancelled = 0, o.total_amount, 0))  as lifetime_value,
    sum(if(o.is_cancelled = 0, ipo.items, 0))       as items_bought,

    min(o.order_date)                               as first_order_date,
    max(o.order_date)                               as last_order_date,

    -- Null for a customer who has never ordered, rather than zero. Zero would
    -- read as "ordered today" in every subsequent comparison.
    if(count(o.order_id) > 0,
       dateDiff('day', max(o.order_date), today()),
       null)                                        as days_since_last_order,

    now()                                           as computed_at

-- A left join, so customers who have never ordered appear with zeros. An
-- inner join would silently answer a different question — "what have our
-- buyers bought" rather than "what have our customers bought" — and the two
-- differ by exactly the group most worth looking at.
from customers as c
left join orders          as o   on o.customer_id = c.customer_id
left join items_per_order as ipo on ipo.order_id  = o.order_id

group by customer_id, country_code, signup_date
