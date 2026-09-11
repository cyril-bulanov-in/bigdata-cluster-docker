"""Export one day of orders from ClickHouse to object storage as Parquet.

    CLICKHOUSE_URL    http://clickhouse-01:8123
    CLICKHOUSE_DB     analytics
    S3_ENDPOINT       http://minio:9000
    S3_ACCESS_KEY     minioadmin
    S3_SECRET_KEY     minioadmin
    S3_BUCKET         raw
    TARGET_DATE       YYYY-MM-DD
    DRY_RUN           1 to read and report, write nothing

Writes to  s3://<bucket>/orders/dt=<date>/orders.parquet  and then reads it
back and compares the row count.

Writing without verifying is the failure this repository keeps circling: a job
that uploads a truncated file exits zero, the object exists, its size looks
plausible, and nothing is wrong until someone queries it weeks later.
"""
from __future__ import annotations

import io
import os
import sys
import time

import boto3
import pyarrow as pa
import pyarrow.parquet as pq
import requests
from botocore.config import Config
from botocore.exceptions import ClientError

CLICKHOUSE_URL = os.environ.get("CLICKHOUSE_URL", "http://clickhouse-01:8123")
CLICKHOUSE_DB = os.environ.get("CLICKHOUSE_DB", "analytics")

S3_ENDPOINT = os.environ.get("S3_ENDPOINT", "http://minio:9000")
S3_ACCESS_KEY = os.environ.get("S3_ACCESS_KEY", "minioadmin")
S3_SECRET_KEY = os.environ.get("S3_SECRET_KEY", "minioadmin")
S3_BUCKET = os.environ.get("S3_BUCKET", "raw")

TARGET_DATE = os.environ.get("TARGET_DATE", "")
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"


def s3_client():
    """A client pointed at MinIO, and the two settings that make it work.

    path style addressing: the AWS default is virtual-hosted style, which puts
    the bucket in the hostname — bucket.s3.amazonaws.com. MinIO is reached by
    a service name with no wildcard DNS behind it, so bucket.minio does not
    resolve. The failure is a connection error naming a host nobody typed.

    region: MinIO ignores it, boto3 refuses to sign without one.
    """
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT,
        aws_access_key_id=S3_ACCESS_KEY,
        aws_secret_access_key=S3_SECRET_KEY,
        region_name="us-east-1",
        config=Config(s3={"addressing_style": "path"}, retries={"max_attempts": 3}),
    )


def ch_query(sql: str, params: dict[str, str] | None = None) -> str:
    query_params: dict[str, str] = {"database": CLICKHOUSE_DB}
    for key, value in (params or {}).items():
        query_params[f"param_{key}"] = value
    response = requests.post(CLICKHOUSE_URL, params=query_params,
                             data=sql.encode("utf-8"), timeout=300)
    if response.status_code != 200:
        raise RuntimeError(
            f"ClickHouse returned {response.status_code}:\n{response.text.strip()[:1500]}"
        )
    return response.text


def wait_for(name: str, check, attempts: int = 30, delay: float = 2.0) -> None:
    for attempt in range(1, attempts + 1):
        try:
            check()
            print(f"{name} reachable on attempt {attempt}", flush=True)
            return
        except Exception as exc:  # noqa: BLE001
            if attempt % 5 == 0:
                print(f"waiting for {name} ({attempt}/{attempts}): {exc}", flush=True)
        time.sleep(delay)
    raise SystemExit(f"{name} did not answer")


