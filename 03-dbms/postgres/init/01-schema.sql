-- ============================================================================
--  Source schema — a small e-commerce OLTP database
-- ============================================================================
--  Runs once, when the postgres-data volume is first created. Changing this
--  file later has no effect on an existing volume; to re-apply it you need
--  `make clean` (which also wipes Kafka, since it is the same Compose project).
--
--  The tables were chosen so that all three kinds of change happen naturally,
--  because change data capture with only inserts demonstrates nothing:
--
--    orders.status      changes constantly    -> a steady stream of UPDATEs
--    products.price     changes occasionally  -> rare UPDATEs on a dimension
--    customers          get deleted           -> DELETEs, the hard case
--    order_items        never change          -> insert-only, for contrast
-- ============================================================================

-- ---------------------------------------------------------------------------
--  customers
-- ---------------------------------------------------------------------------
CREATE TABLE customers (
    customer_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    email         text        NOT NULL UNIQUE,
    full_name     text        NOT NULL,
    country_code  char(2)     NOT NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
--  products
-- ---------------------------------------------------------------------------
CREATE TABLE products (
    product_id  bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    sku         text          NOT NULL UNIQUE,
    name        text          NOT NULL,
    category    text          NOT NULL,
    -- numeric, not float: money in floating point is a bug waiting for a
    -- rounding edge case. Note this becomes Decimal64 in ClickHouse later.
    price       numeric(12,2) NOT NULL CHECK (price > 0),
    is_active   boolean       NOT NULL DEFAULT true,
    updated_at  timestamptz   NOT NULL DEFAULT now()
);

-- ---------------------------------------------------------------------------
--  orders
-- ---------------------------------------------------------------------------
CREATE TABLE orders (
    order_id      bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    customer_id   bigint        NOT NULL REFERENCES customers(customer_id),
    status        text          NOT NULL DEFAULT 'pending'
                    CHECK (status IN ('pending','paid','shipped','delivered','cancelled')),
    total_amount  numeric(12,2) NOT NULL DEFAULT 0,
    created_at    timestamptz   NOT NULL DEFAULT now(),
    updated_at    timestamptz   NOT NULL DEFAULT now()
);

CREATE INDEX orders_customer_idx ON orders (customer_id);
CREATE INDEX orders_status_idx   ON orders (status);

-- ---------------------------------------------------------------------------
--  order_items
-- ---------------------------------------------------------------------------
--  unit_price is copied from the product rather than joined at read time.
--  That is deliberate and it is how real order systems work: the price the
--  customer paid must not change when the catalogue price changes later.
-- ---------------------------------------------------------------------------
CREATE TABLE order_items (
    order_item_id bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    order_id      bigint        NOT NULL REFERENCES orders(order_id) ON DELETE CASCADE,
    product_id    bigint        NOT NULL REFERENCES products(product_id),
    quantity      int           NOT NULL CHECK (quantity > 0),
    unit_price    numeric(12,2) NOT NULL CHECK (unit_price > 0)
);

CREATE INDEX order_items_order_idx ON order_items (order_id);

-- ============================================================================
--  REPLICA IDENTITY — needed later, set now
-- ============================================================================
--  This controls how much of a row Postgres writes into the write-ahead log
--  for UPDATE and DELETE. The default is DEFAULT, which logs only the primary
--  key. That is enough for Postgres's own replication, but not for CDC:
--
--    * a DELETE event would carry only the id, with every other column null,
--      so a downstream consumer could not know what was deleted
--    * an UPDATE event would have no "before" image, so you could not tell
--      which columns actually changed
--
--  FULL logs the entire old row. It costs more WAL volume, which matters on a
--  high-write production table and does not matter at all here.
--
--  Set now rather than during the CDC step on purpose: turning it on later
--  does not retroactively fix events already written to the log, and forgetting
--  it produces deletes that look empty rather than broken. That is a
--  particularly unpleasant thing to debug.
-- ============================================================================
ALTER TABLE customers   REPLICA IDENTITY FULL;
ALTER TABLE products    REPLICA IDENTITY FULL;
ALTER TABLE orders      REPLICA IDENTITY FULL;
ALTER TABLE order_items REPLICA IDENTITY FULL;

-- ============================================================================
--  What is NOT here yet
-- ============================================================================
--  The publication and the replication slot belong to the CDC step and are
--  created there, together with the Debezium connector that consumes them.
--  A slot with no consumer is actively harmful: Postgres retains WAL for it
--  indefinitely and eventually fills the disk.
-- ============================================================================
