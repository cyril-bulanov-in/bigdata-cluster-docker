"""Read the raw orders, shape them for reading, write them to staged.

Reads   s3a://raw/orders/dt=*/            Parquet, exactly as exported
Writes  s3a://staged/orders/dt=*/          Parquet, partitioned by date

What "staged" means here: still one row per order, but typed, deduplicated,
and carrying the derived columns that every downstream query would otherwise
recompute. No joins, no aggregation — that is what curated is for.

The transformation is deliberately modest. The point of this job is the two
things around it that are easy to get wrong and hard to diagnose: writing to
object storage safely, and doing the work on more than one machine.
"""
from __future__ import annotations

import os
import sys
import time

from pyspark.sql import SparkSession
from pyspark.sql import functions as F

SRC_BUCKET = os.environ.get("SRC_BUCKET", "raw")
DST_BUCKET = os.environ.get("DST_BUCKET", "staged")
ENTITY = os.environ.get("ENTITY", "orders")

# Empty means every partition present in the source. A single date restricts
# the job to one day, which is what a scheduled run does.
TARGET_DATE = os.environ.get("TARGET_DATE", "")
DRY_RUN = os.environ.get("DRY_RUN", "0") == "1"


def main() -> int:
    spark = SparkSession.builder.appName("orders-staged").getOrCreate()
    sc = spark.sparkContext
    sc.setLogLevel("WARN")

    src = f"s3a://{SRC_BUCKET}/{ENTITY}/"
    dst = f"s3a://{DST_BUCKET}/{ENTITY}/"

    print("=" * 64)
    print(f"source      : {src}")
    print(f"destination : {dst}")
    print(f"date filter : {TARGET_DATE or 'all partitions'}")
    print(f"dry run     : {DRY_RUN}")
    print("=" * 64)

    # Executors register asynchronously. Reading before any have joined works,
    # and does the whole job on the driver.
    for _ in range(30):
        n = len(sc._jsc.sc().statusTracker().getExecutorInfos()) - 1
        if n > 0:
            print(f"executors   : {n}")
            break
        time.sleep(1)
    else:
        print("no executors registered after 30s", file=sys.stderr)
        return 3

    # ---- read ------------------------------------------------------------
    # dt is not a column in the files. Spark derives it from the dt=<value>
    # directory names, which is what Hive-style partitioning buys: a filter on
    # dt skips whole prefixes without listing or opening them.
    df = spark.read.parquet(src)

    if TARGET_DATE:
        # Pushed down to partition pruning, not applied after reading. The
        # difference is whether the other days are read at all.
        df = df.where(F.col("dt") == F.lit(TARGET_DATE))

    source_rows = df.count()
    print(f"source rows : {source_rows}")
    print(f"partitions  : {df.rdd.getNumPartitions()}")

    if source_rows == 0:
        # A date with nothing in it is a fact. Failing here would make a
        # backfill of a quiet day look like a broken job.
        print("nothing to process")
        return 0

    # ---- deduplicate ------------------------------------------------------
    # The export runs per day and can be re-run, so the same order can appear
    # more than once across files. Keep the latest by updated_at.
    #
    # A window rather than dropDuplicates: dropDuplicates keeps an arbitrary
    # row of each group, which is fine only when the duplicates are identical.
    # Here they are not — a re-export catches later status changes, and the
    # arbitrary choice would silently pick an older state.
    from pyspark.sql.window import Window

    newest = Window.partitionBy("order_id").orderBy(F.col("updated_at").desc())
    df = (
        df.withColumn("_rank", F.row_number().over(newest))
          .where(F.col("_rank") == 1)
          .drop("_rank")
    )

    # ---- derive -----------------------------------------------------------
    # Columns every downstream query would otherwise recompute. Cheap here,
    # once; expensive there, every time.
    staged = (
        df.withColumn("order_date", F.to_date("created_at"))
          .withColumn("order_hour", F.hour("created_at"))
          .withColumn("is_cancelled", F.col("status") == F.lit("cancelled"))
          .withColumn("is_complete", F.col("status").isin("delivered", "paid"))
          # How long the order took to reach its current state. Null while it
          # is still moving is more honest than zero.
          .withColumn(
              "age_seconds",
              F.when(
                  F.col("updated_at") > F.col("created_at"),
                  F.unix_timestamp("updated_at") - F.unix_timestamp("created_at"),
              ),
          )
          .withColumn("staged_at", F.current_timestamp())
    )

    deduped_rows = staged.count()
    if deduped_rows != source_rows:
        print(f"deduplicated: {source_rows} -> {deduped_rows} rows "
              f"({source_rows - deduped_rows} duplicates removed)")
    else:
        print(f"staged rows : {deduped_rows} (no duplicates found)")

    print("\nrows per executor host, after the shuffle:")
    per_host = (
        staged.withColumn("_host", F.spark_partition_id())
              .groupBy("_host").count().orderBy("_host").collect()
    )
    for row in per_host:
        print(f"  partition {row['_host']:<4} {row['count']} rows")

    if DRY_RUN:
        print("\ndry run — nothing written")
        staged.orderBy("order_id").limit(5).show(truncate=False)
        spark.stop()
        return 0

    # ---- write ------------------------------------------------------------
    # partitionBy writes dt=<value>/ directories, so the output is readable
    # the same way the input was, and a later job can prune on dt too.
    #
    # Note what is NOT here: .option("partitionOverwriteMode", "dynamic").
    #
    # That option is Spark's way of saying "replace only the partitions this
    # run produced, leave the others alone" — the difference between re-running
    # one day and destroying a month. But the S3A committers reject it:
    #
    #     PathOutputCommitter does not support dynamicPartitionOverwrite
    #
    # The same guarantee comes from the committer instead. spark-defaults.conf
    # selects the `partitioned` committer with conflict-mode=replace, which
    # resolves conflicts per partition directory: the days in this run are
    # replaced, every other day is untouched.
    #
    # So `overwrite` here is safe, and it is safe because of a setting in a
    # different file. Changing the committer back to `directory` would turn
    # this line into the month-destroying kind without changing this line.
    started = time.monotonic()
    (
        staged.write
        .mode("overwrite")
        .partitionBy("dt")
        .parquet(dst)
    )
    print(f"\nwrote in {time.monotonic() - started:.1f}s")

    # ---- verify -----------------------------------------------------------
    # Reading back is not ceremony. A write that returns without raising and a
    # dataset that can be read are different claims, and object storage is
    # where they come apart.
    check = spark.read.parquet(dst)
    if TARGET_DATE:
        check = check.where(F.col("dt") == F.lit(TARGET_DATE))
    written = check.count()

    if written != deduped_rows:
        print(f"\nwrote {deduped_rows} rows, read back {written}", file=sys.stderr)
        spark.stop()
        return 1

    print(f"verified    : {written} rows read back from {dst}")
    print("\npartitions written:")
    for row in check.groupBy("dt").count().orderBy("dt").collect():
        print(f"  dt={row['dt']}  {row['count']} rows")

    spark.stop()
    return 0


if __name__ == "__main__":
    sys.exit(main())
