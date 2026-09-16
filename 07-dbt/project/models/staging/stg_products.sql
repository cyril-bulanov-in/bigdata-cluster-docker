{{
  config(
    materialized = 'view'
  )
}}

-- One current row per product.
--
-- A small dimension updated in place, so FINAL matters more here than
-- anywhere else relative to the table's size: a product whose price has
-- changed twenty times is twenty rows, and there are only a few hundred
-- products.

with source as (

    select *
    from {{ source('cdc', 'products') }} final
    where is_deleted = 0

)

select
    product_id,

    sku,
    name                                       as product_name,
    category,

    price                                      as current_price,
    is_active,

    updated_at,

    source_lsn,
    source_ts

from source
