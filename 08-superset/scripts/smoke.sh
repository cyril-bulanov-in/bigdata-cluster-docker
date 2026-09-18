#!/usr/bin/env bash
#
# Smoke test for the dashboard stack.
#
# What can be broken while the container is green:
#
#   a driver installed into the wrong interpreter — present on disk, absent
#     from the application, discovered only when a query runs
#   `superset init` skipped, so the UI loads, you log in, and every page is
#     forbidden: an authenticated admin with rights to nothing
#   the schema migrated against SQLite because the Postgres driver was missing
#     and Superset fell back to its default
#   the warehouse connection registered but pointing at the native port, which
#     hangs rather than failing
#   a dataset attached to a database that does not exist — the state Superset's
#     documented YAML import produces silently
#   a dashboard with no position_json, which renders every chart stacked in one
#     column and looks like a styling problem
#   StatsD mapping rules that match nothing, so every metric lands in the
#     catch-all and every Grafana panel is empty for a reason no error reports
#
# Usage:  ./scripts/smoke.sh          (or: make smoke)

set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose"

read_env() {
  grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

SUPERSET_VERSION="$(read_env SUPERSET_VERSION .env)"; SUPERSET_VERSION="${SUPERSET_VERSION:-6.1.0}"
SUPERSET_PORT="$(read_env SUPERSET_PORT .env)";       SUPERSET_PORT="${SUPERSET_PORT:-8089}"
ADMIN_USER="$(read_env SUPERSET_ADMIN_USER .env)";    ADMIN_USER="${ADMIN_USER:-admin}"
DB_NAME="$(read_env SUPERSET_DB_NAME .env)";          DB_NAME="${DB_NAME:-superset}"
DB_USER="$(read_env SUPERSET_DB_USER .env)";          DB_USER="${DB_USER:-superset}"
CH_NAME="$(read_env SUPERSET_CLICKHOUSE_NAME .env)";  CH_NAME="${CH_NAME:-ClickHouse marts}"
CH_MARTS="$(read_env CLICKHOUSE_MARTS_DB .env)";      CH_MARTS="${CH_MARTS:-marts_marts}"
PROM_PORT="$(read_env PROMETHEUS_PORT ../02-monitoring/.env)"; PROM_PORT="${PROM_PORT:-9090}"

# Set where there is no warehouse to read columns from. The environment wins
# over the file, because CI sets it as a job-level variable rather than
# editing .env.
SKIP_DATASETS="${SUPERSET_SKIP_DATASETS:-$(read_env SUPERSET_SKIP_DATASETS .env)}"
SKIP_DATASETS="${SKIP_DATASETS:-0}"

IMAGE="dataplatform/superset:${SUPERSET_VERSION}"
SUPERSET="http://localhost:${SUPERSET_PORT}"
PROM="http://localhost:${PROM_PORT}"

EXPECTED_DATASETS="daily_sales_by_category customer_order_summary recon_orders_by_source"
DASHBOARD_SLUG="platform-overview"
EXPECTED_CHARTS=8

# The virtualenv Superset actually runs from. Not a detail: a package
# installed with the system pip lands outside it and is invisible to the
# application, which is how three separate builds of this image "succeeded"
# while shipping no driver at all.
VENV_PY="/app/.venv/bin/python"

UI_TIMEOUT=180
METRIC_TIMEOUT=120
METRIC_INTERVAL=10

PASSED=0; FAILED=0; SKIPPED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

sup() { $COMPOSE exec -T superset "$@" 2>/dev/null | tr -d '\r' || true; }
pg()  { $COMPOSE exec -T superset-postgres psql -U "$DB_USER" -d "$DB_NAME" -tAc "$1" 2>/dev/null | tr -d '\r' || true; }

# ---------------------------------------------------------------------------
#  1. The image
# ---------------------------------------------------------------------------
info "The image"

if docker image inspect "$IMAGE" >/dev/null 2>&1; then
  pass "${IMAGE} exists"
else
  fail "${IMAGE} is missing — run: docker compose build superset-init"
  printf '\n  Nothing else can be checked without it.\n\n'
  exit 1
fi

# Imported through the venv's interpreter explicitly. `python -c` alone would
# use whatever is first on the path — and the whole class of failure this
# guards against is a package reachable from one interpreter and not the other.
for mod in psycopg2 clickhouse_connect statsd; do
  if docker run --rm --entrypoint "$VENV_PY" "$IMAGE" -c "import ${mod}" >/dev/null 2>&1; then
    pass "${mod} is importable from ${VENV_PY}"
  else
    fail "${mod} is NOT importable from ${VENV_PY} — installed into the wrong interpreter?"
  fi
done

if docker run --rm --entrypoint "$VENV_PY" "$IMAGE" -c \
     "import clickhouse_connect.cc_sqlalchemy" >/dev/null 2>&1; then
  pass "the clickhousedb:// dialect registers"
else
  fail "the clickhousedb:// dialect does not register"
fi

# ---------------------------------------------------------------------------
#  2. Is it running
# ---------------------------------------------------------------------------
if ! $COMPOSE ps --services 2>/dev/null | grep -qx superset; then
  printf '\n\033[31mSuperset is not running.\033[0m\n\n  make up\n  make test\n\n'
  exit 1
fi

info "The containers"

for c in superset superset-postgres superset-redis superset-statsd; do
  state=$($COMPOSE ps --format '{{.Name}} {{.State}}' 2>/dev/null | awk -v n="$c" '$1 == n {print $2}' || true)
  [ "$state" = "running" ] \
    && pass "$c is running" \
    || fail "$c is ${state:-absent}"
done

init_state=$(docker inspect -f '{{.State.Status}}:{{.State.ExitCode}}' superset-init 2>/dev/null || echo "absent")
[ "$init_state" = "exited:0" ] \
  && pass "superset-init completed successfully" \
  || fail "superset-init is ${init_state} — check: docker compose logs superset-init"

# ---------------------------------------------------------------------------
#  3. The metadata database
# ---------------------------------------------------------------------------
#  Superset defaults to SQLite when it cannot reach anything else, and it does
#  so at startup without failing. A stack whose Postgres driver was missing
#  therefore runs perfectly and loses every dashboard on the next rebuild —
#  the tables are in a file inside the container.
# ---------------------------------------------------------------------------
info "The metadata database"

tables=$(pg "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
[ "${tables:-0}" -ge 20 ] 2>/dev/null \
  && pass "${tables} tables in Postgres — the migration ran against the right database" \
  || fail "${tables:-0} tables in Postgres, expected at least 20 — did Superset fall back to SQLite?"

roles=$(pg "SELECT count(*) FROM ab_role")
[ "${roles:-0}" -ge 4 ] 2>/dev/null \
  && pass "${roles} roles exist — superset init ran" \
  || fail "${roles:-0} roles — superset init did not run, every page will be forbidden"

admins=$(pg "SELECT count(*) FROM ab_user WHERE username = '${ADMIN_USER}'")
[ "${admins:-0}" -ge 1 ] 2>/dev/null \
  && pass "the ${ADMIN_USER} account exists" \
  || fail "no ${ADMIN_USER} account — check: docker compose logs superset-init"

# ---------------------------------------------------------------------------
#  4. The warehouse connection
# ---------------------------------------------------------------------------
#  Registered by register.sh on every start, so a fresh volume comes back with
#  it rather than waiting for someone to click it in.
#
#  Checked even without a warehouse: registering the URI is writing a string,
#  and needs nobody to be listening.
# ---------------------------------------------------------------------------
info "The warehouse connection"

conn_count=$(pg "SELECT count(*) FROM dbs WHERE database_name = '${CH_NAME}'")
[ "${conn_count:-0}" -ge 1 ] 2>/dev/null \
  && pass "the '${CH_NAME}' connection is registered" \
  || fail "no connection named '${CH_NAME}' — check: docker compose logs superset-init"

if [ "${conn_count:-0}" -ge 1 ]; then
  uri=$(pg "SELECT sqlalchemy_uri FROM dbs WHERE database_name = '${CH_NAME}' LIMIT 1")

  printf '%s' "$uri" | grep -q '^clickhousedb://' \
    && pass "it uses the clickhousedb:// dialect" \
    || fail "the URI is '${uri:-empty}' — expected clickhousedb://"

  # clickhouse-connect speaks HTTP on 8123. Pointed at the native 9000 it
  # hangs rather than failing, because that port accepts the connection and
  # then waits for bytes that never make sense.
  printf '%s' "$uri" | grep -q ':8123/' \
    && pass "it points at the HTTP port" \
    || fail "the URI does not use port 8123 — the native port hangs rather than failing"

  printf '%s' "$uri" | grep -q "/${CH_MARTS}\$" \
    && pass "it points at the ${CH_MARTS} database" \
    || fail "the URI does not end in /${CH_MARTS}"
fi

# ---------------------------------------------------------------------------
#  5. The datasets
# ---------------------------------------------------------------------------
#  Registered from a file, or deliberately not.
#
#  datasets.py asks ClickHouse what columns each mart has, because a
#  hand-written column list drifts the moment a model changes. So it cannot
#  run where the warehouse is absent, and SUPERSET_SKIP_DATASETS=1 says that
#  was a decision rather than a failure.
# ---------------------------------------------------------------------------
info "The datasets"

if [ "$SKIP_DATASETS" = "1" ]; then
  skip "datasets — SUPERSET_SKIP_DATASETS is set, no warehouse to read columns from"
  skip "dataset columns — datasets were not registered"
  skip "dataset metrics — datasets were not registered"
else
  for ds in $EXPECTED_DATASETS; do
    n=$(pg "SELECT count(*) FROM tables WHERE table_name = '${ds}'")
    [ "${n:-0}" -ge 1 ] 2>/dev/null \
      && pass "dataset ${ds} is registered" \
      || fail "dataset ${ds} is missing — check: docker compose logs superset-init"
  done

  # Columns are fetched from ClickHouse rather than declared, so a dataset
  # with none means fetch_metadata() failed quietly — the dataset exists and
  # every chart built on it will have nothing to select.
  for ds in $EXPECTED_DATASETS; do
    cols=$(pg "SELECT count(*) FROM table_columns c JOIN tables t ON t.id = c.table_id WHERE t.table_name = '${ds}'")
    [ "${cols:-0}" -ge 3 ] 2>/dev/null \
      && pass "${ds} has ${cols} columns" \
      || fail "${ds} has ${cols:-0} columns — fetch_metadata() found nothing"
  done

  # Metrics defined on the dataset rather than in individual charts. Two
  # charts that each define "revenue" will eventually disagree; one definition
  # on the dataset is inherited by every chart.
  metrics=$(pg "SELECT count(*) FROM sql_metrics m JOIN tables t ON t.id = m.table_id WHERE t.table_name IN ('daily_sales_by_category','customer_order_summary','recon_orders_by_source')")
  [ "${metrics:-0}" -ge 9 ] 2>/dev/null \
    && pass "${metrics} metrics defined on the datasets" \
    || fail "${metrics:-0} metrics, expected at least 9"
fi

# Every dataset that exists must point at a database that exists. Checked even
# when registration was skipped: a dangling dataset is the failure Superset's
# YAML import path produces silently, and an empty table trivially passes.
dangling=$(pg "SELECT count(*) FROM tables t LEFT JOIN dbs d ON d.id = t.database_id WHERE d.id IS NULL")
[ "${dangling:-1}" = "0" ] \
  && pass "no dataset points at a missing database" \
  || fail "${dangling} dataset(s) attached to a database that does not exist"

# ---- does the connection actually work -------------------------------------
if ! docker ps --format '{{.Names}}' | grep -qx clickhouse-01; then
  skip "querying the warehouse — ClickHouse is not running"
  skip "the marts are visible — ClickHouse is not running"
elif [ "${conn_count:-0}" -lt 1 ]; then
  skip "querying the warehouse — the connection is not registered"
  skip "the marts are visible — the connection is not registered"
else
  # Through Superset's own connection rather than a fresh one, so this
  # exercises the stored URI including its decrypted password.
  query_out=$(sup "$VENV_PY" -c "
from superset.app import create_app
app = create_app()
with app.app_context():
    from superset import db
    from superset.models.core import Database
    d = db.session.query(Database).filter_by(database_name='${CH_NAME}').one()
    with d.get_sqla_engine() as e:
        print(e.connect().exec_driver_sql('SELECT 1').scalar())
")
  printf '%s' "$query_out" | grep -q '^1$' \
    && pass "a query through the stored connection returns" \
    || fail "querying through the connection failed: ${query_out:-no output}"

  marts=$($COMPOSE exec -T clickhouse-01 clickhouse-client \
    --query "SELECT count() FROM system.tables WHERE database = '${CH_MARTS}'" 2>/dev/null | tr -d '\r' || true)
  [ "${marts:-0}" -ge 3 ] 2>/dev/null \
    && pass "${marts} marts exist in ${CH_MARTS}" \
    || skip "only ${marts:-0} marts in ${CH_MARTS} — run: cd ../07-dbt && make dbt-build-all"
fi

# ---------------------------------------------------------------------------
#  6. The dashboard
# ---------------------------------------------------------------------------
#  Built by dashboard.py from code rather than imported from an exported
#  bundle, so these checks are about what goes wrong when a layout is written
#  by hand.
#
#  A position_json whose `parents` lists are wrong loads with every chart
#  stacked in a heap, and a layout referencing a chart that was never created
#  leaves a gap where a panel should be. Neither raises.
# ---------------------------------------------------------------------------
info "The dashboard"

if [ "$SKIP_DATASETS" = "1" ]; then
  skip "the dashboard — it needs the datasets, which were not registered"
  skip "its charts — the dashboard was not built"
  skip "its layout — the dashboard was not built"
else
  dash=$(pg "SELECT count(*) FROM dashboards WHERE slug = '${DASHBOARD_SLUG}'")
  [ "${dash:-0}" -ge 1 ] 2>/dev/null \
    && pass "the '${DASHBOARD_SLUG}' dashboard exists" \
    || fail "no dashboard with slug '${DASHBOARD_SLUG}' — check: docker compose logs superset-init"

  charts=$(pg "SELECT count(*) FROM slices")
  [ "${charts:-0}" -ge "$EXPECTED_CHARTS" ] 2>/dev/null \
    && pass "${charts} charts exist" \
    || fail "${charts:-0} charts, expected at least ${EXPECTED_CHARTS}"

  # Attached, not merely existing. A chart created but left off the dashboard
  # is invisible, and one the layout names but never created leaves a gap.
  attached=$(pg "SELECT count(*) FROM dashboard_slices ds JOIN dashboards d ON d.id = ds.dashboard_id WHERE d.slug = '${DASHBOARD_SLUG}'")
  [ "${attached:-0}" -ge "$EXPECTED_CHARTS" ] 2>/dev/null \
    && pass "${attached} charts attached to the dashboard" \
    || fail "${attached:-0} charts attached, expected ${EXPECTED_CHARTS}"

  # The same dangling check as for datasets, one level up.
  orphans=$(pg "SELECT count(*) FROM slices s LEFT JOIN tables t ON t.id = s.datasource_id WHERE s.datasource_type = 'table' AND t.id IS NULL")
  [ "${orphans:-1}" = "0" ] \
    && pass "no chart points at a missing dataset" \
    || fail "${orphans} chart(s) attached to a dataset that does not exist"

  # position_json is what makes the layout a layout. Superset renders a
  # dashboard without one, stacking every chart in a single column — which
  # looks like a styling problem rather than a missing field.
  layout=$(pg "SELECT length(position_json) FROM dashboards WHERE slug = '${DASHBOARD_SLUG}'")
  [ "${layout:-0}" -gt 100 ] 2>/dev/null \
    && pass "the dashboard has a layout (${layout} bytes of position_json)" \
    || fail "position_json is ${layout:-empty} — the charts would stack in one column"
fi

# ---------------------------------------------------------------------------
#  7. Metrics
# ---------------------------------------------------------------------------
#  Superset speaks StatsD and serves no Prometheus endpoint, so a second
#  exporter translates. Everything here is about the translation, because that
#  is where this stack went wrong three times in one sitting.
#
#  The mapping rules in statsd/mapping.yml were invented by analogy the first
#  time and matched nothing. Then the API rules used globs, which match a
#  whole dot-separated segment rather than part of one, so they matched
#  nothing either. Then two cache metrics turned out to exist that nobody had
#  thought to map.
#
#  None of that raised an error. A rule that matches nothing is simply never
#  applied, and the metric falls through to the catch-all — which is exactly
#  what the catch-all is for, and why the last check here is the important
#  one.
# ---------------------------------------------------------------------------
info "Metrics (waiting up to ${METRIC_TIMEOUT}s)"

if ! docker ps --format '{{.Names}}' | grep -qx prometheus; then
  skip "the exporter is scraped — Prometheus is not running"
  skip "Superset metrics exist — Prometheus is not running"
  skip "nothing falls through to the catch-all — Prometheus is not running"
else
  # Prometheus polls Docker for new containers every 30s, so a container
  # started in the same wave is not discovered on the first pass.
  waited=0
  targets=0
  while :; do
    body=$(curl -fsS --max-time 10 "${PROM}/api/v1/targets?state=active" 2>/dev/null || true)
    targets=$(printf '%s' "$body" | grep -o '"job": *"superset-statsd"' | wc -l | tr -d ' ' || true)
    [ "${targets:-0}" -ge 1 ] && break
    [ "$waited" -ge "$METRIC_TIMEOUT" ] && break
    sleep "$METRIC_INTERVAL"; waited=$((waited + METRIC_INTERVAL))
  done
  [ "${targets:-0}" -ge 1 ] \
    && pass "Prometheus is scraping the Superset exporter (after ${waited}s)" \
    || fail "no superset-statsd target after ${METRIC_TIMEOUT}s — check the prometheus labels"

  # At least the query metric, which appears as soon as anyone opens a chart.
  # Absent means either nobody has, or the mapping stopped matching.
  named=$(curl -fsS --max-time 10 "${PROM}/api/v1/label/__name__/values" 2>/dev/null \
    | tr ',' '\n' | grep -c -o 'superset_[a-z_]*' || true)
  [ "${named:-0}" -ge 3 ] 2>/dev/null \
    && pass "${named} superset_* metric names present" \
    || skip "only ${named:-0} superset_* names — open a dashboard and re-run"

  # ---- the check that found every mistake in this stack ------------------
  #  superset_other is the catch-all. Anything in it is a metric Superset
  #  emits that no rule covers — which is not an error, and is exactly the
  #  thing that would otherwise be noticed months later as an empty Grafana
  #  panel.
  #
  #  A warning rather than a failure: a Superset upgrade adding a metric is
  #  normal, and the right response is to add a rule, not to go red.
  unmapped=$(curl -fsS --max-time 10 --get \
    --data-urlencode 'query=count(superset_other)' \
    "${PROM}/api/v1/query" 2>/dev/null \
    | grep -o '"[0-9]*"\]' | head -1 | tr -d '"]' || true)

  if [ -z "${unmapped}" ] || [ "${unmapped}" = "0" ]; then
    pass "nothing is falling through to superset_other"
  else
    skip "${unmapped} metric(s) in superset_other — a name no rule covers yet"
    curl -fsS --max-time 10 "${PROM}/api/v1/query?query=superset_other" 2>/dev/null \
      | python3 -c "
import json, sys
try:
    for r in json.load(sys.stdin)['data']['result'][:8]:
        print('        ' + str(r['metric'].get('metric')))
except Exception:
    pass
" || true
  fi
fi

# ---------------------------------------------------------------------------
#  8. The application
# ---------------------------------------------------------------------------
#  /health answers before Superset has finished loading its metadata, so a
#  healthy container says the process is alive and nothing more. The login
#  page requires the application to be serving properly.
# ---------------------------------------------------------------------------
info "The application (waiting up to ${UI_TIMEOUT}s)"

ui_ok=0
deadline=$(( $(date +%s) + UI_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  code=$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "${SUPERSET}/login/" 2>/dev/null || true)
  if [ "$code" = "200" ]; then
    ui_ok=1; break
  fi
  sleep 5
done
[ "$ui_ok" = "1" ] \
  && pass "the login page answers on ${SUPERSET}" \
  || fail "the login page did not answer within ${UI_TIMEOUT}s"

curl -fsS --max-time 10 "${SUPERSET}/health" 2>/dev/null | grep -qi 'ok' \
  && pass "/health reports OK" \
  || fail "/health does not report OK"

version_out=$(sup superset version)
printf '%s' "$version_out" | grep -q "${SUPERSET_VERSION%%.*}" \
  && pass "Superset reports version ${SUPERSET_VERSION}" \
  || fail "Superset did not report version ${SUPERSET_VERSION}: ${version_out:-nothing}"

# ---------------------------------------------------------------------------
#  9. Caching
# ---------------------------------------------------------------------------
#  Not decoration. Without a backing store Superset keeps dashboard filter
#  state in the metadata database, and the UI grows slower with every
#  interaction — which reads as Superset being slow rather than as a cache
#  that was never configured.
# ---------------------------------------------------------------------------
info "Caching"

$COMPOSE exec -T superset-redis redis-cli ping 2>/dev/null | grep -qi pong \
  && pass "Redis answers" \
  || fail "Redis does not answer"

# Read from the running application rather than from the file: a config that
# failed to import leaves Superset running on its defaults, silently.
cache_type=$(sup "$VENV_PY" -c \
  "from superset.app import create_app; a=create_app(); print(a.config['FILTER_STATE_CACHE_CONFIG']['CACHE_TYPE'])")
printf '%s' "$cache_type" | grep -qi 'redis' \
  && pass "filter state is cached in Redis" \
  || fail "filter state cache is '${cache_type:-unset}' — superset_config.py may not have been loaded"

# The StatsD logger, read the same way. A config that imported but left
# STATS_LOGGER at its default sends every metric nowhere, and the exporter
# stays up and empty.
stats_logger=$(sup "$VENV_PY" -c \
  "from superset.app import create_app; a=create_app(); print(type(a.config['STATS_LOGGER']).__name__)")
printf '%s' "$stats_logger" | grep -qi 'statsd' \
  && pass "the StatsD logger is configured (${stats_logger})" \
  || fail "STATS_LOGGER is '${stats_logger:-unset}' — metrics go nowhere and the exporter stays empty"

# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$PASSED" "$FAILED" "$SKIPPED"

if [ "$SKIPPED" -gt 0 ]; then
  echo "  Some checks need the warehouse or Prometheus. Run the full test from"
  echo "  a platform started with the ClickHouse cluster."
  echo ""
fi

[ "$FAILED" -eq 0 ]
