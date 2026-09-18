# 08-superset — dashboards

Superset reading the dbt marts, with its connection, datasets and dashboard
all built from files rather than clicked into the UI.

Step 8 of [bigdata-cluster-docker](../README.md). It **includes** `07-dbt` and
everything below it, so `make up` here starts the whole platform.

## Quick start

```bash
cp .env.example .env
cp ../07-dbt/.env.example ../07-dbt/.env       # if not already there
cp ../06-spark/.env.example ../06-spark/.env
cp ../05-minio/.env.example ../05-minio/.env
cp ../04-etl/.env.example ../04-etl/.env
cp ../03-dbms/.env.example ../03-dbms/.env
cp ../02-monitoring/.env.example ../02-monitoring/.env
cp ../01-kafka/.env.example ../01-kafka/.env
chmod +x scripts/smoke.sh superset/register.sh

make up
make test
```

| | |
|---|---|
| Superset | http://localhost:8089 (admin / admin) |
| Dashboard | http://localhost:8089/superset/dashboard/platform-overview/ |
| dbt docs | http://localhost:8088 |
| Airflow | http://localhost:8081 |
| Grafana | http://localhost:3000 |

Port 8089 rather than Superset's own 8088, which the dbt documentation site
in step 7 already occupies.

## Everything is built from files

A connection clicked into the UI, a dataset created by hand, a dashboard
someone laid out in a browser — none of them survive `make clean`, and none of
them are part of the project. So all three are constructed at startup by
`superset/register.sh`, which runs on every start because each step is
idempotent.

| What | Built by | How it is matched |
|---|---|---|
| The ClickHouse connection | `superset set-database-uri` | by name |
| Three datasets over the marts | `superset/datasets.py` | by table and schema |
| Eight charts and a dashboard | `superset/dashboard.py` | by name and slug |

Superset has no provisioning directory the way Grafana does. Everything lives
in its metadata database, and the documented file-based path is an export and
import of YAML.

### Why the scripts, and not the documented YAML import

A bundle links each dataset to its database by UUID, and that UUID is
generated when the database is registered. A bundle exported from one
installation therefore points at a database that does not exist in another —
**and the import succeeds anyway**, producing datasets attached to nothing.
Nobody finds out until a chart is opened.

Looking the database up by name cannot miss silently. The script raises if it
is absent.

The dashboard is the same argument from a different angle. An export captures
the layout exactly, which is the genuinely tedious part — but it is a machine
artifact. A diff against it says which UUID changed, not which chart. Here
every chart is a dozen lines naming its dataset, its metric and its type, and
a reviewer can read what the dashboard is for.

The price is `position_json`, which the export would have given for free. It
is a flat dictionary of nodes referencing each other by id, where every node
also lists its ancestors — get that list wrong and the dashboard loads with
the charts stacked in a heap rather than raising.

### Metrics are defined on the dataset, not in charts

A metric defined inside a chart is invisible to every other chart, and two
charts that each define "revenue" will eventually disagree. The nine metrics
here live on the three datasets and every chart inherits them.

One of them is worth pointing at: `avg_order_value` divides the sums rather
than averaging a stored ratio. Averaging would weight a two-order day the same
as a two-thousand-order day.

## Five ways to succeed and do nothing

This step produced an unusual concentration of one failure mode: something
reports success and has no effect. It is the reason the smoke test here is as
long as it is.

**A package installed into the wrong interpreter.** Superset 6 runs from a
virtualenv at `/app/.venv`, built by `uv`, which puts no `pip` inside it. So
`pip install` as root succeeds and installs into the system interpreter that
Superset never consults:

```
ModuleNotFoundError: No module named 'psycopg2'
... File "/app/.venv/lib/python3.10/site-packages/sqlalchemy/..."
```

The path in that traceback is the whole diagnosis and is easy to read past —
the error names a module while the fix is about an interpreter. Three builds
"succeeded" before this was found. The Dockerfile now imports each driver
explicitly as its last step, so a wrong install fails the build.

