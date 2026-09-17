{{
  config(
    materialized = 'view'
  )
}}

-- Orders read straight out of Postgres, bypassing change capture entirely.
--
-- This is the control. Everything else in the warehouse arrived through
-- Debezium, Kafka and a materialized view; if any link in that chain drops
-- rows, nothing downstream can tell, because every downstream number comes
-- from the same chain.
--
-- Reading the source directly is the only way to answer "is the warehouse
-- still a faithful copy" — and it is a question that goes unasked on most
-- projects precisely because it needs a second connection nobody set up.
--
-- Every query here hits the operational database. Deliberately a view of a
-- narrow projection rather than select *, and used only by the scheduled
-- reconciliation models.

select
    order_id,
    customer_id,
    status,
    total_amount,
    created_at,
    updated_at

from {{ postgres_source('orders') }}
