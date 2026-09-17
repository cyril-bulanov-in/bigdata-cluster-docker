{{
  config(
    materialized = 'view'
  )
}}

-- Orders as Spark wrote them to object storage.
--
-- The same orders that arrive through change capture, but by a different
-- route: ClickHouse exported a day to s3://raw/, Spark shaped it and wrote
-- s3://staged/, and this reads that back. Two paths to the same facts, which
-- is what makes them worth comparing — see the reconciliation models.
--
-- Reading files rather than a table, so this is slower than anything else in
-- the project and belongs behind a scheduled model, not in a dashboard.

with files as (

    select
        *,
        -- ------------------------------------------------------------------
        --  The partition column ClickHouse does not give you
        -- ------------------------------------------------------------------
        --  Spark derives `dt` from the dt=<value>/ directory name and hands
        --  it back as a column. ClickHouse does not: the s3 function reads
        --  what is inside the files and nothing about where they sit.
        --
        --  Recovering it from _path is therefore not a nicety. Without this
        --  the model returns every partition merged into one undated heap,
        --  which looks like working data right up until someone filters on a
        --  date and gets nothing.
        -- ------------------------------------------------------------------
        {{ partition_date_from_path() }} as dt

    from {{ s3_source(
             env_var('S3_BUCKET_STAGED', 'staged'),
             'orders/dt=*/*.parquet'
           ) }}

)

select
    order_id,
    customer_id,

    status,
    is_cancelled,
    is_complete,

    total_amount,

    created_at,
    updated_at,
    order_date,
    order_hour,
    age_seconds,

    dt,

    -- When Spark produced this row, as distinct from when the order was
    -- placed. The gap between staged_at and updated_at is how far behind the
    -- batch path runs.
    staged_at

from files
