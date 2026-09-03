-- ============================================================================
--  Ingestion: Kafka topics into the staging tables, with no extra service
-- ============================================================================
--  Applied with `make ch-ingest`. Every statement is ON CLUSTER.
--
--  Three objects per source table:
--
--    <name>_queue   ENGINE = Kafka. A consumer dressed as a table. Reading
--                   from it consumes messages, which is why nobody ever
--                   SELECTs from it directly.
--    <name>_mv      A materialized view: an insert trigger. Every batch the
--                   queue reads is passed through its SELECT and inserted
--                   into the target.
--    <name>         the Distributed table from 10-staging.sql — the target.
--
--  ---------------------------------------------------------------------------
--  Why the view writes to the Distributed table and not to the local one
--  ---------------------------------------------------------------------------
--  Writing locally would be faster: no second network hop. It would also be
--  wrong.
--
--  Every node runs a consumer, and Kafka hands each one an arbitrary subset
--  of partitions. A row would therefore land on whichever node happened to
--  read it — not on the shard its sharding key points to. Two versions of the
--  same order, read by two different nodes, would end up on two different
--  shards, and ReplacingMergeTree would never collapse them: deduplication is
--  per shard.
--
--  Inserting through the Distributed table costs a hop and routes every
--  version of a row to the same shard. Correctness first.
--
--  ---------------------------------------------------------------------------
--  Where the consumer starts reading
--  ---------------------------------------------------------------------------
--  Nothing to configure: ClickHouse sets auto.offset.reset = earliest itself
--  when it builds the librdkafka configuration, so a group with no committed
--  offset reads the topic from the beginning. There is no table-level setting
--  for this; kafka_auto_offset_reset does not exist and is rejected with
--  UNKNOWN_SETTING.
--
--  If it ever needs overriding, it goes in the server configuration, not here:
--
--      <clickhouse>
--        <kafka>
--          <auto_offset_reset>latest</auto_offset_reset>
--        </kafka>
--      </clickhouse>
--
--  librdkafka property names use underscores in place of dots there.
--
--  Worth knowing because the failure it would cause is invisible: a consumer
--  starting at the end of a topic subscribes, polls, reports no error and
--  reads nothing, while system.kafka_consumers shows healthy consumers and a
--  recent last_poll. Reading zero from a topic that has a backlog looks
--  exactly like reading zero from an idle topic.
--
--  ---------------------------------------------------------------------------
--  What Debezium actually sends, and why conversions are needed
--  ---------------------------------------------------------------------------
--  A message from cdc.public.orders looks like this:
--
--    {"order_id":4513,"customer_id":1746,"status":"paid",
--     "total_amount":"529.03",
--     "created_at":"2026-09-01T16:14:45.546085Z",
--     "updated_at":"2026-09-02T01:19:51.166173Z",
--     "__deleted":"false","__op":"u","__source_lsn":135118808,
--     "__source_ts_ms":1788311991166,"__table":"orders"}
--
--  Three fields are not the type they look like:
--
--    total_amount is a STRING. That is decimal.handling.mode = string in the
--    connector, chosen so the value stays exact and readable. The default
--    sends base64 bytes plus a scale.
--
--    created_at and updated_at are ISO-8601 STRINGS with microseconds and a
--    trailing Z. Postgres timestamptz maps to Debezium's ZonedTimestamp,
--    which is always a string — time.precision.mode does not change that; it
--    only affects timestamps without a time zone.
--
--    __deleted is the STRING "true" or "false", not a boolean.
--
--  So the queue table declares them as they arrive, and the view converts.
-- ============================================================================


