# 04-etl — orchestration

Airflow deciding *when* things run and *with what parameters*, while the work
itself happens inside containers that know nothing about Airflow.

Step 4 of [bigdata-cluster-docker](../README.md). It **includes** `03-dbms`,
which includes `02-monitoring` and `01-kafka`, so `make up` here starts the
whole platform — thirty containers.

## Quick start

```bash
cp .env.example .env
cp ../03-dbms/.env.example ../03-dbms/.env         # if not already there
cp ../02-monitoring/.env.example ../02-monitoring/.env
cp ../01-kafka/.env.example ../01-kafka/.env
chmod +x scripts/smoke.sh

make up
cd ../03-dbms && make connector && cd ../04-etl
make test
```

| | |
|---|---|
| Airflow | http://localhost:8081 — no login, see below |
| ClickHouse | http://localhost:8123/play |
| Kafbat UI | http://localhost:8080 |
| Grafana | http://localhost:3000 |
| Prometheus | http://localhost:9090 |

`make up-light` starts everything except the ClickHouse cluster, for a smaller
machine.

## The idea this stack exists to demonstrate

A DAG here contains no transformation logic. Not a line of SQL, not a
DataFrame. It says which image to run, on what schedule, with which
parameters — and that is all.

```python
DockerOperator(
    task_id="daily_sales_by_category",
    image="dataplatform/job-daily-sales:0.1.0",
    network_mode="dataplatform",
    environment={
        "CLICKHOUSE_URL": "http://clickhouse-01:8123",
        "TARGET_DATE": "{{ dag_run.run_after | ds }}",
    },
)
```

The SQL lives inside that image, baked in at build time. Swap `DockerOperator`
for `EcsRunTaskOperator` and the same image runs on AWS unchanged.

The alternative — a `PythonOperator` with the logic in the DAG file — looks
simpler and costs the property that makes this worth doing. The job stops
being a versioned artifact, its dependencies become Airflow's dependencies,
and moving to managed Airflow means moving the transformation logic with it.
The file layout says the same thing: `dags/` holds scheduling, `jobs/` holds
work, and nothing crosses over.

## What is inside

| Container | Role |
|---|---|
| `airflow-apiserver` | UI, REST API, and the execution API tasks call back into |
| `airflow-scheduler` | decides what runs; with LocalExecutor, also runs it |
| `airflow-dag-processor` | parses DAG files — a separate process in Airflow 3 |
| `airflow-triggerer` | deferred tasks, the ones that wait without a worker slot |
| `airflow-postgres` | Airflow's own metadata database |
| `airflow-statsd` | StatsD to Prometheus, because Airflow speaks neither |

Four Airflow processes instead of Airflow 2's two. The split that matters is
the DAG processor: the scheduler no longer imports DAG code, so a syntax error
in one file cannot stop scheduling for everything else.

Its metadata lives in its own Postgres, not the one in `03-dbms`. That one is
the operational source being captured — Airflow's bookkeeping has no business
appearing in the change stream, and a migration on one must never touch the
other.

## The DAGs

**`00_docker_smoke`** proves the plumbing and does nothing useful. Five things
have to be right before any real job can run, and each fails differently: the
scheduler reaching the Docker socket, the image existing, the container
joining the right network, parameters arriving, and a non-zero exit becoming a
failed task. Its second task fails on purpose — a pipeline where nothing has
ever failed is a pipeline where nobody knows what failure looks like.

**`10_daily_sales`** computes one day of sales by category from the CDC
staging tables into `analytics.daily_sales_by_category`. Daily at 01:00 UTC,
`catchup=False`, `max_active_runs=1`.

```bash
make mart-job DRY_RUN=1     # see what it would write, change nothing
make mart-job               # run it directly, no Airflow involved
make mart                   # what is in the mart
make mart-run               # the same thing through Airflow
make dag-state DAG=10_daily_sales
```

Running the job directly is worth having as its own command. When a mart is
wrong, the first question is whether the job is wrong or the orchestration is,
and this answers it in one step.

## Two things in the mart query worth reading

### GLOBAL JOIN, and the wrong answer you get without it

A JOIN between two `Distributed` tables is executed **locally on each shard**.
That is correct only when both are sharded on the join key.

`orders` and `order_items` are both sharded on `order_id`, so joining them is
local and complete. `products` is sharded on `product_id`, and its rows for a
given order can live on any shard — so that join is `GLOBAL`, which makes the
initiator evaluate the subquery once and send the result everywhere.

Dropping the keyword raises no error. Each shard would join against its own
slice of the catalogue and the output would be quietly short. A wrong number,
not a stack trace, and nothing to notice until someone reconciles the mart
against the source by hand.

### Idempotency, and why the job can be re-run freely

