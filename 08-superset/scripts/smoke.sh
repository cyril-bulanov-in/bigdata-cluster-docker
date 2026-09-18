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
#   a dataset attached to a database that does not exist — the state the YAML
#     import path produces silently, and the reason datasets.py looks the
#     database up by name instead
#   /health answering before the application has finished loading, which it
#     does, so a healthy container proves less than it looks
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

IMAGE="dataplatform/superset:${SUPERSET_VERSION}"
SUPERSET="http://localhost:${SUPERSET_PORT}"

EXPECTED_DATASETS="daily_sales_by_category customer_order_summary recon_orders_by_source"

# The virtualenv Superset actually runs from. Not a detail: a package
# installed with the system pip lands outside it and is invisible to the
# application, which is how three separate builds of this image "succeeded"
# while shipping no driver at all.
VENV_PY="/app/.venv/bin/python"

UI_TIMEOUT=180

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

for mod in psycopg2 clickhouse_connect; do
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

for c in superset superset-postgres superset-redis; do
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
#  Registered by datasets.py on every start, so a fresh volume comes back with
#  them. A dataset created in the UI is not part of the project and does not
#  survive `make clean`.
#
#  The dangling-dataset check is the one worth having. Superset's documented
#  YAML import links a dataset to its database by UUID, and a bundle exported
#  from one installation points at a UUID that does not exist in another — the
#  import succeeds and produces datasets attached to nothing, which shows up
#  only when someone opens a chart.
# ---------------------------------------------------------------------------
info "The datasets"

for ds in $EXPECTED_DATASETS; do
  n=$(pg "SELECT count(*) FROM tables WHERE table_name = '${ds}'")
  [ "${n:-0}" -ge 1 ] 2>/dev/null \
    && pass "dataset ${ds} is registered" \
    || fail "dataset ${ds} is missing — check: docker compose logs superset-init"
done

# Every dataset must point at a database that exists.
dangling=$(pg "SELECT count(*) FROM tables t LEFT JOIN dbs d ON d.id = t.database_id WHERE d.id IS NULL")
[ "${dangling:-1}" = "0" ] \
  && pass "no dataset points at a missing database" \
  || fail "${dangling} dataset(s) attached to a database that does not exist"

# Columns are fetched from ClickHouse rather than declared, so a dataset with
# none means fetch_metadata() failed quietly — the dataset exists and every
# chart built on it will have nothing to select.
for ds in $EXPECTED_DATASETS; do
  cols=$(pg "SELECT count(*) FROM table_columns c JOIN tables t ON t.id = c.table_id WHERE t.table_name = '${ds}'")
  [ "${cols:-0}" -ge 3 ] 2>/dev/null \
    && pass "${ds} has ${cols} columns" \
    || fail "${ds} has ${cols:-0} columns — fetch_metadata() found nothing"
done

# Metrics defined on the dataset rather than in individual charts. Two charts
# that each define "revenue" will eventually disagree; one definition on the
# dataset is inherited by every chart.
metrics=$(pg "SELECT count(*) FROM sql_metrics m JOIN tables t ON t.id = m.table_id WHERE t.table_name IN ('daily_sales_by_category','customer_order_summary','recon_orders_by_source')")
[ "${metrics:-0}" -ge 9 ] 2>/dev/null \
  && pass "${metrics} metrics defined on the datasets" \
  || fail "${metrics:-0} metrics, expected at least 9"

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
#  6. The application
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
#  7. Caching
# ---------------------------------------------------------------------------
info "Caching"

$COMPOSE exec -T superset-redis redis-cli ping 2>/dev/null | grep -qi pong \
  && pass "Redis answers" \
  || fail "Redis does not answer"

cache_type=$(sup "$VENV_PY" -c \
  "from superset.app import create_app; a=create_app(); print(a.config['FILTER_STATE_CACHE_CONFIG']['CACHE_TYPE'])")
printf '%s' "$cache_type" | grep -qi 'redis' \
  && pass "filter state is cached in Redis" \
  || fail "filter state cache is '${cache_type:-unset}' — superset_config.py may not have been loaded"

# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$PASSED" "$FAILED" "$SKIPPED"

if [ "$SKIPPED" -gt 0 ]; then
  echo "  Some checks need the warehouse. Run the full test from a platform"
  echo "  started with the ClickHouse cluster."
  echo ""
fi

[ "$FAILED" -eq 0 ]