def main() -> int:
    if not TARGET_DATE:
        print("TARGET_DATE is not set", file=sys.stderr)
        return 2

    # The prefix, and the reason it is shaped this way.
    #
    # <entity>/dt=<date>/ is Hive-style partitioning: the layer is the bucket,
    # the entity never changes, and the date only ever grows. Nothing in the
    # path is ever rewritten, which matters because renaming a prefix in S3
    # means copying and deleting every object under it — there is no rename.
    #
    # The dt= form is not decoration. Spark, Trino and Athena all read it as a
    # partition column and skip prefixes that cannot match a filter, without
    # listing them.
    key = f"orders/dt={TARGET_DATE}/orders.parquet"

    print(f"target date : {TARGET_DATE}")
    print(f"clickhouse  : {CLICKHOUSE_URL} database={CLICKHOUSE_DB}")
    print(f"destination : s3://{S3_BUCKET}/{key}  via {S3_ENDPOINT}")
    print(f"dry run     : {DRY_RUN}")

    wait_for("clickhouse", lambda: ch_query("SELECT 1"))
    s3 = s3_client()
    wait_for("minio", lambda: s3.head_bucket(Bucket=S3_BUCKET))

    # ---- read ------------------------------------------------------------
    # FINAL collapses the versions change capture produces. Without it every
    # status change of an order would appear as its own row.
    #
    # Parquet is asked for by name: ClickHouse writes the format itself, so
    # there is no row-by-row conversion in Python and no chance of a type
    # being reinterpreted on the way through.
    sql = """
        SELECT order_id, customer_id, status, total_amount, created_at, updated_at
        FROM orders FINAL
        WHERE is_deleted = 0 AND toDate(created_at) = {day:Date}
        ORDER BY order_id
        FORMAT Parquet
    """
    count = ch_query(
        "SELECT count() FROM orders FINAL "
        "WHERE is_deleted = 0 AND toDate(created_at) = {day:Date}",
        {"day": TARGET_DATE},
    ).strip()
    print(f"rows in source: {count}", flush=True)

    if count == "0":
        # A day with no orders is a fact, not a failure. Failing here would
        # make every backfill of a quiet day look like a broken job.
        print("nothing to export", flush=True)
        return 0

    started = time.monotonic()
    response = requests.post(
        CLICKHOUSE_URL,
        params={"database": CLICKHOUSE_DB, "param_day": TARGET_DATE},
        data=sql.encode("utf-8"),
        timeout=600,
    )
    if response.status_code != 200:
        raise RuntimeError(f"ClickHouse returned {response.status_code}: "
                           f"{response.text.strip()[:1500]}")
    body = response.content
    print(f"read {len(body) / 1024 / 1024:.1f} MiB of parquet in "
          f"{time.monotonic() - started:.1f}s", flush=True)

    # Parse it before uploading. This is cheap and it is the difference
    # between shipping a valid file and shipping whatever came back.
    table = pq.read_table(io.BytesIO(body))
    print(f"parsed: {table.num_rows} rows, {table.num_columns} columns", flush=True)
    print(f"schema:\n{table.schema}", flush=True)

    if int(table.num_rows) != int(count):
        raise RuntimeError(
            f"ClickHouse reported {count} rows but the parquet holds {table.num_rows}"
        )

    if DRY_RUN:
        print("dry run — nothing written", flush=True)
        return 0

    # ---- write -----------------------------------------------------------
    s3.put_object(Bucket=S3_BUCKET, Key=key, Body=body,
                  ContentType="application/octet-stream")
    print(f"uploaded {len(body)} bytes", flush=True)

    # ---- read it back ----------------------------------------------------
    # An upload that returns success is not the same as an object that can be
    # read. Fetching it back and counting the rows is a few seconds and closes
    # the whole class of "the job was green and the file was truncated".
    fetched = s3.get_object(Bucket=S3_BUCKET, Key=key)["Body"].read()
    verified = pq.read_table(io.BytesIO(fetched))

    if verified.num_rows != table.num_rows:
        raise RuntimeError(
            f"wrote {table.num_rows} rows, read back {verified.num_rows}"
        )
    if len(fetched) != len(body):
        raise RuntimeError(f"wrote {len(body)} bytes, read back {len(fetched)}")

    print(f"verified: {verified.num_rows} rows read back from "
          f"s3://{S3_BUCKET}/{key}", flush=True)

    # What the object actually looks like in the store, including its version
    # id — the bucket is versioned, so a re-run does not overwrite history.
    head = s3.head_object(Bucket=S3_BUCKET, Key=key)
    print(f"etag={head['ETag']} version={head.get('VersionId', 'none')} "
          f"size={head['ContentLength']}", flush=True)
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except ClientError as exc:
        print(f"S3 error: {exc}", file=sys.stderr)
        sys.exit(1)
