"""Keeps the source database changing, so the rest of the platform has work.

Two modes:

    python generate.py seed     fill the reference tables once, then exit
    python generate.py churn    create and mutate rows forever

Plain SQL through psycopg, no ORM. The point of this file is that a reader can
see exactly which statements hit the database, because those statements are
what Debezium will turn into change events later. An ORM would hide precisely
the part that matters here.

Every rate is an environment variable, so the shape of the load can be changed
without rebuilding the image. See .env.example.
"""
from __future__ import annotations

import os
import random
import signal
import sys
import time
from datetime import datetime, timezone

import psycopg
from psycopg import sql

# ---------------------------------------------------------------------------
#  Configuration
# ---------------------------------------------------------------------------
DSN = (
    f"host={os.environ.get('PGHOST', 'postgres')} "
    f"port={os.environ.get('PGPORT', '5432')} "
    f"dbname={os.environ['PGDATABASE']} "
    f"user={os.environ['PGUSER']} "
    f"password={os.environ['PGPASSWORD']}"
)

SEED_CUSTOMERS = int(os.environ.get("SEED_CUSTOMERS", "2000"))
SEED_PRODUCTS  = int(os.environ.get("SEED_PRODUCTS", "200"))

# How many orders to create per minute. Everything else is expressed as a
# probability per cycle, so raising this raises the whole load proportionally.
ORDERS_PER_MINUTE = float(os.environ.get("ORDERS_PER_MINUTE", "30"))

# Probability, per cycle, of each kind of mutation.
P_ADVANCE_ORDER   = float(os.environ.get("P_ADVANCE_ORDER", "0.60"))
P_UPDATE_PRICE    = float(os.environ.get("P_UPDATE_PRICE", "0.05"))
P_NEW_CUSTOMER    = float(os.environ.get("P_NEW_CUSTOMER", "0.03"))
P_DELETE_CUSTOMER = float(os.environ.get("P_DELETE_CUSTOMER", "0.01"))

REPORT_EVERY = int(os.environ.get("REPORT_EVERY_SECONDS", "60"))

# ---------------------------------------------------------------------------
#  Reference data
# ---------------------------------------------------------------------------
CATEGORIES = ["laptops", "phones", "audio", "cameras", "storage", "monitors"]
ADJECTIVES = ["compact", "pro", "ultra", "lite", "classic", "studio", "field"]
NOUNS      = ["recorder", "adapter", "enclosure", "receiver", "mount", "hub"]
COUNTRIES  = ["IN", "RU", "DE", "US", "GB", "BR", "JP", "PL", "TR", "ES"]
FIRST      = ["Alex", "Maria", "Ivan", "Priya", "Chen", "Omar", "Lena", "Tomas"]
LAST       = ["Kowalski", "Petrov", "Sharma", "Weber", "Silva", "Nakamura"]

# Order status transitions. A terminal status has no successors, so an order
# stops moving once it is delivered or cancelled.
NEXT_STATUS = {
    "pending":   ["paid", "cancelled"],
    "paid":      ["shipped"],
    "shipped":   ["delivered"],
    "delivered": [],
    "cancelled": [],
}

# ---------------------------------------------------------------------------
#  Shutdown
# ---------------------------------------------------------------------------
#  Docker sends SIGTERM on `docker compose stop`. Without a handler Python
#  dies mid-transaction and the container takes the full 10-second kill
#  timeout to exit, every single time.
# ---------------------------------------------------------------------------
_stop = False


def _handle_stop(signum, _frame):
    global _stop
    print(f"received signal {signum}, finishing the current cycle", flush=True)
    _stop = True


signal.signal(signal.SIGTERM, _handle_stop)
signal.signal(signal.SIGINT, _handle_stop)


