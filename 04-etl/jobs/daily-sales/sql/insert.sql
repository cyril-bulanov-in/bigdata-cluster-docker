-- Recompute one day of sales by category.
--
-- {day:Date} is a real query parameter, not string interpolation. ClickHouse
-- parses it as a Date and rejects anything that is not one, which is the
-- difference between a bad parameter failing here and a bad parameter
-- silently selecting nothing.

INSERT INTO analytics.daily_sales_by_category
SELECT
    toDate(o.created_at)                        AS day,
    p.category                                  AS category,
    uniqExact(o.order_id)                       AS orders,
    sum(oi.quantity)                            AS items,
    sum(oi.quantity * oi.unit_price)            AS revenue,
    now64(3)                                    AS computed_at
FROM
(
    -- FINAL collapses the versions change capture produces: an order arrives
    -- as an insert, then an update setting the total, then once per status
    -- change. Without FINAL every one of those would be counted.
    --
    -- It is expensive — it merges parts at read time — which is exactly why
    -- this runs once a day into a small table instead of on every dashboard
    -- refresh.
    SELECT order_id, created_at, status
    FROM analytics.orders FINAL
    WHERE is_deleted = 0
      AND toDate(created_at) = {day:Date}
      -- Cancelled orders are not sales. Everything else counts, including
      -- orders still in flight, because the question is what was ordered that
      -- day, not what was eventually delivered.
      AND status != 'cancelled'
) AS o
INNER JOIN
(
    SELECT order_id, product_id, quantity, unit_price
    FROM analytics.order_items FINAL
    WHERE is_deleted = 0
) AS oi
    -- A plain JOIN, and it is correct here only because both tables are
    -- sharded on order_id. A distributed JOIN runs locally on each shard, so
    -- co-located keys join correctly and anything else silently loses the
    -- rows whose partners live on another node.
    ON o.order_id = oi.order_id
GLOBAL INNER JOIN
(
    SELECT product_id, category
    FROM analytics.products FINAL
    WHERE is_deleted = 0
) AS p
    -- GLOBAL, because products is sharded on product_id, not order_id. Its
    -- rows for a given order can live on any shard.
    --
    -- GLOBAL makes the initiator evaluate this subquery once and send the
    -- result to every shard. Dropping the keyword would not raise an error:
    -- each shard would join against only its own slice of products, and the
    -- output would be quietly short. That is the failure mode worth
    -- remembering — a wrong number, not a stack trace.
    ON oi.product_id = p.product_id
GROUP BY day, category;