-- ============================================================================
--  orders
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.orders_queue ON CLUSTER platform
(
    order_id        Int64,
    customer_id     Int64,
    status          String,
    -- String, not Decimal: see the note above.
    total_amount    String,
    created_at      String,
    updated_at      String,
    -- Backticks because the identifiers begin with underscores. These are the
    -- columns ExtractNewRecordState adds to the flattened row.
    `__op`          String,
    `__deleted`     String,
    `__source_lsn`  UInt64,
    `__source_ts_ms` Int64,
    `__table`       String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka-1:9092,kafka-2:9092,kafka-3:9092,kafka-4:9092',
    kafka_topic_list = 'cdc.public.orders',
    -- One consumer group per table. Every ClickHouse node joins the same
    -- group, so Kafka divides the six partitions between them; with eight
    -- nodes two will sit idle, which costs nothing.
    kafka_group_name = 'clickhouse-orders',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1,
    -- Tolerate fields we did not declare. Adding a column to the source table
    -- then makes Debezium send one more field, and ingestion keeps working.
    input_format_skip_unknown_fields = 1,
    -- Deliberately zero: a message ClickHouse cannot parse halts the stream
    -- instead of being silently dropped. On a stand, loud beats lossy. In
    -- production this is where a dead-letter topic belongs.
    kafka_skip_broken_messages = 0;


CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.orders_mv ON CLUSTER platform
TO analytics.orders
AS SELECT
    order_id,
    customer_id,
    status,
    -- The string "529.03" into an exact Decimal, with no float in between.
    toDecimal64(total_amount, 2)                        AS total_amount,
    -- BestEffort because the string carries microseconds and a Z suffix;
    -- the plain parser wants an exact format.
    parseDateTime64BestEffort(created_at, 3, 'UTC')     AS created_at,
    parseDateTime64BestEffort(updated_at, 3, 'UTC')     AS updated_at,
    `__op`                                              AS op,
    -- The version column: the write-ahead log position, monotonic per
    -- database, produced by Postgres itself.
    `__source_lsn`                                      AS source_lsn,
    fromUnixTimestamp64Milli(`__source_ts_ms`, 'UTC')   AS source_ts,
    -- "true" / "false" as text into the UInt8 the engine requires.
    if(`__deleted` = 'true', 1, 0)                      AS is_deleted
FROM analytics.orders_queue;


-- ============================================================================
--  order_items
-- ============================================================================
--  No timestamps in the source table at all, so none arrive.
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.order_items_queue ON CLUSTER platform
(
    order_item_id   Int64,
    order_id        Int64,
    product_id      Int64,
    quantity        Int32,
    unit_price      String,
    `__op`          String,
    `__deleted`     String,
    `__source_lsn`  UInt64,
    `__source_ts_ms` Int64,
    `__table`       String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka-1:9092,kafka-2:9092,kafka-3:9092,kafka-4:9092',
    kafka_topic_list = 'cdc.public.order_items',
    kafka_group_name = 'clickhouse-order-items',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1,
    input_format_skip_unknown_fields = 1,
    kafka_skip_broken_messages = 0;


CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.order_items_mv ON CLUSTER platform
TO analytics.order_items
AS SELECT
    order_item_id,
    order_id,
    product_id,
    quantity,
    toDecimal64(unit_price, 2)                          AS unit_price,
    `__op`                                              AS op,
    `__source_lsn`                                      AS source_lsn,
    fromUnixTimestamp64Milli(`__source_ts_ms`, 'UTC')   AS source_ts,
    if(`__deleted` = 'true', 1, 0)                      AS is_deleted
FROM analytics.order_items_queue;


-- ============================================================================
--  customers
-- ============================================================================
--  The table deletes happen on. A delete event arrives with every column
--  populated, because REPLICA IDENTITY FULL is set on the source — without it
--  there would be a customer_id and nothing else to store.
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.customers_queue ON CLUSTER platform
(
    customer_id     Int64,
    email           String,
    full_name       String,
    country_code    String,
    created_at      String,
    updated_at      String,
    `__op`          String,
    `__deleted`     String,
    `__source_lsn`  UInt64,
    `__source_ts_ms` Int64,
    `__table`       String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka-1:9092,kafka-2:9092,kafka-3:9092,kafka-4:9092',
    kafka_topic_list = 'cdc.public.customers',
    kafka_group_name = 'clickhouse-customers',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1,
    input_format_skip_unknown_fields = 1,
    kafka_skip_broken_messages = 0;


CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.customers_mv ON CLUSTER platform
TO analytics.customers
AS SELECT
    customer_id,
    email,
    full_name,
    country_code,
    parseDateTime64BestEffort(created_at, 3, 'UTC')     AS created_at,
    parseDateTime64BestEffort(updated_at, 3, 'UTC')     AS updated_at,
    `__op`                                              AS op,
    `__source_lsn`                                      AS source_lsn,
    fromUnixTimestamp64Milli(`__source_ts_ms`, 'UTC')   AS source_ts,
    if(`__deleted` = 'true', 1, 0)                      AS is_deleted
FROM analytics.customers_queue;


-- ============================================================================
--  products
-- ============================================================================
--  is_active is a real JSON boolean here, not a string — Debezium maps a
--  Postgres boolean straight through. Bool in the queue table, UInt8 in
--  storage.
-- ============================================================================

CREATE TABLE IF NOT EXISTS analytics.products_queue ON CLUSTER platform
(
    product_id      Int64,
    sku             String,
    name            String,
    category        String,
    price           String,
    is_active       Bool,
    updated_at      String,
    `__op`          String,
    `__deleted`     String,
    `__source_lsn`  UInt64,
    `__source_ts_ms` Int64,
    `__table`       String
)
ENGINE = Kafka
SETTINGS
    kafka_broker_list = 'kafka-1:9092,kafka-2:9092,kafka-3:9092,kafka-4:9092',
    kafka_topic_list = 'cdc.public.products',
    kafka_group_name = 'clickhouse-products',
    kafka_format = 'JSONEachRow',
    kafka_num_consumers = 1,
    input_format_skip_unknown_fields = 1,
    kafka_skip_broken_messages = 0;


CREATE MATERIALIZED VIEW IF NOT EXISTS analytics.products_mv ON CLUSTER platform
TO analytics.products
AS SELECT
    product_id,
    sku,
    name,
    category,
    toDecimal64(price, 2)                               AS price,
    toUInt8(is_active)                                  AS is_active,
    parseDateTime64BestEffort(updated_at, 3, 'UTC')     AS updated_at,
    `__op`                                              AS op,
    `__source_lsn`                                      AS source_lsn,
    fromUnixTimestamp64Milli(`__source_ts_ms`, 'UTC')   AS source_ts,
    if(`__deleted` = 'true', 1, 0)                      AS is_deleted
FROM analytics.products_queue;