# ---------------------------------------------------------------------------
#  Connection
# ---------------------------------------------------------------------------
def connect(retries: int = 60, delay: float = 2.0) -> psycopg.Connection:
    """Retry until Postgres accepts connections.

    Compose waits for the healthcheck, but a healthy Postgres can still refuse
    a connection for a moment while it finishes recovery. Retrying is cheaper
    than reasoning about that race.
    """
    last: Exception | None = None
    for attempt in range(1, retries + 1):
        try:
            conn = psycopg.connect(DSN, autocommit=True)
            print(f"connected to postgres on attempt {attempt}", flush=True)
            return conn
        except psycopg.OperationalError as exc:
            last = exc
            if attempt % 5 == 0:
                print(f"postgres not ready yet ({attempt}/{retries})", flush=True)
            time.sleep(delay)
    raise SystemExit(f"could not connect to postgres: {last}")


# ---------------------------------------------------------------------------
#  Seed
# ---------------------------------------------------------------------------
def seed(conn: psycopg.Connection) -> None:
    with conn.cursor() as cur:
        cur.execute("SELECT count(*) FROM customers")
        existing = cur.fetchone()[0]
        if existing:
            print(f"already seeded: {existing} customers, nothing to do", flush=True)
            return

        # executemany in one transaction rather than one INSERT per row.
        # Two thousand separate commits would also produce two thousand
        # separate WAL flushes, which is slow for no reason.
        customers = [
            (
                f"user{i:05d}@example.com",
                f"{random.choice(FIRST)} {random.choice(LAST)}",
                random.choice(COUNTRIES),
            )
            for i in range(SEED_CUSTOMERS)
        ]
        cur.executemany(
            "INSERT INTO customers (email, full_name, country_code) VALUES (%s, %s, %s)",
            customers,
        )
        print(f"inserted {len(customers)} customers", flush=True)

        products = [
            (
                f"SKU-{i:05d}",
                f"{random.choice(ADJECTIVES)} {random.choice(NOUNS)}",
                random.choice(CATEGORIES),
                round(random.lognormvariate(4.0, 0.7), 2),
            )
            for i in range(SEED_PRODUCTS)
        ]
        cur.executemany(
            "INSERT INTO products (sku, name, category, price) VALUES (%s, %s, %s, %s)",
            products,
        )
        print(f"inserted {len(products)} products", flush=True)


# ---------------------------------------------------------------------------
#  Individual mutations
# ---------------------------------------------------------------------------
def create_order(cur) -> bool:
    """One order with one to five items. Produces INSERTs only."""
    cur.execute("SELECT customer_id FROM customers ORDER BY random() LIMIT 1")
    row = cur.fetchone()
    if row is None:
        return False
    customer_id = row[0]

    cur.execute(
        "SELECT product_id, price FROM products WHERE is_active ORDER BY random() LIMIT %s",
        (random.randint(1, 5),),
    )
    picked = cur.fetchall()
    if not picked:
        return False

    cur.execute(
        "INSERT INTO orders (customer_id, status) VALUES (%s, 'pending') RETURNING order_id",
        (customer_id,),
    )
    order_id = cur.fetchone()[0]

    total = 0.0
    for product_id, price in picked:
        qty = random.randint(1, 3)
        total += float(price) * qty
        cur.execute(
            "INSERT INTO order_items (order_id, product_id, quantity, unit_price) "
            "VALUES (%s, %s, %s, %s)",
            (order_id, product_id, qty, price),
        )

    # A second statement against orders, so every order produces at least one
    # UPDATE as well as its INSERT.
    cur.execute(
        "UPDATE orders SET total_amount = %s, updated_at = now() WHERE order_id = %s",
        (round(total, 2), order_id),
    )
    return True


def advance_order(cur) -> bool:
    """Move one order to its next status. The main source of UPDATEs."""
    cur.execute(
        "SELECT order_id, status FROM orders "
        "WHERE status IN ('pending','paid','shipped') ORDER BY random() LIMIT 1"
    )
    row = cur.fetchone()
    if row is None:
        return False
    order_id, status = row

    options = NEXT_STATUS[status]
    if not options:
        return False
    # Cancellation is possible but rare; weight it down.
    weights = [10 if s != "cancelled" else 1 for s in options]
    new_status = random.choices(options, weights=weights, k=1)[0]

    cur.execute(
        "UPDATE orders SET status = %s, updated_at = now() WHERE order_id = %s",
        (new_status, order_id),
    )
    return True


