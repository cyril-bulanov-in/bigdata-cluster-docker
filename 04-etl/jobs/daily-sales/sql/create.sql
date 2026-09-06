-- Created by the job itself, not by a migration step.
--
-- The job is meant to be runnable anywhere with nothing but a ClickHouse
-- address — that is the portability the whole repository is built around. A
-- job that only works after someone remembers to run a separate DDL step is
-- not portable, it is a two-part ritual.
--
-- IF NOT EXISTS everywhere, so running it on every execution costs nothing.

CREATE TABLE IF NOT EXISTS analytics.daily_sales_by_category_local ON CLUSTER platform
(
    day           Date,
    category      LowCardinality(String),
    orders        UInt64,
    items         UInt64,
    revenue       Decimal(18, 2),
    -- The version. Recomputing a day inserts a new row with a later timestamp
    -- and the old one is replaced, so a re-run is idempotent rather than
    -- additive. Without this a backfill would double every number it touched.
    computed_at   DateTime64(3, 'UTC')
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/daily_sales_by_category_local',
    '{replica}',
    computed_at
)
PARTITION BY toYYYYMM(day)
ORDER BY (day, category);


CREATE TABLE IF NOT EXISTS analytics.daily_sales_by_category ON CLUSTER platform
AS analytics.daily_sales_by_category_local
-- Sharded by category rather than by day: a query almost always filters on a
-- date range and groups by category, so spreading categories across shards
-- parallelises the work. Sharding by day would send a single day's whole
-- query to one node.
ENGINE = Distributed('platform', 'analytics', 'daily_sales_by_category_local', sipHash64(category));
