{{
  config(
    materialized = 'view'
  )
}}

-- Customers read straight out of Postgres.
--
-- The interesting one for reconciliation. Customers are the table the
-- generator deletes from, so this and the CDC copy can legitimately disagree
-- for a moment — and a disagreement that persists means a delete event was
-- lost, which is the failure mode change capture is least likely to report.

select
    customer_id,
    email,
    full_name,
    country_code,
    created_at,
    updated_at

from {{ postgres_source('customers') }}
