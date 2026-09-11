#!/usr/bin/env bash
#
# Smoke test for the Spark stack.
#
# At this point the cluster exists and no job has run on it yet, so what can
# be broken is narrower than usual — and worth catching before any job is
# written on top:
#
#   the S3 jars are absent, or present only on the master, so a job plans
#     correctly and dies on the first executor
#   hadoop-aws does not match the Hadoop compiled into Spark, which surfaces
#     as NoSuchMethodError from somewhere unrelated
#   workers registered with the master but offer no cores
#   Spark serves metrics on a per-role path and Prometheus scrapes the default
#
# Usage:  ./scripts/smoke.sh          (or: make smoke)

set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose"

read_env() {
  grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

UI_PORT="$(read_env SPARK_MASTER_UI_PORT .env)"; UI_PORT="${UI_PORT:-8090}"
HADOOP_AWS="$(read_env HADOOP_AWS_VERSION .env)"; HADOOP_AWS="${HADOOP_AWS:-3.3.4}"
AWS_SDK="$(read_env AWS_SDK_VERSION .env)";       AWS_SDK="${AWS_SDK:-1.12.262}"
PROM_PORT="$(read_env PROMETHEUS_PORT ../02-monitoring/.env)"; PROM_PORT="${PROM_PORT:-9090}"

SPARK="http://localhost:${UI_PORT}"
PROM="http://localhost:${PROM_PORT}"

EXPECTED_WORKERS=4
MASTER_TIMEOUT=120
METRIC_TIMEOUT=120
METRIC_INTERVAL=10

PASSED=0; FAILED=0; SKIPPED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
#  0. Is it running
# ---------------------------------------------------------------------------
if ! $COMPOSE ps --services 2>/dev/null | grep -qx spark-master; then
  printf '\n\033[31mSpark is not running.\033[0m\n\n  make up\n  make test\n\n'
  exit 1
fi

# ---------------------------------------------------------------------------
#  1. The master
# ---------------------------------------------------------------------------
info "The master"

# The master serves its state as JSON on the UI port, which is more reliable
# to assert on than scraping HTML.
master_ok=0
deadline=$(( $(date +%s) + MASTER_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if curl -fsS --max-time 5 "${SPARK}/json/" >/dev/null 2>&1; then
    master_ok=1; break
  fi
  sleep 5
done
[ "$master_ok" = "1" ] \
  && pass "the master answers on ${SPARK}" \
  || fail "the master did not answer within ${MASTER_TIMEOUT}s"

master_json=$(curl -fsS --max-time 10 "${SPARK}/json/" 2>/dev/null || echo '{}')

status=$(printf '%s' "$master_json" | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('status', ''))
except Exception: print('')
" 2>/dev/null || true)
[ "$status" = "ALIVE" ] \
  && pass "the master reports ALIVE" \
  || fail "the master reports '${status:-nothing}'"

# ---------------------------------------------------------------------------
#  2. The workers
# ---------------------------------------------------------------------------
#  Registered is not the same as usable. A worker that joined with zero cores
#  accepts no executors, and the cluster looks fully staffed while nothing can
#  be scheduled on it.
# ---------------------------------------------------------------------------
info "The workers"

read -r alive cores memory <<EOF
$(printf '%s' "$master_json" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    w = [x for x in d.get('workers', []) if x.get('state') == 'ALIVE']
    print(len(w), sum(x.get('cores', 0) for x in w), sum(x.get('memory', 0) for x in w))
except Exception:
    print(0, 0, 0)
" 2>/dev/null || echo "0 0 0")
EOF

[ "${alive:-0}" = "$EXPECTED_WORKERS" ] \
  && pass "${alive} workers registered and alive" \
  || fail "${alive:-0} workers alive, expected ${EXPECTED_WORKERS}"

[ "${cores:-0}" -ge "$EXPECTED_WORKERS" ] 2>/dev/null \
  && pass "${cores} cores offered to the cluster" \
  || fail "${cores:-0} cores offered — a worker with no cores accepts no executors"

[ "${memory:-0}" -gt 0 ] 2>/dev/null \
  && pass "${memory} MiB offered to the cluster" \
  || fail "no memory offered"

# ---------------------------------------------------------------------------
#  3. The S3 jars
# ---------------------------------------------------------------------------
#  Checked on a worker, not the master. Workers run the tasks that read S3, so
#  an image with the jars only where the job is submitted from produces a job
#  that plans correctly and fails on the first executor — with an error that
#  mentions neither S3 nor the missing jar.
# ---------------------------------------------------------------------------
info "The S3 jars, on a worker"

worker_jars=$($COMPOSE exec -T spark-worker-1 ls /opt/spark/jars 2>/dev/null | tr -d '\r' || true)

printf '%s' "$worker_jars" | grep -q "hadoop-aws-${HADOOP_AWS}.jar" \
  && pass "hadoop-aws-${HADOOP_AWS}.jar is present" \
  || fail "hadoop-aws-${HADOOP_AWS}.jar is missing from the worker"

printf '%s' "$worker_jars" | grep -q "aws-java-sdk-bundle-${AWS_SDK}.jar" \
  && pass "aws-java-sdk-bundle-${AWS_SDK}.jar is present" \
  || fail "aws-java-sdk-bundle-${AWS_SDK}.jar is missing from the worker"

# The version that actually matters. hadoop-aws must equal the Hadoop version
# Spark was compiled against — not merely be present, and not merely be close.
# The bundled version is readable from any hadoop-*.jar in the same directory.
bundled_hadoop=$(printf '%s' "$worker_jars" \
  | grep -oE '^hadoop-client-api-[0-9]+\.[0-9]+\.[0-9]+' \
  | head -1 | sed 's/hadoop-client-api-//' || true)

if [ -z "$bundled_hadoop" ]; then
  # Different Spark builds name their Hadoop jars differently; fall back to
  # any hadoop- jar carrying a version, rather than reporting nothing.
  bundled_hadoop=$(printf '%s' "$worker_jars" \
    | grep -oE '^hadoop-[a-z-]*-[0-9]+\.[0-9]+\.[0-9]+' \
    | grep -v 'hadoop-aws' | head -1 | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' || true)
fi

if [ -z "$bundled_hadoop" ]; then
  skip "could not read the bundled Hadoop version from the jar names"
elif [ "$bundled_hadoop" = "$HADOOP_AWS" ]; then
  pass "hadoop-aws ${HADOOP_AWS} matches the Hadoop ${bundled_hadoop} in this Spark build"
else
  fail "hadoop-aws is ${HADOOP_AWS} but Spark bundles Hadoop ${bundled_hadoop}"
  echo "        A mismatch surfaces as NoSuchMethodError from deep in the stack,"
  echo "        naming neither S3 nor versions. Set HADOOP_AWS_VERSION=${bundled_hadoop}."
fi

# The class Spark will actually look for. A jar can be present, correctly
# named and still be the wrong artifact.
if $COMPOSE exec -T spark-worker-1 python3 -c "
import zipfile
z = zipfile.ZipFile('/opt/spark/jars/hadoop-aws-${HADOOP_AWS}.jar')
assert 'org/apache/hadoop/fs/s3a/S3AFileSystem.class' in z.namelist()
" >/dev/null 2>&1; then
  pass "S3AFileSystem is inside the jar"
else
  fail "S3AFileSystem is not in hadoop-aws-${HADOOP_AWS}.jar"
fi

# ---------------------------------------------------------------------------
#  4. Configuration
# ---------------------------------------------------------------------------
info "Configuration"

conf=$($COMPOSE exec -T spark-worker-1 cat /opt/spark/conf/spark-defaults.conf 2>/dev/null | tr -d '\r' || true)

printf '%s' "$conf" | grep -q 'fs.s3a.path.style.access.*true' \
  && pass "path-style addressing is on" \
  || fail "path-style addressing is off — bucket.minio does not resolve"

printf '%s' "$conf" | grep -q 'fs.s3a.committer.name.*directory' \
  && pass "the directory committer is configured" \
  || fail "no S3 committer — the default renames files, and S3 has no rename"

# ---------------------------------------------------------------------------
#  5. Metrics
# ---------------------------------------------------------------------------
#  Spark serves Prometheus metrics natively, but on a different path per role.
#  Without the prometheus.path label and the relabel rule in docker-sd, the
#  targets are discovered and scrape a 404 — the same trap MinIO had.
# ---------------------------------------------------------------------------
info "Metrics (waiting up to ${METRIC_TIMEOUT}s)"

waited=0
m_targets=0
w_targets=0
while :; do
  body=$(curl -fsS --max-time 10 "${PROM}/api/v1/targets?state=active" 2>/dev/null || true)
  m_targets=$(printf '%s' "$body" | grep -o '"job": *"spark-master"' | wc -l | tr -d ' ' || true)
  w_targets=$(printf '%s' "$body" | grep -o '"job": *"spark-worker"' | wc -l | tr -d ' ' || true)
  [ "${m_targets:-0}" -ge 1 ] && [ "${w_targets:-0}" -ge "$EXPECTED_WORKERS" ] && break
  [ "$waited" -ge "$METRIC_TIMEOUT" ] && break
  sleep "$METRIC_INTERVAL"; waited=$((waited + METRIC_INTERVAL))
done

[ "${m_targets:-0}" -ge 1 ] \
  && pass "Prometheus is scraping the master (after ${waited}s)" \
  || fail "no spark-master target — check the prometheus.path label"

[ "${w_targets:-0}" -ge "$EXPECTED_WORKERS" ] \
  && pass "Prometheus is scraping ${w_targets} workers" \
  || fail "${w_targets:-0} spark-worker targets, expected ${EXPECTED_WORKERS}"

# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$PASSED" "$FAILED" "$SKIPPED"

[ "$FAILED" -eq 0 ]
