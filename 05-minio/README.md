# 05-minio — object storage

S3-compatible storage with a three-layer bucket layout, versioning where it
buys something, and lifecycle rules that stop it from costing money quietly.

Step 5 of [bigdata-cluster-docker](../README.md). It **includes** `04-etl` and
everything below it, so `make up` here starts the whole platform.

## Quick start

```bash
cp .env.example .env
cp ../04-etl/.env.example ../04-etl/.env          # if not already there
cp ../03-dbms/.env.example ../03-dbms/.env
cp ../02-monitoring/.env.example ../02-monitoring/.env
cp ../01-kafka/.env.example ../01-kafka/.env
chmod +x scripts/smoke.sh minio/init.sh

make up
make test
```

| | |
|---|---|
| MinIO console | http://localhost:9001 (credentials in `.env`) |
| MinIO S3 API | http://localhost:9000 |
| Airflow | http://localhost:8081 |
| ClickHouse | http://localhost:8123/play |
| Grafana | http://localhost:3000 |

`make up-light` starts everything except the ClickHouse cluster.

Port 9000 is free because ClickHouse's native port was deliberately published
on 9010 back in step 3, for exactly this.

## Why this comes before Spark

Spark without object storage either reads Kafka straight into ClickHouse —
which ClickHouse already does by itself — or works on local files, which has
nothing to do with the target architecture. With MinIO in place the jobs have
a real task: read from Kafka or S3, write Parquet back, through the same
`s3a://` paths that will point at AWS with one variable changed.

## The layout

Three layers, three buckets.

| Bucket | Contents | Versioning | Lifecycle |
|---|---|---|---|
| `raw` | exactly what arrived, never edited | on | expire after 30d, noncurrent after 7d |
| `staged` | parsed, typed, deduplicated | on | noncurrent after 7d |
| `curated` | modelled for the queries that run | off | none |

Separate buckets rather than prefixes in one, because lifecycle rules and
access policies are set per bucket — a retention rule on `raw` then cannot
reach `curated` by accident.

Created by `minio-init`, a container that runs to completion and exits. It is
idempotent, so `make up` calls it every time without a guard, and a fresh
clone produces the same layout with the same rules.

### Versioning is on for two buckets and off for one

`raw` and `staged` are written by jobs that can be re-run. A re-run that
overwrites an object destroys the evidence of what the first run produced.
With versioning the previous copy is still there.

`curated` is derived and rebuildable from `staged`, so keeping every version
of it costs storage for no recovery value.

The smoke test asserts all three, including that `curated` is **off** — that
one exists to catch versioning being switched on everywhere "to be safe".

### The lifecycle rule that pays for itself

`--noncurrent-expire-days 7` on the versioned buckets.

Without it, versioning accumulates every overwrite for ever. This is the most
common way an object storage bill grows with no visible cause: the console
lists current versions only, so the object count and the total size both look
correct while the storage underneath keeps growing.

Checking it by hand means comparing the object count against the version
count, which nobody does. So it is a smoke check and an alert instead —
`MinioMissedFreeVersions` in
`../02-monitoring/prometheus/rules/05-minio.yml` watches MinIO's own expiry
counters, which say whether the rules are being applied rather than whether
their effect happens to be visible yet.

## There are no directories in S3

Worth stating because the console shows a folder tree and it is a fiction.

There are only object names, and a slash is an ordinary character in one. The
console groups by prefix for display. `make objects` lists recursively, which
is what is actually stored:

```bash
make objects BUCKET=raw
```

A "folder" created through the console appears as a zero-byte object whose
name ends in a slash — MinIO writes that placeholder so the UI has something
to show. Real S3 has no such object.

The consequence that matters: **there is no rename**. `mc mv` and `aws s3 mv`
are wrappers around CopyObject plus DeleteObject. Renaming a prefix means
copying and deleting every object under it — one request pair each, no
atomicity, and CopyObject caps at 5 GB per object before multipart copy is
required.

Which is why the prefix layout is decided up front and never touched:

```
raw/orders/dt=2026-09-06/orders.parquet
    ^      ^             ^
    |      |             the only part that ever grows
    |      never changes
    the layer, which is the bucket
```

`dt=` is Hive-style partitioning, and not decoration: Spark, Trino and Athena
read it as a partition column and skip prefixes that cannot match a filter,
without listing them.

## Writing through the protocol

The export job in `04-etl` reads a day of orders from ClickHouse and writes it
as Parquet:

```bash
cd ../04-etl
make export-job DAY=2026-09-06 DRY_RUN=1    # read and report, write nothing
make export-job DAY=2026-09-06
cd ../05-minio && make objects BUCKET=raw
```

Two things in that job are worth reading rather than described here: the two
boto3 settings that make an S3 client work against MinIO, and the read-back
verification. See `../04-etl/jobs/export-orders/run.py`.

Run it twice on the same day and the object count stays at one while the
version id changes:

```bash
make mc
mc ls --versions local/raw/orders/dt=2026-09-06/
```

That is versioning doing its job: the earlier result is still recoverable, and
the lifecycle rule removes it after a week.

## Traps from this step

**A Docker Hub tag is not a GitHub release tag.** MinIO's public images stop
around September 2025 while the source keeps releasing. A version copied from
the releases page fails with `failed to resolve reference ... not found`.
Check before committing one:

```bash
docker manifest inspect minio/minio:<tag> >/dev/null && echo ok
```

**MinIO serves metrics on `/minio/v2/metrics/cluster`, not `/metrics`.** The
container carries a `prometheus.path` label and `docker-sd` in
`02-monitoring` has a relabel rule for `__metrics_path__`. Without it the
target is discovered and scrapes a 404 — red for a reason that has nothing to
do with MinIO.

**Replacing a mounted file needs `--force-recreate`; replacing a file inside a
mounted directory does not.** A bind mount of a single file follows the inode,
and most editors replace rather than rewrite. The container then holds a
reference to a file that no longer exists and reports `no such file or
directory` for a path that is plainly there on the host.

**Two of the six metric names in the first draft of the alerting rules did not
exist.** Invented by analogy: `minio_bucket_usage_version_total` looked
reasonable and is not a thing. A rule naming a metric that does not exist
never fires and never complains. The smoke test now asserts that every metric
the rules depend on is present, so an upgrade that renames one turns the test
red instead of silently disabling an alert.

## What continuous integration does not cover

The workflow starts everything except the ClickHouse cluster, for the same
memory reason as steps 3 and 4.

What that costs here is the export job, which reads from ClickHouse. So the
smoke test has its own protocol check that depends on nothing but MinIO: write
an object, read it back, compare the bytes, confirm a version was recorded,
delete it. Without that, CI would verify that buckets exist and never once
confirm that anything can be stored in them.

CI covers: the compose files and every include, MinIO starting, the bucket
layout, versioning on all three buckets, both lifecycle rules, Prometheus
scraping the right path, every metric the alerting rules name, and a full
write-read-verify round trip.

**Locally, on a machine that can hold the cluster:**

```bash
make up
make test          # 29 checks, nothing skipped
cd ../04-etl && make export-job DAY=<a day with orders>
cd ../05-minio && make objects BUCKET=raw
```

## Commands

```
make help          list every command
make up            start the whole platform including MinIO
make up-light      start without the ClickHouse cluster
make test          validate configs, then the running stack
make clean         stop everything and wipe every volume

make buckets       the layout, with versioning and lifecycle
make buckets-init  re-run the layout script (idempotent)
make objects       everything stored, recursively (BUCKET=raw)
make mc            interactive shell with the MinIO client
make minio-status  is it up and what does it report
make minio-metrics is Prometheus scraping it
```