The mart is a `ReplacingMergeTree` keyed by `(day, category)` with a
`computed_at` version. Recomputing a day inserts a new row and the old one is
replaced. A backfill is therefore safe by construction, which is worth more
than any amount of care about not running a job twice.

## Failure drills

### A task that fails

```bash
make dag-run                       # 00_docker_smoke: one green, one red
make dag-state DAG=00_docker_smoke
```

Watch the failing task go `up_for_retry` before `failed`, and check that
`airflow_task_finish_total{state="failed"}` appears in Prometheus. That metric
is what `AirflowTaskFailed` in
`../02-monitoring/prometheus/rules/04-etl.yml` watches.

### A scheduler that stops

```bash
docker stop airflow-scheduler
```

The UI keeps working. DAGs are listed, history is there, everything looks
healthy — and nothing gets scheduled, because the UI and the scheduler are
different processes. This is the failure `AirflowSchedulerNotHeartbeating`
exists for, and the reason a green Airflow page proves less than it appears to.

```bash
docker start airflow-scheduler
```

### A DAG that will not import

Add a stray `import nonexistent` to any file in `dags/` and wait half a
minute.

```bash
make dag-errors
```

The DAG does not appear in the UI as broken. It does not appear at all, which
is indistinguishable from a file nobody has written yet. `make dag-errors` and
the `AirflowDagImportErrors` alert are the only two places it shows.

## Airflow 3 traps

Every one of these cost time here, and they share a shape: the DAG looks fine
until something runs it.

**A manual run has no `logical_date` and no `data_interval_end`.** Both are
undefined, not empty. Jinja in Airflow uses `StrictUndefined`, so even
`{{ data_interval_end or dag_run.run_after }}` fails — it raises on the
undefined name before evaluating the `or`. `{{ dag_run.run_after | ds }}` works
because that is an attribute of an object that exists.

The failure comes at task execution, not at DAG parse. The DAG imports
cleanly, the schedule works, and the Trigger button kills the task.

**Every component needs the same `AIRFLOW__API_AUTH__JWT_SECRET`.** The
scheduler issues the token a task uses to call the execution API, and the
api-server verifies it. Without a fixed value each generates its own, and the
task dies with `Invalid auth token` before its operator ever runs — which
reads as a DockerOperator problem and is not.

**`SimpleAuthManager` cannot take a password from configuration.**
`simple_auth_manager_users` is `username:role`; passwords are always generated
into a file inside the container, and the value changes whenever the volume
does. This stand sets `simple_auth_manager_all_admins` and has no login at
all. Anything that reaches port 8081 has full control — acceptable while that
is one laptop, and the first thing to change otherwise.

**`mount_tmp_dir=False` on every DockerOperator.** Airflow otherwise mounts a
temporary directory that exists inside the scheduler container and not on the
host the Docker daemon runs on.

**`network_mode="dataplatform"` on every DockerOperator.** Without it the job
container lands on the default bridge, where `clickhouse-01` does not resolve,
and fails on a connection timeout that looks like a warehouse problem.

**`airflow dags list-runs` takes the dag id positionally.** Not `-d`, which
was the Airflow 2 spelling, and not `--dag-id`. The wrong form exits with a
usage message rather than an error, so a broken command looks like a command
that found nothing.

## What continuous integration does not cover

The workflow starts everything except the ClickHouse cluster and skips the two
checks that need it: running the mart job and verifying what it wrote.

The reason is memory. Eight ClickHouse nodes at 2 GiB is 16 GiB before
anything else, and a GitHub runner has 16 GiB in total. Even without them this
is the tightest stack in the repository — twenty-six containers — which is why
the workflow prints `free -h` before starting.

CI therefore covers: the compose files and every include, both job images
building, all four Airflow components starting, the API answering, both DAGs
parsing without import errors, and Prometheus receiving Airflow metrics.

**Locally, on a machine that can hold the cluster:**

```bash
make up
cd ../03-dbms && make connector && cd ../04-etl
make test                    # 14 checks, nothing skipped
make mart-job                # the job, directly
make mart                    # what it wrote
make mart-run                # the same through Airflow
make dag-state DAG=10_daily_sales
```

Docker needs a generous allocation: 48 GiB is comfortable for the full
platform, 24 is about the floor.

## Commands

```
make help          list every command
make up            start the whole platform including Airflow
make up-light      start without the ClickHouse cluster
make jobs          build the job images
make test          validate configs, then the running stack
make clean         stop everything and wipe every volume

make af-status     are the four components up, is the API answering
make af-logs       follow the Airflow components
make dags          which DAGs are parsed
make dag-errors    DAG files that failed to import
make dag-run       trigger the smoke DAG
make dag-state     recent runs of a DAG (DAG=... to choose)

make mart-job      run the mart job directly (DAY=..., DRY_RUN=1)
make mart-run      trigger the mart DAG
make mart          what is in the mart
```
