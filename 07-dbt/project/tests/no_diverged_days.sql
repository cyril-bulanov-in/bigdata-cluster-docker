-- A singular test: any row it returns is a failure.
--
-- Written as a test file rather than a schema.yml entry because the packaged
-- generic tests that would express this (dbt_utils.expression_is_true) need
-- dbt_utils, and a single assertion is not worth a dependency — packages have
-- to be fetched, pinned and kept in step with dbt-core.
--
-- ---------------------------------------------------------------------------
--  Why this warns rather than errors
-- ---------------------------------------------------------------------------
--  Capture runs a second or two behind the source, and the three counts in
--  recon_orders_by_source are taken at slightly different moments, so the
--  most recent day is almost always a little short. Erroring on that means a
--  red build on every run, and within a week a test nobody reads.
--
--  In production this would exclude the current day and error on everything
--  older. Here it warns, because the platform is started and stopped
--  constantly and a day that was half-captured before a shutdown stays
--  half-captured for ever — a real gap, caused by the stand rather than by a
--  defect worth failing a build over.
-- ---------------------------------------------------------------------------

{{ config(severity = 'warn') }}

select
    order_date,
    pg_orders,
    cdc_orders,
    cdc_minus_pg,
    verdict

from {{ ref('recon_orders_by_source') }}

where verdict = 'DIVERGED'
  -- Today is still being written to by the generator while this runs.
  and order_date < today()
