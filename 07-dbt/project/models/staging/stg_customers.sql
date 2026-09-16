{{
  config(
    materialized = 'view'
  )
}}

-- One current row per customer, deleted ones excluded.
--
-- This is the table deletes actually happen on, so the is_deleted filter does
-- real work here rather than being defensive boilerplate.

with source as (

    select *
    from {{ source('cdc', 'customers') }} final
    where is_deleted = 0

)

select
    customer_id,

    email,
    full_name,
    country_code,

    created_at,
    updated_at,
    toDate(created_at)                         as signup_date,

    source_lsn,
    source_ts

from source
