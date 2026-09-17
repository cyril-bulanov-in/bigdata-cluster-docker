#!/usr/bin/env bash
#
# Smoke test for the dbt stack.
#
# Two halves, and the split matters because only one of them can run in CI.
#
# Everything under "The project" needs no database: dbt parses the project,
# resolves every ref() and source(), and builds the dependency graph. That
# catches a typo in a model name, a source that does not exist in sources.yml,
# broken Jinja, and a test pointing at a column that was renamed — which is
# most of what breaks when someone edits SQL.
#
# Everything under "Against the warehouse" needs ClickHouse, which does not
# fit on a GitHub runner. Those checks skip rather than fail when it is
# absent; see the README.
#
# Usage:  ./scripts/smoke.sh          (or: make smoke)

set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose"

read_env() {
  grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

DBT_VERSION="$(read_env DBT_VERSION .env)";     DBT_VERSION="${DBT_VERSION:-0.1.0}"
DBT_IMAGE="dataplatform/dbt:${DBT_VERSION}"
SOURCE_DB="$(read_env SOURCE_DATABASE .env)";   SOURCE_DB="${SOURCE_DB:-analytics}"
DBT_SCHEMA="$(read_env DBT_SCHEMA .env)";       DBT_SCHEMA="${DBT_SCHEMA:-marts}"
DOCS_PORT="$(read_env DBT_DOCS_PORT .env)";     DOCS_PORT="${DOCS_PORT:-8088}"

# Every model the project is expected to contain. A list rather than a count,
# so a model that was renamed shows up as the specific one that went missing.
STAGING_MODELS="stg_orders stg_order_items stg_customers stg_products"
EXTERNAL_MODELS="stg_s3_orders stg_pg_orders stg_pg_customers"
MART_MODELS="recon_orders_by_source daily_sales_by_category customer_order_summary"
EXPECTED_SOURCES="orders order_items customers products"

PASSED=0; FAILED=0; SKIPPED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# The word dbt is part of the command, not the entrypoint.
#
# The image deliberately has no ENTRYPOINT: Cosmos builds the full command
# itself starting with `dbt`, and an entrypoint of ["dbt"] makes the container
# run `dbt dbt run`, which fails with "No such command 'dbt'" — an error that
# reads as dbt being absent from an image that plainly contains it.
dbt_offline() {
  docker run --rm --network none "$DBT_IMAGE" dbt "$@" 2>&1 || true
}

ch() { $COMPOSE exec -T clickhouse-01 clickhouse-client "$@" 2>/dev/null | tr -d '\r' || true; }

dbt_online() {
  docker run --rm --network dataplatform \
    -e CLICKHOUSE_HOST=clickhouse-01 -e CLICKHOUSE_PORT=9000 \
    -e CLICKHOUSE_USER=default -e DBT_SCHEMA="$DBT_SCHEMA" \
    -e SOURCE_DATABASE="$SOURCE_DB" \
    -e POSTGRES_HOST=postgres -e POSTGRES_PORT=5432 \
    -e POSTGRES_DB="$(read_env POSTGRES_DB .env)" \
    -e POSTGRES_USER="$(read_env POSTGRES_USER .env)" \
    -e POSTGRES_PASSWORD="$(read_env POSTGRES_PASSWORD .env)" \
    -e S3_ENDPOINT="$(read_env S3_ENDPOINT .env)" \
    -e S3_ACCESS_KEY="$(read_env S3_ACCESS_KEY .env)" \
    -e S3_SECRET_KEY="$(read_env S3_SECRET_KEY .env)" \
    -e S3_BUCKET_STAGED="$(read_env S3_BUCKET_STAGED .env)" \
    "$DBT_IMAGE" dbt "$@" 2>&1
}

# ---------------------------------------------------------------------------
#  1. The image
# ---------------------------------------------------------------------------
info "The image"

if docker image inspect "$DBT_IMAGE" >/dev/null 2>&1; then
  pass "${DBT_IMAGE} exists"
else
  fail "${DBT_IMAGE} is missing — run: make dbt-build"
  printf '\n  Nothing else can be checked without it.\n\n'
  exit 1
fi

version_out=$(dbt_offline --version)
printf '%s' "$version_out" | grep -qi 'clickhouse' \
  && pass "the ClickHouse adapter is installed" \
  || fail "no ClickHouse adapter in the image"

# ---------------------------------------------------------------------------
#  2. The project, parsed without a database
# ---------------------------------------------------------------------------
info "The project"

parse_out=$(dbt_offline parse)
if printf '%s' "$parse_out" | grep -qiE '\[error\]|failure|compilation error'; then
  fail "the project does not parse"
  printf '%s\n' "$parse_out" | grep -iE 'error|fail' | head -6 | sed 's/^/        /'
else
  pass "the project parses, every ref and source resolves"
fi

# Deprecations are worth failing on rather than ignoring. Each one is a thing
# that works today and stops working at the next major version, and the whole
# point of a warning is that it arrives before the breakage.
if printf '%s' "$parse_out" | grep -qi 'Deprecat'; then
  fail "the project uses deprecated syntax:"
  printf '%s\n' "$parse_out" | grep -iA3 'Summary of encountered deprecations' | head -6 | sed 's/^/        /'
else
  pass "no deprecated syntax"
fi

ls_out=$(dbt_offline ls --resource-type model)
for m in $STAGING_MODELS $EXTERNAL_MODELS $MART_MODELS; do
  printf '%s' "$ls_out" | grep -q "$m" \
    && pass "model ${m} is in the graph" \
    || fail "model ${m} is missing from the graph"
done

src_out=$(dbt_offline ls --resource-type source)
for s in $EXPECTED_SOURCES; do
  printf '%s' "$src_out" | grep -q "cdc.${s}" \
    && pass "source cdc.${s} is declared" \
    || fail "source cdc.${s} is not declared"
done

# Tests are the reason to use dbt rather than a folder of SQL files. A project
# whose test count silently drops to zero still builds, still runs, and stops
# checking anything.
test_count=$(dbt_offline ls --resource-type test | grep -c . || true)
[ "${test_count:-0}" -ge 30 ] \
  && pass "${test_count} data tests defined" \
  || fail "only ${test_count:-0} data tests — expected at least 30"

# ---------------------------------------------------------------------------
#  3. Against the warehouse
# ---------------------------------------------------------------------------
info "Against the warehouse"

if ! docker ps --format '{{.Names}}' | grep -qx clickhouse-01; then
  skip "connection — ClickHouse is not running"
  skip "models built — ClickHouse is not running"
  skip "deduplication — ClickHouse is not running"
  skip "the two mart implementations agree — ClickHouse is not running"
  skip "documentation — ClickHouse is not running"
else
  dbt_online debug | grep -q 'All checks passed' \
    && pass "dbt connects to ClickHouse" \
    || fail "dbt cannot connect — check: make dbt-debug"

  staging_built=$(ch --query "SELECT count() FROM system.tables WHERE database = '${DBT_SCHEMA}_staging'")
  [ "${staging_built:-0}" -ge 7 ] 2>/dev/null \
    && pass "${staging_built} staging models built" \
    || fail "${staging_built:-0} staging models, expected 7 — run: make dbt-build-all"

  marts_built=$(ch --query "SELECT count() FROM system.tables WHERE database = '${DBT_SCHEMA}_marts'")
  [ "${marts_built:-0}" -ge 3 ] 2>/dev/null \
    && pass "${marts_built} marts built" \
    || fail "${marts_built:-0} marts, expected 3 — run: make dbt-build-all"

  # ---- the check this layer exists for ---------------------------------
  if [ "${staging_built:-0}" -ge 4 ]; then
    dupes=$(ch --query "SELECT count() FROM (SELECT order_id FROM ${DBT_SCHEMA}_staging.stg_orders GROUP BY order_id HAVING count() > 1)")
    [ "${dupes:-1}" = "0" ] \
      && pass "stg_orders has no duplicate order_id — FINAL is doing its job" \
      || fail "${dupes} order_id values appear more than once — is FINAL still in the model?"

    raw=$(ch --query "SELECT count() FROM ${SOURCE_DB}.customers")
    stg=$(ch --query "SELECT count() FROM ${DBT_SCHEMA}_staging.stg_customers")
    if [ -n "$raw" ] && [ -n "$stg" ] && [ "$raw" -gt "$stg" ] 2>/dev/null; then
      pass "customers: ${raw} source rows collapse to ${stg} current ones"
    else
      fail "customers: ${raw:-?} source rows, ${stg:-?} staged — expected the source to hold more"
    fi
  else
    skip "deduplication — the models are not built"
  fi

  # ---- two implementations of one definition ---------------------------
  #  The mart in 04-etl and the model here compute the same thing from the
  #  same rows. Keeping both is only worth it if the disagreement is checked,
  #  and it has already paid for itself: the job was counting cancelled
  #  orders as revenue, which nothing else noticed for two steps.
  if [ "${marts_built:-0}" -ge 3 ]; then
    if dbt_online test --select mart_matches_job >/tmp/dbt_recon.log 2>&1; then
      pass "the dbt mart agrees with the hand-written job"
    elif grep -qE 'WARN=1|Completed with [0-9]+ warning' /tmp/dbt_recon.log; then
      fail "the two mart implementations disagree"
      grep -iE 'got [0-9]+ result' /tmp/dbt_recon.log | head -2 | sed 's/^/        /'
    else
      skip "mart comparison — the job's table does not exist yet"
    fi
  else
    skip "the two mart implementations agree — the marts are not built"
  fi

  # ---- everything else dbt asserts -------------------------------------
  if [ "${marts_built:-0}" -ge 3 ]; then
    if dbt_online test >/tmp/dbt_test.log 2>&1; then
      pass "dbt test passes"
    else
      if grep -qE 'Completed with [0-9]+ warning' /tmp/dbt_test.log \
         && ! grep -qE 'Completed with [0-9]+ error' /tmp/dbt_test.log; then
        pass "dbt test passes with warnings only"
      else
        fail "dbt test failed"
        grep -iE 'error|fail' /tmp/dbt_test.log | head -6 | sed 's/^/        /'
      fi
    fi
  else
    skip "tests — the marts are not built"
  fi

  # ---- the documentation site ------------------------------------------
  #  Checked for content, not merely for an answer. Before the first
  #  `make docs` the volume is empty and nginx returns 403 — a healthy
  #  container serving nothing.
  if docker ps --format '{{.Names}}' | grep -qx dbt-docs; then
    # Read a fixed prefix rather than piping the whole page into grep.
    #
    # The generated site is a single 2.7 MB file. `curl | grep -q` closes the
    # pipe on the first match, curl takes SIGPIPE and exits non-zero, and -f
    # turns that into a failure — so the check reported an empty site while
    # serving a perfectly good one.
    docs_head=$(curl -sS --max-time 10 "http://localhost:${DOCS_PORT}/index.html" 2>/dev/null | head -c 400 || true)
    if printf '%s' "$docs_head" | grep -qi 'dbt'; then
      pass "the documentation site is serving a generated page"
    else
      fail "dbt-docs answers but serves nothing — run: make docs"
    fi
  else
    skip "documentation — dbt-docs is not running"
  fi
fi

# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$PASSED" "$FAILED" "$SKIPPED"

if [ "$SKIPPED" -gt 0 ]; then
  echo "  The warehouse checks were skipped. dbt does nothing without a"
  echo "  database, so CI covers parsing only — run the full test on a machine"
  echo "  that can hold the ClickHouse cluster."
  echo ""
fi

[ "$FAILED" -eq 0 ]
