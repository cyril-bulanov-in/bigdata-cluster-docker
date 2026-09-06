#!/usr/bin/env bash
#
# Smoke test for the orchestration stack.
#
# What can be broken while every container is green:
#
#   a DAG file fails to import — it is simply absent from the UI, with no
#     broken entry and no warning
#   the scheduler stops heartbeating while the UI keeps answering, because
#     they are different processes
#   a job image is missing, so DockerOperator fails on something that reads
#     like an Airflow problem
#   a template references a variable that a manual run does not have, so the
#     DAG works on a schedule and dies when triggered by hand
#   the job runs, exits zero, and writes nothing
#
# SKIP_CLICKHOUSE=1 leaves out the checks that need the warehouse.
#
# Usage:  ./scripts/smoke.sh          (or: make smoke)

set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose"
SKIP_CLICKHOUSE="${SKIP_CLICKHOUSE:-0}"

read_env() {
  grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

AF_PORT="$(read_env AIRFLOW_PORT .env)";    AF_PORT="${AF_PORT:-8081}"
JOB_VERSION="$(read_env JOB_VERSION .env)"; JOB_VERSION="${JOB_VERSION:-0.1.0}"
PROM_PORT="$(read_env PROMETHEUS_PORT ../02-monitoring/.env)"; PROM_PORT="${PROM_PORT:-9090}"

AIRFLOW="http://localhost:${AF_PORT}"
PROM="http://localhost:${PROM_PORT}"

AF_COMPONENTS="airflow-apiserver airflow-scheduler airflow-dag-processor airflow-triggerer"
EXPECTED_DAGS="00_docker_smoke 10_daily_sales"
API_TIMEOUT=120

# ---------------------------------------------------------------------------
#  How long to wait for a metric to exist
# ---------------------------------------------------------------------------
#  Two separate delays, and neither is a sign of anything wrong.
#
#  Prometheus polls Docker for containers every 30s, so a container that
#  started in the same wave as Prometheus itself is not discovered on the
#  first pass.
#
#  Airflow pushes StatsD as events happen. An idle scheduler does emit
#  heartbeats, but not the instant it starts.
#
#  Checking once made this test pass on a machine where the stack had been up
#  for a while and fail on a cold CI runner — the same mistake, in the same
#  shape, that the metric checks in 02-monitoring already document. Retrying
#  costs nothing when the answer is already there: the first attempt succeeds.
# ---------------------------------------------------------------------------
METRIC_TIMEOUT=120
METRIC_INTERVAL=10

PASSED=0; FAILED=0; SKIPPED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

af() { $COMPOSE exec -T airflow-scheduler "$@" 2>/dev/null | tr -d '\r' || true; }
ch() { $COMPOSE exec -T clickhouse-01 clickhouse-client --database analytics --query "$1" 2>/dev/null | tr -d '\r' || true; }

# ---------------------------------------------------------------------------
#  0. Is the stack running
# ---------------------------------------------------------------------------
running=$($COMPOSE ps --services 2>/dev/null | grep -cE '^(airflow-apiserver|airflow-scheduler)$' || true)
if [ "${running:-0}" -lt 2 ]; then
  printf '\n\033[31mAirflow is not running.\033[0m\n\n  make up\n  make test\n\n'
  exit 1
fi

# ---------------------------------------------------------------------------
#  1. The components
# ---------------------------------------------------------------------------
info "Airflow components"

for c in $AF_COMPONENTS; do
  state=$($COMPOSE ps --format '{{.Name}} {{.State}}' 2>/dev/null | awk -v n="$c" '$1 == n {print $2}' || true)
  [ "$state" = "running" ] \
    && pass "$c is running" \
    || fail "$c is ${state:-absent}"
done

# The api-server takes a while: on a fresh volume it runs a schema migration
# before it serves anything. Polling rather than a single check, because a
# stack started thirty seconds ago is not a stack that is broken.
api_ok=0
deadline=$(( $(date +%s) + API_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -fsS --max-time 5 "${AIRFLOW}/api/v2/monitor/health" >/dev/null 2>&1; then
    api_ok=1; break
  fi
  sleep 5
done
[ "$api_ok" = "1" ] \
  && pass "the API answers on ${AIRFLOW}" \
  || fail "the API did not answer within ${API_TIMEOUT}s"

# ---------------------------------------------------------------------------
#  2. The DAGs
# ---------------------------------------------------------------------------
info "DAGs"

# Import errors first. A DAG that fails to import is not listed as broken —
# it is not listed at all, which is indistinguishable from a file that was
# never written.
errors_text=$(af airflow dags list-import-errors -o plain)
if printf '%s' "$errors_text" | grep -qi 'no data found'; then
  pass "no DAG import errors"
else
  fail "DAG files failing to import:"
  printf '%s\n' "$errors_text" | head -5 | sed 's/^/        /'
fi

dag_list=$(af airflow dags list -o plain)
for d in $EXPECTED_DAGS; do
  printf '%s' "$dag_list" | grep -q "$d" \
    && pass "$d is present" \
    || fail "$d is missing — check: make dag-errors"
done

# ---------------------------------------------------------------------------
#  3. The job images
# ---------------------------------------------------------------------------
#  DockerOperator never builds anything. A missing image fails the task with
#  "No such image", which reads like an orchestration problem.
# ---------------------------------------------------------------------------
info "Job images"

for job in hello daily-sales; do
  docker image inspect "dataplatform/job-${job}:${JOB_VERSION}" >/dev/null 2>&1 \
    && pass "dataplatform/job-${job}:${JOB_VERSION} exists" \
    || fail "dataplatform/job-${job}:${JOB_VERSION} is missing — run: make jobs"
done

# ---------------------------------------------------------------------------
#  4. Metrics
# ---------------------------------------------------------------------------
#  Both checks retry — see the note at the top on why "the container is up" and
#  "the metric exists" are not the same moment.
#
#  Note also the `|| true` on every pipeline. With `set -o pipefail`, a curl
#  that cannot connect or a grep that matches nothing returns non-zero, `set -e`
#  sees it on a variable assignment, and the script dies without printing
#  anything at all — removing every check after it rather than reporting one.
# ---------------------------------------------------------------------------
info "Metrics (waiting up to ${METRIC_TIMEOUT}s each)"

waited=0
targets=0
while :; do
  targets_body=$(curl -fsS --max-time 10 "${PROM}/api/v1/targets?state=active" 2>/dev/null || true)
  targets=$(printf '%s' "$targets_body" | grep -o '"job": *"airflow"' | wc -l | tr -d ' ' || true)
  [ "${targets:-0}" -ge 1 ] && break
  [ "$waited" -ge "$METRIC_TIMEOUT" ] && break
  sleep "$METRIC_INTERVAL"; waited=$((waited + METRIC_INTERVAL))
done
[ "${targets:-0}" -ge 1 ] \
  && pass "Prometheus is scraping the Airflow exporter (after ${waited}s)" \
  || fail "no airflow scrape target after ${METRIC_TIMEOUT}s — check the labels on airflow-statsd"

waited=0
series=0
while :; do
  series_body=$(curl -fsS --max-time 10 --get \
                  --data-urlencode 'query=count({__name__=~"airflow_.*"})' \
                  "${PROM}/api/v1/query" 2>/dev/null || true)
  series=$(printf '%s' "$series_body" | grep -o '"[0-9]*"\]' | head -1 | tr -d '"]' || true)
  [ "${series:-0}" -gt 0 ] 2>/dev/null && break
  [ "$waited" -ge "$METRIC_TIMEOUT" ] && break
  sleep "$METRIC_INTERVAL"; waited=$((waited + METRIC_INTERVAL))
done
[ "${series:-0}" -gt 0 ] 2>/dev/null \
  && pass "${series} airflow metric series present (after ${waited}s)" \
  || fail "no airflow metrics after ${METRIC_TIMEOUT}s — Airflow pushes StatsD, so even an idle scheduler should emit heartbeats"

# ---------------------------------------------------------------------------
#  5. A job that actually does something
# ---------------------------------------------------------------------------
#  Run directly, not through Airflow. When a mart is wrong the first question
#  is whether the job is wrong or the orchestration is, and this answers it
#  without waiting for a schedule.
# ---------------------------------------------------------------------------
info "The mart job"

if [ "$SKIP_CLICKHOUSE" = "1" ]; then
  skip "mart job — SKIP_CLICKHOUSE is set"
  skip "mart contents — SKIP_CLICKHOUSE is set"
else
  day=$(date -u -v-1d +%F 2>/dev/null || date -u -d yesterday +%F)

  if docker run --rm --network dataplatform \
       -e CLICKHOUSE_URL=http://clickhouse-01:8123 \
       -e CLICKHOUSE_DB=analytics \
       -e TARGET_DATE="$day" \
       "dataplatform/job-daily-sales:${JOB_VERSION}" >/tmp/mart_job.log 2>&1; then
    pass "the mart job ran for ${day} and exited zero"
  else
    fail "the mart job failed for ${day}"
    tail -8 /tmp/mart_job.log | sed 's/^/        /'
  fi

  # Exiting zero is not the same as writing something. A job that succeeds
  # while producing nothing is the failure this check exists for.
  rows=$(ch "SELECT count() FROM daily_sales_by_category FINAL WHERE day = '${day}'")
  [ "${rows:-0}" -gt 0 ] 2>/dev/null \
    && pass "${rows} category rows in the mart for ${day}" \
    || fail "the mart is empty for ${day} despite the job succeeding"
fi

# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$PASSED" "$FAILED" "$SKIPPED"

if [ "$SKIPPED" -gt 0 ]; then
  echo "  The warehouse checks were skipped. Run without SKIP_CLICKHOUSE on a"
  echo "  machine that can hold the ClickHouse cluster to cover them."
  echo ""
fi

[ "$FAILED" -eq 0 ]
