-- ============================================================================
--  Staging layer: the shape Debezium delivers, stored as ClickHouse sees it
-- ============================================================================
--  Applied with `make ch-schema`. Every statement is ON CLUSTER, so it goes
--  into the DDL queue in Keeper and every node picks it up.
--
--  Two tables per source table, and the naming matters:
--
--    <name>_local    ReplicatedReplacingMergeTree — where rows actually live.
--                    One copy per shard, replicated inside the shard.
--    <name>          Distributed — holds nothing, routes reads and writes to
--                    the local tables. This is the one you query.
--
--  ---------------------------------------------------------------------------
--  How the deduplication works, and what it demands of the schema
--  ---------------------------------------------------------------------------
--  Change capture delivers a row again on every update, and again on delete.
--  ReplacingMergeTree keeps only the row with the highest version for each
--  ORDER BY key, and drops rows flagged is_deleted when reading with FINAL.
--
--  That machinery has two hard constraints, and both shape the DDL below:
--
--  1. Deduplication happens within one shard.
--     If two versions of the same row land on different shards, nothing ever
--     collapses them. The sharding key is therefore always the primary key of
--     the source table — never a timestamp, never a hash of the whole row.
--
--  2. Deduplication happens within one partition.
--     If two versions land in different partitions, same problem. So the
--     partitioning expression must use a column that never changes. created_at
--     qualifies. updated_at does not: an update would move the new version
--     into a different partition and the old one would survive forever.
--
--  ---------------------------------------------------------------------------
--  The version column
--  ---------------------------------------------------------------------------
--  source_lsn, the write-ahead log position Debezium attaches to every event.
--  It is monotonic per database and produced by Postgres itself.
--
--  updated_at would have been the obvious choice and is the wrong one: it is
--  set by application code, which can forget to touch it, set it in the wrong
--  timezone, or write two updates inside the same millisecond. The log
--  position cannot lie about ordering, because ordering is what it is.
-- ============================================================================