def update_price(cur) -> bool:
    """Occasional catalogue change. Note it does not touch existing orders:
    order_items keeps the price paid, which is the whole point of copying it."""
    cur.execute("SELECT product_id, price FROM products ORDER BY random() LIMIT 1")
    row = cur.fetchone()
    if row is None:
        return False
    product_id, price = row
    factor = random.uniform(0.9, 1.15)
    cur.execute(
        "UPDATE products SET price = %s, updated_at = now() WHERE product_id = %s",
        (round(float(price) * factor, 2), product_id),
    )
    return True


def new_customer(cur) -> bool:
    cur.execute(
        "INSERT INTO customers (email, full_name, country_code) VALUES (%s, %s, %s)",
        (
            f"user{int(time.time() * 1000) % 10**9}@example.com",
            f"{random.choice(FIRST)} {random.choice(LAST)}",
            random.choice(COUNTRIES),
        ),
    )
    return True


def delete_customer(cur) -> bool:
    """The interesting one for CDC.

    Only customers with no orders are deleted — a foreign key blocks the rest,
    and this generator is not here to demonstrate constraint violations. In a
    real system this is what a data-deletion request looks like.
    """
    cur.execute(
        "SELECT c.customer_id FROM customers c "
        "LEFT JOIN orders o ON o.customer_id = c.customer_id "
        "WHERE o.order_id IS NULL ORDER BY random() LIMIT 1"
    )
    row = cur.fetchone()
    if row is None:
        return False
    cur.execute("DELETE FROM customers WHERE customer_id = %s", (row[0],))
    return True


# ---------------------------------------------------------------------------
#  Churn loop
# ---------------------------------------------------------------------------
def churn(conn: psycopg.Connection) -> None:
    interval = 60.0 / max(ORDERS_PER_MINUTE, 0.1)
    print(
        f"churn started: {ORDERS_PER_MINUTE} orders/min "
        f"(one cycle every {interval:.2f}s)",
        flush=True,
    )

    counts = {"orders": 0, "advances": 0, "prices": 0, "customers": 0, "deletes": 0}
    last_report = time.monotonic()

    while not _stop:
        cycle_start = time.monotonic()
        try:
            with conn.cursor() as cur:
                if create_order(cur):
                    counts["orders"] += 1
                if random.random() < P_ADVANCE_ORDER and advance_order(cur):
                    counts["advances"] += 1
                if random.random() < P_UPDATE_PRICE and update_price(cur):
                    counts["prices"] += 1
                if random.random() < P_NEW_CUSTOMER and new_customer(cur):
                    counts["customers"] += 1
                if random.random() < P_DELETE_CUSTOMER and delete_customer(cur):
                    counts["deletes"] += 1
        except psycopg.OperationalError as exc:
            # The database restarted underneath us. Reconnect rather than die:
            # a generator that exits on the first blip is useless for a stack
            # whose whole purpose includes failure drills.
            print(f"lost connection ({exc}), reconnecting", flush=True)
            conn = connect()
            continue

        now = time.monotonic()
        if now - last_report >= REPORT_EVERY:
            print(
                "last {}s: {} orders, {} status changes, {} price changes, "
                "{} new customers, {} deletes".format(
                    REPORT_EVERY, counts["orders"], counts["advances"],
                    counts["prices"], counts["customers"], counts["deletes"]
                ),
                flush=True,
            )
            counts = dict.fromkeys(counts, 0)
            last_report = now

        # Sleep for whatever is left of the cycle, so the configured rate is
        # the actual rate rather than an upper bound that the database misses.
        elapsed = time.monotonic() - cycle_start
        if elapsed < interval:
            time.sleep(interval - elapsed)

    print("stopped cleanly", flush=True)


# ---------------------------------------------------------------------------
def main() -> int:
    mode = sys.argv[1] if len(sys.argv) > 1 else "churn"
    conn = connect()

    if mode == "seed":
        seed(conn)
    elif mode == "churn":
        churn(conn)
    else:
        print(f"unknown mode: {mode} (expected 'seed' or 'churn')", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
