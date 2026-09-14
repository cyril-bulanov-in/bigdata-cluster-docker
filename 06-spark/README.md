# 06-spark — distributed processing

A standalone Spark cluster of one master and four workers, and jobs that read
and write object storage through `s3a://`.

Step 6 of [bigdata-cluster-docker](../README.md). It **includes** `05-minio`
and everything below it, so `make up` here starts the whole platform.

## Quick start

```bash
cp .env.example .env
cp ../05-minio/.env.example ../05-minio/.env    # if not already there
cp ../04-etl/.env.example ../04-etl/.env
cp ../03-dbms/.env.example ../03-dbms/.env
cp ../02-monitoring/.env.example ../02-monitoring/.env
cp ../01-kafka/.env.example ../01-kafka/.env
chmod +x scripts/smoke.sh jobs/*/entrypoint.sh

make up
make test
```

| | |
|---|---|
| Spark master | http://localhost:8090 |
| MinIO console | http://localhost:9001 |
| Airflow | http://localhost:8081 |
| ClickHouse | http://localhost:8123/play |
| Grafana | http://localhost:3000 |

`make up-light` starts everything except the ClickHouse cluster.

## The cluster

One master, four workers, one image for all of them and for the jobs.

Standalone rather than YARN or Kubernetes: YARN would mean running Hadoop to
schedule Spark, Kubernetes would mean running Kubernetes. Standalone is
Spark's own scheduler, and it maps onto EMR Serverless the same way the rest
of this repository maps onto AWS — a job submits, executors are allocated, the
job ends. What changes there is who allocates, not what the job says.

Four workers with two cores each rather than two larger ones, because the
point is to watch a job spread across executors. With two, "it ran" and "it
was distributed" look the same.

```bash
make cluster        # what the master sees: workers, cores, memory
make jars           # the S3 jars, and the Hadoop version they must match
make spark-shell    # interactive PySpark on the cluster
```

### Worker memory and executor memory are different numbers

`SPARK_WORKER_MEMORY` is what a worker **offers**. `spark.executor.memory` is
what one executor **asks for**, and it defaults to 1 GiB no matter how much
the worker offered.

Raising only the worker figure increases the cluster's capacity and not a
single executor: the job still runs in 1 GiB and still spills to disk. Both
are set in `.env`, sized so exactly one executor fits per worker with room
left for JVM overhead outside the heap — which Spark does not count against
`spark.executor.memory`.

## Reading and writing S3

This is the fragile part of the whole step, and it took four separate failures
to get right. Each is documented where it was fixed; collected here because
they share a shape.

### The version chain is not a matter of taste

Spark's ability to read `s3a://` rests on three artifacts that must agree:

| | version | fixed by |
|---|---|---|
| Spark | 3.5.9 | chosen |
| `hadoop-aws` | 3.3.4 | the Hadoop compiled into that Spark build |
| `aws-java-sdk-bundle` | 1.12.262 | what that `hadoop-aws` was built against |
| `spark-hadoop-cloud` | 3.5.9 | Spark, again — it is a Spark module |

Only the first is a choice. `make jars` prints the Hadoop version actually
inside the image, and the smoke test fails if `hadoop-aws` disagrees with it.

Getting any of them wrong produces `NoSuchMethodError` or
`ClassNotFoundException` from deep inside the stack, naming neither S3 nor
versions. The jars are downloaded during the image build, and the build opens
each one and asserts the class Spark will look for is inside — so a wrong
version fails there rather than a minute into a job.

**Spark 3.5 rather than 4.x** for the same reason: 4.x moved to the v2 AWS
SDK, and the 3.5 line is the combination most working examples target.

### spark-hadoop-cloud is a separate download

It holds `PathOutputCommitProtocol` and `BindingParquetOutputCommitter` — the
classes `spark-defaults.conf` names. It is an optional Spark module, published
separately, and present in no official Spark image.

Without it the cluster starts, reads S3 perfectly, and fails only when a job
first **writes**, with a `ClassNotFoundException` naming a class that sounds
like it should be built in.

### The magic committer, and why not a staging one

S3 has no rename. The default Spark committer renames files into place when a
job finishes, which on S3 is a copy plus a delete per file, with no
atomicity — slow, and if the job dies halfway it leaves a directory that is
neither the old result nor the new one.

Of the S3A committers this uses `magic`, and the two staging committers were
tried first:

**`directory`** rejects Spark's `partitionOverwriteMode=dynamic` outright:

```
PathOutputCommitter does not support dynamicPartitionOverwrite
```

**`partitioned`** accepts it and then loses the data. Both staging committers
keep metadata about their uploaded parts in a **local** directory and expect
the driver and every executor to see the same one. Here they are separate
containers with separate filesystems, so the executors stage their work where
the driver never looks. The job then succeeds, writes `_SUCCESS`, and leaves
the prefix otherwise empty:

```
$ make objects BUCKET=staged
  [2026-09-14 06:20:44 UTC] 9.6KiB STANDARD orders/_SUCCESS
```

**`magic`** keeps nothing locally. Executors write straight to S3 as multipart
uploads and leave completion markers in the bucket, so there is no shared path
to arrange. It needs a store with consistent listings, which S3 has had since
2020 and MinIO always did.

The smoke test asserts the committer is `magic` by name, not merely that one
is set, and counts parquet files in the destination rather than trusting the
exit code.

### Dynamic partition overwrite comes from the committer

