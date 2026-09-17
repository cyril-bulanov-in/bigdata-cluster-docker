-- Recompute one day of the mart.
--
-- Idempotent: the target is a ReplacingMergeTree versioned by computed_at, so
-- re-running a day replaces its rows rather than adding to them.

INSERT INTO daily_sales_by_category
SELECT
    toDate(o.created_at)            AS day,
    p.category                      AS category,
    uniqExact(o.order_id)           AS orders,
    sum(i.quantity)                 AS items,
    sum(i.quantity * i.unit_price)  AS revenue,
    now()                           AS computed_at
FROM order_items AS i
INNER JOIN orders AS o
    ON o.order_id = i.order_id
-- ---------------------------------------------------------------------------
--  GLOBAL, and only here
-- ---------------------------------------------------------------------------
--  orders and order_items are both sharded on order_id, so their rows sit on
--  the same node and a plain JOIN is correct.
--
--  products is sharded on product_id. A plain JOIN would run on each shard
--  against whatever fragment of the catalogue happens to live there, and
--  silently drop every line whose product is elsewhere. GLOBAL sends the
--  whole catalogue to every node first.
--
--  The failure this prevents is not an error. It is a smaller number.
-- ---------------------------------------------------------------------------
GLOBAL INNER JOIN products AS p
    ON p.product_id = i.product_id
WHERE toDate(o.created_at) = {day:Date}
  AND o.is_deleted = 0
  AND i.is_deleted = 0
-- ---------------------------------------------------------------------------
--  Cancelled orders are not revenue
-- ---------------------------------------------------------------------------
--  Added after the dbt model in 07-dbt disagreed with this job by about one
--  percent on every closed day. The dbt model excluded cancelled orders and
--  this one did not, so this one was overstating revenue for every day it had
--  ever computed.
--
--  Nothing caught it for two steps. The job verified that it wrote rows and
--  that the count was plausible, which it was — an order that is placed and
--  then cancelled is a real order, and counting it produces a number that
--  looks entirely reasonable and is wrong.
--
--  What caught it was a second implementation of the same definition,
--  disagreeing. That is the argument for keeping both.
-- ---------------------------------------------------------------------------
  AND o.status != 'cancelled'
GROUP BY day, category
