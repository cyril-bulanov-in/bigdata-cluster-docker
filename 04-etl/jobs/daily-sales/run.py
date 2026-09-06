"""Recompute one day of the sales-by-category mart.

Reads analytics.orders, analytics.order_items and analytics.products in
ClickHouse and writes analytics.daily_sales_by_category.

Configuration, all through the environment:

    CLICKHOUSE_URL    http://clickhouse-01:8123
    CLICKHOUSE_DB     analytics
    TARGET_DATE       YYYY-MM-DD, the day to recompute
    DRY_RUN           1 to report what would be written and stop

Idempotent. The mart is a ReplacingMergeTree keyed by (day, category) with a
computed_at version, so running the same day twice replaces the row rather
than adding to it. That property is what makes a backfill safe, and it is
worth more than any amount of care about not running a job twice.
"""
from __future__ import annotations

import os
import pathlib
import sys
import time

import requests

CLICKHOUSE_URL = os.environ.get("CLICKHOUSE_URL", "http://clickhouse-01:8123")
CLICKHOUSE_DB = os.environ.get("CLICKHOUSE_DB", "analytics")
TARGET_DATE = os.environ.get("TARGET_DATE", "")
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"

SQL_DIR = pathlib.Path("/app/sql")
TIMEOUT = int(os.environ.get("QUERY_TIMEOUT_SECONDS", "300"))


def execute(sql: str, params: dict[str, str] | None = None) -> str:
    """Send one statement over the HTTP interface.

    Parameters go as param_<name> query arguments, which is how ClickHouse
    binds {name:Type} placeholders. String interpolation would work too, right
    up until a value contains a quote.
    """
    query_params: dict[str, str] = {"database": CLICKHOUSE_DB}
    for key, value in (params or {}).items():
        query_params[f"param_{key}"] = value

    response = requests.post(
        CLICKHOUSE_URL,
        params=query_params,
        data=sql.encode("utf-8"),
        timeout=TIMEOUT,
    )
    if response.status_code != 200:
        # ClickHouse puts the real complaint in the body. Raising on the
        # status alone would report "500 Server Error" and throw away the one
        # line that says which column does not exist.
        raise RuntimeError(
            f"ClickHouse returned {response.status_code}:\n{response.text.strip()[:2000]}"
        )
    return response.text.strip()


def wait_for_clickhouse(attempts: int = 30, delay: float = 2.0) -> None:
    """A job container can start before the cluster is ready to answer.

    Airflow retries a failed task, so this is not strictly necessary — but a
    task that fails and retries looks like an incident in the UI and in the
    metrics, and "the warehouse was still starting" is not one.
    """
    for attempt in range(1, attempts + 1):
        try:
            if execute("SELECT 1") == "1":
                print(f"clickhouse reachable on attempt {attempt}", flush=True)
                return
        except Exception as exc:  # noqa: BLE001 - any failure means not ready
            if attempt % 5 == 0:
                print(f"waiting for clickhouse ({attempt}/{attempts}): {exc}", flush=True)
        time.sleep(delay)
    raise SystemExit(f"clickhouse at {CLICKHOUSE_URL} did not answer")


def main() -> int:
    if not TARGET_DATE:
        print("TARGET_DATE is not set", file=sys.stderr)
        return 2

    print(f"target date : {TARGET_DATE}")
    print(f"clickhouse  : {CLICKHOUSE_URL} database={CLICKHOUSE_DB}")
    print(f"dry run     : {DRY_RUN}")

    wait_for_clickhouse()

    # ---- make sure the mart exists -------------------------------------
    # Every statement in the file is separate; the HTTP interface takes one
    # at a time.
    create_sql = (SQL_DIR / "create.sql").read_text()
    for statement in [s.strip() for s in create_sql.split(";") if s.strip()]:
        execute(statement)
    print("mart tables present", flush=True)

    # ---- what is there to compute --------------------------------------
    source_rows = execute(
        "SELECT count() FROM orders FINAL "
        "WHERE is_deleted = 0 AND toDate(created_at) = {day:Date}",
        {"day": TARGET_DATE},
    )
    print(f"source orders on {TARGET_DATE}: {source_rows}", flush=True)

    if source_rows == "0":
        # Not an error. A day with no orders is a fact, and failing on it
        # would make every backfill of a quiet day look like a broken job.
        print("nothing to compute for this day", flush=True)
        return 0

    if DRY_RUN:
        # Turn the INSERT into a plain SELECT so the result can be shown.
        #
        # The trailing semicolon has to go with it: the HTTP interface takes
        # one statement at a time and rejects anything after a `;`, so
        # appending FORMAT to a string that still ends in one fails with
        # "Multi-statements are not allowed" — an error about the delimiter,
        # not about the query.
        select_only = (
            (SQL_DIR / "insert.sql")
            .read_text()
            .replace("INSERT INTO analytics.daily_sales_by_category", "")
            .strip()
            .rstrip(";")
            .strip()
        )
        preview = execute(select_only + " FORMAT PrettyCompact", {"day": TARGET_DATE})
        print("would write:\n" + preview, flush=True)
        return 0

    # ---- recompute -------------------------------------------------------
    started = time.monotonic()
    execute((SQL_DIR / "insert.sql").read_text(), {"day": TARGET_DATE})
    elapsed = time.monotonic() - started
    print(f"insert completed in {elapsed:.1f}s", flush=True)

    # ---- wait for the write to land, then report ------------------------
    #
    # Inserting through a Distributed table is asynchronous: the initiator
    # writes the rows for each shard to disk and forwards them in the
    # background. Reading the mart immediately after the insert returns
    # whichever shards have already received their part.
    #
    # The consequence is worse than a slow report. The job would print an
    # incomplete result and exit zero — a number that looks authoritative and
    # is not. Waiting until the count stops changing costs a few seconds and
    # removes that.
    expected = execute(
        "SELECT uniqExact(p.category) FROM ("
        "  SELECT product_id, category FROM products FINAL WHERE is_deleted = 0"
        ") AS p",
    )
    for attempt in range(1, 31):
        landed = execute(
            "SELECT count() FROM daily_sales_by_category FINAL WHERE day = {day:Date}",
            {"day": TARGET_DATE},
        )
        if landed == expected:
            print(f"all {landed} category rows landed after {attempt}s", flush=True)
            break
        time.sleep(1)
    else:
        print(
            f"WARNING: {landed} of {expected} category rows visible after 30s — "
            "distributed inserts may still be in flight",
            flush=True,
        )

    # ---- report what landed ---------------------------------------------
    # FINAL on the mart too: a re-run leaves the previous version in place
    # until a merge removes it, so counting without FINAL would report both.
    result = execute(
        "SELECT category, orders, items, revenue "
        "FROM daily_sales_by_category FINAL "
        "WHERE day = {day:Date} ORDER BY revenue DESC FORMAT PrettyCompact",
        {"day": TARGET_DATE},
    )
    print(f"mart for {TARGET_DATE}:\n{result}", flush=True)

    total = execute(
        "SELECT sum(revenue) FROM daily_sales_by_category FINAL WHERE day = {day:Date}",
        {"day": TARGET_DATE},
    )
    print(f"total revenue: {total}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
