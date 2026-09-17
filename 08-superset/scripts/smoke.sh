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

IMAGE="dataplatform/superset:${SUPERSET_VERSION}"
SUPERSET="http://localhost:${SUPERSET_PORT}"

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
#  Checked before anything is started, and against the image rather than a
#  running container: a driver missing here fails later, elsewhere, with an
#  error that mentions neither the build nor the install.
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
# use whatever is first on the path, which is the venv here but need not stay
# that way — and the whole class of failure this guards against is a package
# reachable from one interpreter and not the other.
for mod in psycopg2 clickhouse_connect; do
  if docker run --rm --entrypoint "$VENV_PY" "$IMAGE" -c "import ${mod}" >/dev/null 2>&1; then
    pass "${mod} is importable from ${VENV_PY}"
  else
    fail "${mod} is NOT importable from ${VENV_PY} — installed into the wrong interpreter?"
  fi
done

# Importable is not the same as registered. Superset asks SQLAlchemy for a
# `clickhousedb://` dialect, and a driver that imports cleanly while failing
# to register produces an error about an unknown dialect when the connection
# is added — several steps away from the cause.
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

# The init container must have finished, not merely been created. Everything
# below depends on the migration and on `superset init` having run.
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
#
#  Asserting the tables are in Postgres is how that stays visible.
# ---------------------------------------------------------------------------
info "The metadata database"

tables=$(pg "SELECT count(*) FROM information_schema.tables WHERE table_schema = 'public'")
[ "${tables:-0}" -ge 20 ] 2>/dev/null \
  && pass "${tables} tables in Postgres — the migration ran against the right database" \
  || fail "${tables:-0} tables in Postgres, expected at least 20 — did Superset fall back to SQLite?"

# `superset init` creates the default roles. Without it the UI loads, login
# succeeds, and every page is forbidden.
roles=$(pg "SELECT count(*) FROM ab_role")
[ "${roles:-0}" -ge 4 ] 2>/dev/null \
  && pass "${roles} roles exist — superset init ran" \
  || fail "${roles:-0} roles — superset init did not run, every page will be forbidden"

admins=$(pg "SELECT count(*) FROM ab_user WHERE username = '${ADMIN_USER}'")
[ "${admins:-0}" -ge 1 ] 2>/dev/null \
  && pass "the ${ADMIN_USER} account exists" \
  || fail "no ${ADMIN_USER} account — check: docker compose logs superset-init"

# ---------------------------------------------------------------------------
#  4. The application
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

# The version Superset thinks it is, from inside. Confirms the application
# starts far enough to run a CLI command against its own configuration, which
# a broken superset_config.py would prevent.
version_out=$(sup superset version)
printf '%s' "$version_out" | grep -q "${SUPERSET_VERSION%%.*}" \
  && pass "Superset reports version ${SUPERSET_VERSION}" \
  || fail "Superset did not report version ${SUPERSET_VERSION}: ${version_out:-nothing}"

# ---------------------------------------------------------------------------
#  5. Caching
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

# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$PASSED" "$FAILED" "$SKIPPED"

[ "$FAILED" -eq 0 ]
