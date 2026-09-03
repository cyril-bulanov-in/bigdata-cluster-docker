-- ============================================================================
--  Tear down the ingestion objects so they can be recreated
-- ============================================================================
--  Used by `make ch-ingest-reset`, never on its own.
--
--  Why this is needed at all: the SETTINGS of a Kafka engine table cannot be
--  changed in place. There is no ALTER for kafka_auto_offset_reset, the group
--  name, the topic list or the format. Changing any of them means dropping
--  the table and creating it again.
--
--  Order matters. The materialized view has to go first: while it exists it
--  holds a dependency on the queue table, and dropping the queue underneath
--  it leaves a view pointing at nothing.
--
--  Nothing in the staging tables is touched. The data already in
--  <name>_local stays exactly where it is; only the consumers are rebuilt.
--
--  One consequence worth knowing: the consumer group keeps its committed
--  offsets in Kafka, and those survive this. A rebuilt queue with
--  kafka_auto_offset_reset = 'earliest' will still resume from the committed
--  offset rather than from the start, because the setting only applies when
--  there is no offset to resume from. To genuinely replay a topic from the
--  beginning, the consumer group has to be deleted too — `make ch-ingest-reset`
--  does that as well.
-- ============================================================================

DROP VIEW IF EXISTS analytics.orders_mv ON CLUSTER platform;
DROP VIEW IF EXISTS analytics.order_items_mv ON CLUSTER platform;
DROP VIEW IF EXISTS analytics.customers_mv ON CLUSTER platform;
DROP VIEW IF EXISTS analytics.products_mv ON CLUSTER platform;

DROP TABLE IF EXISTS analytics.orders_queue ON CLUSTER platform;
DROP TABLE IF EXISTS analytics.order_items_queue ON CLUSTER platform;
DROP TABLE IF EXISTS analytics.customers_queue ON CLUSTER platform;
DROP TABLE IF EXISTS analytics.products_queue ON CLUSTER platform;
