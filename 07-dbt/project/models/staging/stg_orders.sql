{{
  config(
    materialized = 'view'
  )
}}

-- One current row per order.
--
-- Three things happen here and nothing else: collapse the versions change
-- capture produces, drop the deleted rows, and give the columns names that
-- mean something downstream. No joins, no aggregation, no business rules —
-- those belong in marts, and keeping them out is what makes a staging model
-- safe to rebuild at any time.

with source as (

    -- FINAL is the whole reason this model exists.
    --
    -- The table is a ReplacingMergeTree holding every version of every order:
    -- the insert, the update that set the total, and one row per status
    -- change. Without FINAL a count of orders returns the number of events,
    -- which is a plausible number and the wrong one.
    --
    -- It is expensive — parts are merged at read time — which is exactly why
    -- it is paid once here rather than in every query downstream.
    select *
    from {{ source('cdc', 'orders') }} final
    where is_deleted = 0

)

select
    order_id,
    customer_id,

    status,

    -- ------------------------------------------------------------------
    --  Why the cast, and why it is on the argument rather than the result
    -- ------------------------------------------------------------------
    --  status is LowCardinality(String), which is right for a column with
    --  five distinct values. The problem is what ClickHouse does with it
    --  next: LowCardinality propagates through functions, so
    --
    --      status = 'cancelled'           -> LowCardinality(UInt8)
    --      toUInt8(status = 'cancelled')  -> LowCardinality(UInt8) as well
    --
    --  and materialising that is refused outright:
    --
    --      Creating columns of type LowCardinality(UInt8) is prohibited by
    --      default due to expected negative impact on performance
    --
    --  Which is a fair objection — a dictionary over two values costs more
    --  than the byte it replaces. Wrapping the result in a cast does not
    --  help, because the wrapper is already inside. The cast has to come
    --  first, on the argument, so the comparison never sees a
    --  LowCardinality in the first place.
    -- ------------------------------------------------------------------
    toUInt8(cast(status as String) = 'cancelled')                    as is_cancelled,
    toUInt8(cast(status as String) in ('delivered', 'paid'))         as is_complete,

    total_amount,

    created_at,
    updated_at,
    toDate(created_at)                         as order_date,
    toHour(created_at)                         as order_hour,

    -- Null while the order is still moving, rather than zero. Zero would
    -- average into "no time at all" and quietly pull every statistic down.
    if(updated_at > created_at,
       toUnixTimestamp(updated_at) - toUnixTimestamp(created_at),
       null)                                   as age_seconds,

    -- Kept from the capture layer. source_lsn is how a row here can be traced
    -- back to a position in the source database's write-ahead log, which is
    -- the only way to answer "was this row current as of X".
    source_lsn,
    source_ts

from source
