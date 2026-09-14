"""Read the Parquet in raw/ and report what Spark sees.

Does nothing useful on purpose. Five things have to be right before any real
Spark job can run, and each fails differently:

    the driver can reach the master and get executors
    the executors can reach the driver back
    s3a:// resolves at all — the jars are present and loadable
    the endpoint, credentials and path style reach the executors, not just
      the driver
    the work is actually distributed rather than done in one place

Debugging those alongside a transformation means never being sure which half
is broken.
"""
from __future__ import annotations

import os
import sys

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

S3_BUCKET = os.environ.get("S3_BUCKET", "raw")
S3_PREFIX = os.environ.get("S3_PREFIX", "orders")


def main() -> int:
    # The session is already configured by spark-submit; this only attaches to
    # it. Every --conf the entrypoint passed is visible here.
    spark = SparkSession.builder.appName("spark-smoke").getOrCreate()
    sc = spark.sparkContext
    spark.sparkContext.setLogLevel("WARN")

    print("=" * 64)
    print(f"spark version   : {spark.version}")
    print(f"master          : {sc.master}")
    print(f"application id  : {sc.applicationId}")
    print(f"driver host     : {sc.getConf().get('spark.driver.host', '?')}")
    print("=" * 64)

    # Executors register asynchronously. Reporting the count immediately after
    # startup usually shows one — the driver's own block manager — which looks
    # like a cluster that gave out nothing.
    import time
    for _ in range(30):
        # The driver's block manager is in this list too, hence the -1.
        n = len(sc._jsc.sc().statusTracker().getExecutorInfos()) - 1
        if n > 0:
            print(f"executors       : {n}")
            break
        time.sleep(1)
    else:
        print("executors       : none registered after 30s", file=sys.stderr)
        return 3

    path = f"s3a://{S3_BUCKET}/{S3_PREFIX}/"
    print(f"reading         : {path}")

    try:
        df = spark.read.parquet(path)
    except Exception as exc:  # noqa: BLE001
        # The most common failures here are worth naming, because the stack
        # trace names none of them.
        print(f"\nread failed: {exc}\n", file=sys.stderr)
        print("Usual causes, in order of likelihood:", file=sys.stderr)
        print("  the prefix is empty — run the export job in 04-etl first", file=sys.stderr)
        print("  hadoop-aws does not match the Hadoop compiled into Spark", file=sys.stderr)
        print("  the endpoint or credentials never reached the executors", file=sys.stderr)
        print("  path-style addressing is off, so bucket.minio was resolved", file=sys.stderr)
        return 1

    # An action, so the read actually happens. Everything above this line is
    # lazy: a wrong path produces no error until something forces evaluation.
    rows = df.count()
    print(f"rows            : {rows}")
    print(f"partitions      : {df.rdd.getNumPartitions()}")
    print("\nschema:")
    df.printSchema()

    if rows == 0:
        print("\nthe prefix exists but holds no rows", file=sys.stderr)
        return 2

    # Which executor did which part of the work. This is the point of running
    # four single-core workers rather than one larger one: on a cluster that
    # is distributing properly, more than one host appears here.
    per_host = (
        df.withColumn("_host", F.spark_partition_id())
          .groupBy("_host").count().orderBy("_host")
          .limit(20).collect()
    )
    print(f"\nrows per partition ({len(per_host)} shown):")
    for row in per_host:
        print(f"  partition {row['_host']:<4} {row['count']} rows")

    print("\nsample:")
    df.orderBy("order_id").limit(5).show(truncate=False)

    spark.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
