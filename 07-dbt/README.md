# 07-dbt — models, tests and lineage

The transformation layer as a project rather than a folder of scripts: models
with declared dependencies, tests that run alongside them, generated
documentation, and one Airflow task per model.

Step 7 of [bigdata-cluster-docker](../README.md). It **includes** `06-spark`
and everything below it, so `make up` here starts the whole platform.

## Quick start

```bash
cp .env.example .env
cp ../06-spark/.env.example ../06-spark/.env      # if not already there
cp ../05-minio/.env.example ../05-minio/.env
cp ../04-etl/.env.example ../04-etl/.env
cp ../03-dbms/.env.example ../03-dbms/.env
cp ../02-monitoring/.env.example ../02-monitoring/.env
cp ../01-kafka/.env.example ../01-kafka/.env
chmod +x scripts/smoke.sh

make up
make dbt-build-all
make docs
make test
```

| | |
|---|---|
| dbt docs | http://localhost:8088 |
| Airflow | http://localhost:8081 (DAG `dbt_platform`) |
| ClickHouse | http://localhost:8123/play |
| Spark master | http://localhost:8090 |
| MinIO console | http://localhost:9001 |
| Grafana | http://localhost:3000 |

## Three sources, one project

dbt is a single-database tool: the adapter is chosen once and every model
compiles to SQL for that engine. This project nonetheless reads three systems,
because the reading happens on ClickHouse's side through its table functions.

| Source | How it is read | What it is for |
|---|---|---|
| ClickHouse | directly | the CDC staging layer from step 3 |
| Postgres | `postgresql()` table function | the operational source, read live |
| Object storage | `s3()` table function | the Parquet Spark wrote in step 6 |

The alternative — one dbt project per source — gives model sets that cannot be
joined to each other, which defeats the purpose. Here a single model can
compare all three, and one does: `recon_orders_by_source`.

Both table functions take addresses and credentials as arguments, which would
put them in the model text and therefore in git. The macros in
`project/macros/external_sources.sql` read them from the environment instead,
so a model says what it wants rather than how to reach it.

### The partition column ClickHouse does not give you

Spark derives `dt` from a `dt=2026-09-06/` directory name and hands it back as
a column. ClickHouse does not: `s3()` reads what is inside the files and knows
nothing about where they sit.

`stg_s3_orders` recovers it from the `_path` virtual column with a regex. This
is easy to miss precisely because the same layout works transparently in
Spark, and the failure is quiet — `extractGroups` returns an empty array when
it does not match, `toDate` of that is null, and the column fills with nulls
rather than raising. Hence the `not_null` test on it.

## The layers

```
sources (cdc)          declared in sources.yml, with freshness thresholds
    ↓
staging                one view per source, FINAL applied, deletes removed
    ↓
marts                  tables, modelled for the queries that run
```

Mirrors the bucket layout in step 5 and means the same things. There is no
`raw` layer here because raw lives in object storage, not in the warehouse.

### FINAL is the whole reason staging exists

The CDC tables are `ReplacingMergeTree` holding every version of every row:
the insert, the update that set the total, one row per status change. Without
`FINAL` a count of orders returns the number of events — a plausible number,
and the wrong one.

It is expensive, since parts are merged at read time, which is exactly why it
is paid once in a staging view rather than in every query downstream.

`make dbt-compare` shows what it removes:

```
  table            source rows    staged rows    versions collapsed
  orders           22505          22501          4
  customers        2665           2420           245
  products         210            200            10
  order_items      67331          67331          0
```

Four for orders rather than thousands, because the engine had already merged
most parts in the background. That is the trap: the source is *usually*
deduplicated, so a model without `FINAL` looks correct most of the time and
drifts whenever a merge has not caught up. The `unique` test on `order_id` is
what makes the difference visible — remove `FINAL` and it fails immediately.

## Two implementations of one mart, on purpose

`daily_sales_by_category` exists twice: as the hand-written job in
`04-etl/jobs/daily-sales/` and as a model here. Both read the same rows and
must produce the same numbers.

Keeping both is not a demonstration. It found a real defect: **the job had
been counting cancelled orders as revenue for two steps.** Its own checks saw
nothing — it verified that it wrote rows and that the count was plausible, and
it was. An order that is placed and then cancelled is a real order, and
including it produces an entirely reasonable number that is wrong.

What caught it was a second implementation of the same definition disagreeing.
`tests/mart_matches_job.sql` is that comparison.

### What "the same day" means turned out to be the hard part

The comparison took three attempts.

Comparing every shared day reported eighteen mismatches, of which one was the
cancelled-orders defect and seventeen were an artefact: the job writes a
snapshot of one day when someone runs it, while the model rebuilds every day
on every build.

Restricting to days before the job's last run seemed to fix that, on the
theory that a past day has stopped changing. **It has not.** An order placed
on the 14th can be cancelled on the 17th, and that changes the 14th's revenue.
Calendar days close; their data does not.

So the test compares a day only if no order belonging to it has been updated
since the job computed it. That is exact — and it is the same question a
production pipeline has to answer before it can call a partition final.

## One Airflow task per model

`dags/40_dbt_cosmos.py` turns the project into a task group: ten models, ten
test groups, each in its own container.