-- ============================================================================
--  orders
-- ============================================================================
--  The interesting one. Every order arrives at least twice — an insert, then
--  an update setting the total — and again on each status change. Several
--  versions per row is the normal case here, not an edge case.
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.orders_local ON CLUSTER platform
(
    order_id      Int64,
    customer_id   Int64,
    -- LowCardinality pays off from a handful of distinct values upward: the
    -- column is stored as a dictionary plus small integers.
    status        LowCardinality(String),
    total_amount  Decimal(12, 2),
    created_at    DateTime64(3, 'UTC'),
    updated_at    DateTime64(3, 'UTC'),

    -- ---- what Debezium adds ------------------------------------------------
    -- c = create, u = update, d = delete, r = read (from the initial snapshot)
    op            LowCardinality(String),
    -- The version. See the note above on why this and not updated_at.
    source_lsn    UInt64,
    source_ts     DateTime64(3, 'UTC'),
    -- The delete marker. Must be UInt8: it is an engine parameter, not an
    -- ordinary column, and ClickHouse checks the type.
    is_deleted    UInt8 DEFAULT 0,

    -- When this row reached the warehouse. Useful for measuring end-to-end
    -- latency against source_ts, and for telling a backfill from live traffic.
    ingested_at   DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplicatedReplacingMergeTree(
    -- The path in Keeper. {shard} comes from the macros file, so the two
    -- nodes of a shard produce the same path and become replicas of each
    -- other; nodes in different shards produce different paths and never
    -- exchange data.
    '/clickhouse/tables/{shard}/orders_local',
    -- Who this replica is, within that path. Must be unique per shard.
    '{replica}',
    source_lsn,
    is_deleted
)
-- created_at never changes for an order, so every version of a row lands in
-- the same partition and can be collapsed.
PARTITION BY toYYYYMM(created_at)
-- The deduplication key. One surviving row per order_id.
ORDER BY order_id;


CREATE TABLE IF NOT EXISTS analytics.orders ON CLUSTER platform
AS analytics.orders_local
ENGINE = Distributed(
    'platform',
    'analytics',
    'orders_local',
    -- The sharding key. sipHash64 rather than a plain modulo: order ids are
    -- sequential, and a modulo of sequential ids sends long runs of
    -- consecutive inserts to the same shard.
    --
    -- It is order_id because that is the primary key of the source row. Every
    -- version of an order therefore lands on the same shard, which is the
    -- precondition for ReplacingMergeTree ever collapsing them.
    sipHash64(order_id)
);


-- ============================================================================
--  order_items
-- ============================================================================
--  Insert-only in practice: a line of an order is written once and never
--  touched. ReplacingMergeTree effectively degenerates into a plain append
--  here, which is fine — the uniform shape is worth more than a saved engine.
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.order_items_local ON CLUSTER platform
(
    order_item_id Int64,
    order_id      Int64,
    product_id    Int64,
    quantity      Int32,
    -- Copied from the product at the time of sale, not joined at read time.
    -- The price the customer paid must not change when the catalogue does.
    unit_price    Decimal(12, 2),

    op            LowCardinality(String),
    source_lsn    UInt64,
    source_ts     DateTime64(3, 'UTC'),
    is_deleted    UInt8 DEFAULT 0,
    ingested_at   DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/order_items_local',
    '{replica}',
    source_lsn,
    is_deleted
)
-- No timestamp on this table at all, so partition by a bucket of the id.
-- Immutable, and it keeps parts from growing without bound.
PARTITION BY intDiv(order_id, 1000000)
ORDER BY order_item_id;


CREATE TABLE IF NOT EXISTS analytics.order_items ON CLUSTER platform
AS analytics.order_items_local
ENGINE = Distributed(
    'platform',
    'analytics',
    'order_items_local',
    -- order_id, NOT order_item_id. The items of an order then live on the
    -- same shard as the order itself, and joining them stays local instead of
    -- shipping rows between nodes on every query.
    --
    -- This is the one place in the schema where the sharding key is not the
    -- table's own primary key, and it is deliberate: co-location beats
    -- perfectly even distribution.
    sipHash64(order_id)
);


-- ============================================================================
--  customers
-- ============================================================================
--  The table that gets deleted from. Deletes arrive with is_deleted = 1 and
--  every column filled in — which is what REPLICA IDENTITY FULL on the source
--  buys. Without it a delete would carry the key and nothing else.
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.customers_local ON CLUSTER platform
(
    customer_id   Int64,
    email         String,
    full_name     String,
    country_code  LowCardinality(String),
    created_at    DateTime64(3, 'UTC'),
    updated_at    DateTime64(3, 'UTC'),

    op            LowCardinality(String),
    source_lsn    UInt64,
    source_ts     DateTime64(3, 'UTC'),
    is_deleted    UInt8 DEFAULT 0,
    ingested_at   DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/customers_local',
    '{replica}',
    source_lsn,
    is_deleted
)
PARTITION BY toYYYYMM(created_at)
ORDER BY customer_id;


CREATE TABLE IF NOT EXISTS analytics.customers ON CLUSTER platform
AS analytics.customers_local
ENGINE = Distributed('platform', 'analytics', 'customers_local', sipHash64(customer_id));


-- ============================================================================
--  products
-- ============================================================================
--  A small dimension that is updated in place. Note the absence of
--  PARTITION BY: the only timestamp here is updated_at, and partitioning by a
--  column that changes would scatter the versions of a row across partitions
--  where they could never be collapsed.
--
--  tuple() means one partition for the whole table. Correct for a few hundred
--  rows; it would be wrong for anything large.
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.products_local ON CLUSTER platform
(
    product_id    Int64,
    sku           String,
    name          String,
    category      LowCardinality(String),
    price         Decimal(12, 2),
    is_active     UInt8,
    updated_at    DateTime64(3, 'UTC'),

    op            LowCardinality(String),
    source_lsn    UInt64,
    source_ts     DateTime64(3, 'UTC'),
    is_deleted    UInt8 DEFAULT 0,
    ingested_at   DateTime64(3, 'UTC') DEFAULT now64(3)
)
ENGINE = ReplicatedReplacingMergeTree(
    '/clickhouse/tables/{shard}/products_local',
    '{replica}',
    source_lsn,
    is_deleted
)
PARTITION BY tuple()
ORDER BY product_id;


CREATE TABLE IF NOT EXISTS analytics.products ON CLUSTER platform
AS analytics.products_local
ENGINE = Distributed('platform', 'analytics', 'products_local', sipHash64(product_id));