Note also that `/app/.venv/bin/pip` does not exist (exit 127) and
`python -m pip` reports no module named pip. `uv pip install --python` is what
works.

**A metrics endpoint that is not one.** Superset serves no Prometheus
endpoint; everything goes out over StatsD. Pointing service discovery at
`/health` looks like a free liveness signal — that endpoint returns the word
`OK`, not exposition format, so Prometheus marks the target down on a parse
error and the alert fires for ever. An alert that always fires is worse than
no alert. Liveness comes from cAdvisor instead.

**Mapping rules that match nothing.** The first `statsd/mapping.yml` invented
names by analogy with Airflow. Not one rule matched. A rule that matches
nothing is not an error — it is simply never applied, and the metric falls
through.

**A glob that cannot match.** The second version used `superset.*RestApi.*`,
which can never match `superset.DashboardRestApi.get`: a glob `*` in this
exporter matches a whole dot-separated segment, not part of one. Those rules
are regex now.

**A silent fallback to SQLite.** Superset defaults to SQLite when it cannot
reach its configured database, at startup, without failing. A stack whose
Postgres driver was missing runs perfectly and loses every dashboard on the
next rebuild, because the tables are in a file inside the container. The smoke
test counts tables in Postgres for that reason.

Only the first of these raised anything at all, and it raised in the wrong
place.

### The catch-all that found three of them

The last rule in `statsd/mapping.yml` keeps unmatched metrics under
`superset_other` rather than dropping them:

```yaml
  - match: '^superset\.(.+)$'
    match_type: regex
    name: "superset_other"
    labels:
      metric: "$1"
```

It caught the invented names, the glob problem, and two cache metrics
(`loaded_from_cache`, `loading_from_cache`) nobody knew existed. Without it,
each would have been noticed as an empty Grafana panel, months later.

The smoke test asserts nothing is falling through — as a skip rather than a
failure, because a Superset upgrade adding a metric is normal and the answer
is to add a rule, not to go red.

### And one that takes down the application

StatsD is fire-and-forget over UDP, so a missing exporter should cost nothing.
That is true of *sending* and not of *constructing*: `StatsClient` resolves
the hostname in its constructor, so `superset_config.py` raises at import time
if the exporter is not resolvable —

```
socket.gaierror: [Errno -2] Name or service not known
Failed to create app
```

— and that takes down every Superset command, `db upgrade` included. The
config now wraps the construction, because losing metrics is a degradation
and losing the application is an outage.

## What continuous integration does not cover

The workflow starts only this stack's four services. Superset needs nothing
from Kafka, ClickHouse or Spark to prove it works, and booting seven stacks to
reach the same checks would spend twenty minutes on nothing.

What that costs is everything downstream of the warehouse. `datasets.py` asks
ClickHouse what columns each mart has — because a hand-written column list
drifts the moment a model changes — so it cannot run there, and the dashboard
needs the datasets.

`SUPERSET_SKIP_DATASETS=1` says that was a decision rather than a failure. The
alternative, wrapping the step in `|| true`, would hide a real failure just as
quietly.

**CI covers:** the image building with all three drivers importable from the
venv Superset runs from, the dialect registering, the schema migrating against
Postgres rather than SQLite, `superset init` having created the roles, the
admin account, the connection registered with the right dialect and port, no
dangling datasets, the login page serving, Redis answering, and the StatsD
logger being configured rather than silently at its default.

**Locally, on a machine that can hold the cluster:**

```bash
make up
make test          # 41 checks, nothing skipped
```

The full run additionally covers the datasets and their columns, the dashboard
and its layout, a query through the stored connection, and that nothing is
falling through to `superset_other`.

## Commands

```
make help                list every command
make up                  start the whole platform including Superset
make up-light            start without the ClickHouse cluster
make test                the smoke test
make clean               stop everything and wipe every volume

make superset-status     is it up and answering
make drivers             are the drivers where Superset looks
make superset-log        follow Superset and its init container
make superset-shell      a shell inside Superset
make superset-reset-admin  reset the admin password to what .env says
```