The job writes with `mode("overwrite")` and **no**
`partitionOverwriteMode` option. Replacing only the partitions this run
produced — rather than deleting every other day in the destination — is the
committer's `conflict-mode`, not a Spark option. Asking for both is what
produces the error above.

So that `overwrite` is safe because of a setting in a different file. Change
the committer and the same line becomes the month-destroying kind without
changing.

## The jobs

Two images, both built **FROM** the cluster image so the driver and the
executors run the same Spark build and the same jars. Two images that drifted
apart produce `ClassCastException` on `SerializedLambda`, naming a class and
not the reason.

| Image | What it does |
|---|---|
| `spark-job-spark-smoke` | reads `s3a://raw/orders/`, counts, reports the partition split |
| `spark-job-orders-staged` | `raw` → `staged`: deduplicate, derive columns, write partitioned |

```bash
make jobs                       # build both
make spark-job                  # the smoke job
make staged DRY_RUN=1           # read and report, write nothing
make staged                     # raw -> staged
make staged DATE=2026-09-06     # one day only
make staged-ls                  # what is in the staged bucket
```

### Client mode needs a resolvable driver name

The driver runs inside the job container and the executors connect **back** to
it. Left alone, Spark advertises whatever the container thinks its hostname
is — a random hex id no other container can resolve.

The job then starts, acquires executors, and hangs: the driver waiting for
executors that cannot reach it, with nothing in the log to say so.

So `make spark-job` passes `--name` and `--hostname`, and the entrypoint sets
`spark.driver.host` to match. In the DAG the equivalent is `container_name`
plus `SPARK_DRIVER_HOST`, since `DockerOperator` has no `--name`.

### Deduplication uses a window, not dropDuplicates

The export runs per day and can be re-run, so the same order can appear more
than once. `dropDuplicates` keeps an arbitrary row of each group, which is
correct only when the duplicates are identical. Here they are not — a
re-export catches later status changes — so the arbitrary choice would
silently keep an older state.

## Orchestration

`30_orders_to_staged` in `../04-etl/dags/` chains the two: export a day from
ClickHouse to `raw`, then transform it into `staged`.

Nothing in that DAG says "Spark". It names an image and passes environment
variables, exactly as it does for the plain Python job above it; the image
happens to run `spark-submit` internally. That is what makes the move to EMR
Serverless a change of operator rather than a rewrite.

```bash
cd ../04-etl
make dag-run   DAG=30_orders_to_staged
make dag-state DAG=30_orders_to_staged
```

## Why partitions are not workers

A first run often shows two partitions on a four-worker cluster, which looks
wrong and is not.

A partition is a unit of work, and their number comes from what is being read.
Two Parquet files, each far below `spark.sql.files.maxPartitionBytes`
(128 MiB), make two partitions and therefore two tasks — so two executors work
and two sit idle. The cluster is not underused; there is no more work to hand
out.

The transformation is different: the window function and the group-by force a
shuffle, and `spark.sql.shuffle.partitions` is set to 8. The job prints rows
per partition after the shuffle, and that is where the four executors show up.

Note also that `dt` appears in the schema without ever having been written
into the files. Spark derives it from the `dt=<value>/` directory names — the
Hive-style partitioning the export job was careful to produce. A filter on
`dt` then skips whole prefixes without listing them.

## Failure drills

### Lose a worker mid-job

```bash
make staged & sleep 15 && docker stop spark-worker-2
```

The tasks that worker held are rescheduled onto the others and the job
completes. Watch it in the master UI: the worker disappears, the task count on
the remaining three rises.

```bash
docker start spark-worker-2
```

### Lose the master

```bash
docker stop spark-master
```

Running jobs continue — the master hands out executors and then stays out of
the way. New submissions fail. This is the opposite of what most people
expect, and it is worth seeing once.

## What continuous integration does not cover

The workflow starts everything except the ClickHouse cluster, for the same
memory reason as steps 3 to 5. Worker memory is also cut from 8 GiB to 1 GiB:
the checks are about there being four separate executors, not about how much
each holds.

What that costs is the transformation itself. It reads `s3://raw/orders/`,
which is filled by a job that reads ClickHouse — absent in CI. That check
prints as `SKIP` rather than failing on something it was never given.

CI covers: the image build including all three jars and their contents, the
cluster forming, four workers offering cores, `hadoop-aws` matching the
bundled Hadoop, the committer being `magic`, path-style addressing, and
Prometheus scraping both roles.

**Locally, on a machine that can hold the cluster:**

```bash
make up
cd ../04-etl && make export-job DAY=<a day with orders>
cd ../06-spark && make test     # 15 checks, nothing skipped
make staged && make staged-ls
```

Four workers at 8 GiB is 32 GiB for Spark alone, on top of roughly 24 for the
rest of the platform. Lower `SPARK_WORKER_MEMORY` and `SPARK_EXECUTOR_MEMORY`
together — lowering only one does nothing.

## Commands

```
make help          list every command
make up            start the whole platform including Spark
make up-light      start without the ClickHouse cluster
make test          validate configs, then the running stack
make clean         stop everything and wipe every volume

make cluster       workers, cores, memory as the master sees them
make jars          the S3 jars and the Hadoop version they must match
make jobs          build the job images
make spark-job     run the smoke job
make staged        run raw -> staged (DATE=..., DRY_RUN=1)
make staged-ls     what is in the staged bucket
make spark-shell   interactive PySpark on the cluster
make spark-metrics is Prometheus scraping Spark
```