The alternative is a single task running `dbt build`. That works and makes a
failure opaque — the task is red, and which of ten models broke is a question
answered by reading the log. Here the graph in Airflow is the graph in dbt, a
failure is visible where it happened, and a fix re-runs from that model
forward.

### Docker execution mode, and what it costs

Cosmos normally runs models in-process: dbt installed in the Airflow image,
the project mounted, each task calling dbt directly. Simpler and faster — and
it puts the SQL in a mounted directory and the execution inside the scheduler,
which is the opposite of how every other job in this repository works.

`ExecutionMode.DOCKER` keeps the arrangement: each model runs as a container
from `dataplatform/dbt` with the project baked in, started and discarded.
Airflow needs no dbt, no adapter and no database driver — only the manifest.

The cost is a container start per model. At ten that is seconds; at a thousand
the in-process mode would be the right answer instead.

### Three Cosmos traps, all silent

**`dbt_project_path` is required even in Docker mode**, and it means the path
inside the *container* — `/dbt` — not the one Airflow sees. Omitting it fails
at parse time with a message that is accurate and says nothing about which of
the two paths it wants.

**`test_behavior` takes a `TestBehavior` member, not a string.** A string
matches nothing and Cosmos renders no tests at all — the graph looks complete
with fifty assertions quietly absent. The symptom was ten tasks where twenty
were expected.

**The image must have no `ENTRYPOINT`.** Cosmos builds the whole command
starting with `dbt`, so `ENTRYPOINT ["dbt"]` makes the container run
`dbt dbt run` and fail with `No such command 'dbt'` — which reads as dbt being
missing from an image that plainly contains it. All twenty tasks died in three
seconds. The smoke test now asserts the entrypoint is empty.

### The manifest is a contract, and it is committed

Cosmos builds its graph from `project/target/manifest.json` rather than by
running `dbt ls` on every DAG parse — which would need dbt in Airflow and a
live database connection, every thirty seconds.

The trade is that the file can fall behind. A model added and not followed by
`make manifest` simply has no task: the DAG renders perfectly, one task short,
and nothing says so.

That is why `target/` is ignored and `manifest.json` is not. Generating it in
CI instead would compare a file against the project it was just generated
from, which always agrees and proves nothing. The smoke test compares the
committed manifest against the committed models.

Watch the `.gitignore` pattern if you touch it:

```gitignore
**/target/*
!**/target/manifest.json
```

A pattern containing a slash anywhere but the end is anchored to the
repository root, so a plain `target/*` matches nothing under `07-dbt/project/`
and the negation appears to be broken when the line above it is.

## Documentation as a service

`make docs` generates the site and serves it at http://localhost:8088.

`dbt docs serve` would be simpler and is not used: it starts a single-user
server that dies with the command. Static files behind nginx make the
documentation something the platform offers, at an address, alongside Grafana
and the Spark UI.

Generation needs a live connection — the catalogue comes from asking the
warehouse what was actually created, which is why the site shows real column
types rather than what the models claim about themselves.

The lineage graph is the thing worth opening. `customer_order_summary` joins
three staging models and is read by nothing, which is what makes the graph a
tree rather than a list.

## What continuous integration does not cover

More than in any other stack, and for a structural reason: **dbt does nothing
without a warehouse**, and eight ClickHouse nodes do not fit on a GitHub
runner. Starting the whole platform here would spend twenty minutes to reach
checks that take two without it.

So this workflow is deliberately narrow. It builds the image and runs
`dbt parse` in a container with `--network none` — which proves the check does
not quietly depend on a connection.

**CI covers:** the image building, the adapter being installed, the absence of
an `ENTRYPOINT`, the project parsing, every `ref()` and `source()` resolving,
no deprecated syntax, all ten models and four sources present in the graph, at
least thirty tests defined, and the committed manifest matching the committed
models.

That is most of what breaks while editing SQL: a renamed model still
referenced, a source missing from `sources.yml`, unbalanced Jinja, a test on a
column that no longer exists.

**CI does not cover** anything that needs the database — which includes SQL
that is valid to dbt and wrong to ClickHouse. Both real defects found in this
step were of that kind: the `LowCardinality(UInt8)` that ClickHouse refuses to
materialise, and the qualified column names that made every test fail on a
model that built perfectly.

**Locally, on a machine that can hold the cluster:**

```bash
make up
make dbt-build-all          # models and tests, in dependency order
make docs
make test                   # 32 checks, nothing skipped
make dbt-freshness          # is change capture still moving
make dbt-compare            # what FINAL removes
```

## Commands

```
make help           list every command
make up             start the platform, build the image, refresh the manifest
make test           the smoke test
make clean          stop everything and wipe every volume

make dbt-build      build the image
make dbt-build-all  run the models and their tests
make dbt-debug      can dbt reach ClickHouse
make dbt-dev        run a dbt command against the local project, no rebuild
make dbt-shell      a shell in the image, project mounted

make manifest       regenerate the manifest Airflow reads
make docs           generate the documentation and serve it
make models         which tables and views dbt has created
make dbt-compare    staging rows against raw source rows
make dbt-freshness  how old is the newest row in each source
```
