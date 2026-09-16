{{
  config(
    materialized = 'view'
  )
}}

-- One current row per order line.
--
-- Insert-only in practice, so FINAL rarely has anything to collapse. It stays
-- because "rarely" is not "never": a re-delivered Kafka message produces a
-- second copy, and a model that is correct only while nothing goes wrong is
-- not correct.

with source as (

    select *
    from {{ source('cdc', 'order_items') }} final
    where is_deleted = 0

)

select
    order_item_id,
    order_id,
    product_id,

    quantity,

    -- The price at the time of sale, copied into the line rather than joined
    -- from the catalogue. Joining would make last year's revenue change when
    -- someone edits a price today.
    unit_price,
    quantity * unit_price                      as line_total,

    source_lsn,
    source_ts

from source
