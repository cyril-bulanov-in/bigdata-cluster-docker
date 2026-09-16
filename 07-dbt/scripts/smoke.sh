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

EXPECTED_MODELS="stg_orders stg_order_items stg_customers stg_products"
EXPECTED_SOURCES="orders order_items customers products"

PASSED=0; FAILED=0; SKIPPED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# dbt with no network and no credentials. Parsing needs neither, and running
# it this way proves that: a check that quietly depended on a live connection
# would pass here and fail in CI.
dbt_offline() {
  docker run --rm --network none "$DBT_IMAGE" "$@" 2>&1 || true
}

ch() { $COMPOSE exec -T clickhouse-01 clickhouse-client "$@" 2>/dev/null | tr -d '\r' || true; }

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

# The adapter is pinned in requirements.txt and dbt-core is not — see the
# comment there. This asserts that pip resolved a working pair rather than
# leaving one of them absent.
version_out=$(dbt_offline --version)
printf '%s' "$version_out" | grep -qi 'clickhouse' \
  && pass "the ClickHouse adapter is installed: $(printf '%s' "$version_out" | grep -i clickhouse | head -1 | tr -s ' ')" \
  || fail "no ClickHouse adapter in the image"

printf '%s' "$version_out" | grep -qiE 'installed:' \
  && pass "dbt-core is installed: $(printf '%s' "$version_out" | grep -i 'installed:' | head -1 | tr -s ' ')" \
  || fail "dbt-core did not report a version"

# ---------------------------------------------------------------------------
#  2. The project, parsed without a database
# ---------------------------------------------------------------------------
#  `dbt parse` reads every model, resolves ref() and source(), compiles the
#  Jinja and builds the dependency graph — all without connecting. It is the
#  strongest check available offline, and it catches the errors that actually
#  happen while editing: a ref() to a model that was renamed, a source that is
#  not in sources.yml, an unbalanced Jinja block, a test on a column that no
#  longer exists.
#
#  What it does NOT catch is SQL that is valid to dbt and wrong to ClickHouse.
#  That needs the warehouse, and is why the second half of this test exists.
# ---------------------------------------------------------------------------
info "The project"

parse_out=$(dbt_offline parse)
if printf '%s' "$parse_out" | grep -qiE 'error|fail'; then
  fail "the project does not parse"
  printf '%s\n' "$parse_out" | grep -iE 'error|fail' | head -6 | sed 's/^/        /'
else
  pass "the project parses, every ref and source resolves"
fi

ls_out=$(dbt_offline ls --resource-type model)
for m in $EXPECTED_MODELS; do
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
[ "${test_count:-0}" -ge 20 ] \
  && pass "${test_count} data tests defined" \
  || fail "only ${test_count:-0} data tests — expected at least 20"

# ---------------------------------------------------------------------------
#  3. Against the warehouse
# ---------------------------------------------------------------------------
info "Against the warehouse"

if ! docker ps --format '{{.Names}}' | grep -qx clickhouse-01; then
  skip "connection — ClickHouse is not running"
  skip "models built — ClickHouse is not running"
  skip "deduplication — ClickHouse is not running"
  skip "tests — ClickHouse is not running"
else
  # Not the same as `dbt parse`: this resolves the profile, reads the
  # environment variables, and opens a connection.
  if $COMPOSE exec -T clickhouse-01 true 2>/dev/null \
     && docker run --rm --network dataplatform \
          -e CLICKHOUSE_HOST=clickhouse-01 -e CLICKHOUSE_PORT=9000 \
          -e CLICKHOUSE_USER=default -e DBT_SCHEMA="$DBT_SCHEMA" \
          -e SOURCE_DATABASE="$SOURCE_DB" \
          "$DBT_IMAGE" debug 2>&1 | grep -q 'All checks passed'; then
    pass "dbt connects to ClickHouse"
  else
    fail "dbt cannot connect — check: make dbt-debug"
  fi

  built=$(ch --query "SELECT count() FROM system.tables WHERE database = '${DBT_SCHEMA}_staging'")
  [ "${built:-0}" -ge 4 ] 2>/dev/null \
    && pass "${built} staging models built in ${DBT_SCHEMA}_staging" \
    || fail "${built:-0} models in ${DBT_SCHEMA}_staging, expected 4 — run: make dbt-build-all"

  # ---- the check this layer exists for ---------------------------------
  #  Every staging model reads its source with FINAL. Drop it and the model
  #  still builds, still returns plausible numbers, and counts every version
  #  of a row as a separate row.
  #
  #  Asserting that the model has no duplicate keys is how that gets caught —
  #  the same thing the `unique` test in schema.yml does, checked here from
  #  outside dbt so that a project whose tests were disabled still fails.
  if [ "${built:-0}" -ge 4 ]; then
    dupes=$(ch --query "SELECT count() FROM (SELECT order_id FROM ${DBT_SCHEMA}_staging.stg_orders GROUP BY order_id HAVING count() > 1)")
    [ "${dupes:-1}" = "0" ] \
      && pass "stg_orders has no duplicate order_id — FINAL is doing its job" \
      || fail "${dupes} order_id values appear more than once — is FINAL still in the model?"

    # The source holds more rows than the model, and that gap is the point.
    # Equal counts mean either nothing has changed since the last merge or
    # the deduplication silently stopped happening.
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

  # dbt's own tests, run from outside. Slower than the checks above and worth
  # it: they cover uniqueness, nullability and referential integrity across
  # every model at once.
  if [ "${built:-0}" -ge 4 ]; then
    if docker run --rm --network dataplatform \
         -e CLICKHOUSE_HOST=clickhouse-01 -e CLICKHOUSE_PORT=9000 \
         -e CLICKHOUSE_USER=default -e DBT_SCHEMA="$DBT_SCHEMA" \
         -e SOURCE_DATABASE="$SOURCE_DB" \
         "$DBT_IMAGE" test >/tmp/dbt_test.log 2>&1; then
      pass "dbt test passes"
    else
      # Warnings are not failures: the relationship tests are deliberately
      # severity:warn, because an order can outlive a deleted customer and an
      # item can arrive before its order.
      if grep -qE 'Completed with [0-9]+ warning' /tmp/dbt_test.log \
         && ! grep -qE 'Completed with [0-9]+ error' /tmp/dbt_test.log; then
        pass "dbt test passes with warnings only"
      else
        fail "dbt test failed"
        grep -iE 'error|fail' /tmp/dbt_test.log | head -6 | sed 's/^/        /'
      fi
    fi
  else
    skip "tests — the models are not built"
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
