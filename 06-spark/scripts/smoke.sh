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

# The magic committer specifically, not just any committer.
#
# The staging committers — directory and partitioned — keep metadata about
# their uploaded parts in a local directory and expect the driver and every
# executor to see the same one. In containers they do not, and the job then
# succeeds while writing only _SUCCESS into an empty prefix. Asserting the
# name rather than merely its presence is what keeps that from coming back.
printf '%s' "$conf" | grep -q 'fs.s3a.committer.name.*magic' \
  && pass "the magic committer is configured" \
  || fail "the magic committer is not set — staging committers lose data across containers"

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
#  6. A job that actually runs on the cluster
# ---------------------------------------------------------------------------
#  Everything above proves the cluster is assembled. This proves it does work.
#
#  Skipped when the source is empty rather than failed: the raw layer is
#  filled by the export job in 04-etl, which needs ClickHouse, and continuous
#  integration runs without the warehouse. A test that fails on something it
#  was never given teaches people to ignore it.
# ---------------------------------------------------------------------------
info "A job on the cluster"

JOB_VERSION="$(read_env JOB_VERSION .env)"; JOB_VERSION="${JOB_VERSION:-0.1.0}"
MINIO_USER="$(read_env MINIO_ROOT_USER .env)";     MINIO_USER="${MINIO_USER:-minioadmin}"
MINIO_PASS="$(read_env MINIO_ROOT_PASSWORD .env)"; MINIO_PASS="${MINIO_PASS:-minioadmin}"
MC_VERSION="$(read_env MC_VERSION ../05-minio/.env)"; MC_VERSION="${MC_VERSION:-latest}"
MC_IMAGE="$(read_env MC_IMAGE ../05-minio/.env)"; MC_IMAGE="${MC_IMAGE:-quay.io/minio/mc}"

# The client as a throwaway container on the platform network, so it reaches
# MinIO by service name exactly as a job would.
#
# The registry is a variable, not a literal. MinIO publishes to quay.io now
# and the Docker Hub copies are missing tags — a literal here kept working
# locally, where the image was already pulled, and failed in CI on a clean
# machine.
mc() {
  docker run --rm --network dataplatform \
    -e "MC_HOST_local=http://${MINIO_USER}:${MINIO_PASS}@minio:9000" \
    "${MC_IMAGE}:${MC_VERSION}" "$@" 2>/dev/null | tr -d '\r' || true
}

raw_objects=$(mc ls --recursive local/raw/orders/ | grep -c 'parquet' || true)

if ! docker ps --format '{{.Names}}' | grep -qx minio; then
  skip "the transformation — MinIO is not running"
  skip "its output — MinIO is not running"
elif ! docker image inspect "dataplatform/spark-job-orders-staged:${JOB_VERSION}" >/dev/null 2>&1; then
  fail "dataplatform/spark-job-orders-staged:${JOB_VERSION} is missing — run: make jobs"
  skip "its output — the image is missing"
elif [ "${raw_objects:-0}" -eq 0 ]; then
  skip "the transformation — s3://raw/orders/ is empty, run the export in 04-etl"
  skip "its output — nothing to transform"
else
  if docker run --rm --network dataplatform \
       --name spark-driver-smoke --hostname spark-driver-smoke \
       -e SPARK_MASTER_URL=spark://spark-master:7077 \
       -e SPARK_DRIVER_HOST=spark-driver-smoke \
       -e SPARK_DRIVER_MEMORY="${SPARK_DRIVER_MEMORY:-1g}" \
       -e SPARK_EXECUTOR_MEMORY="${SPARK_EXECUTOR_MEMORY:-1g}" \
       -e SPARK_EXECUTOR_CORES="${SPARK_EXECUTOR_CORES:-1}" \
       -e SPARK_CORES_MAX="${SPARK_CORES_MAX:-4}" \
       -e S3_ENDPOINT=http://minio:9000 \
       -e AWS_ACCESS_KEY_ID="${MINIO_USER}" \
       -e AWS_SECRET_ACCESS_KEY="${MINIO_PASS}" \
       "dataplatform/spark-job-orders-staged:${JOB_VERSION}" >/tmp/staged_smoke.log 2>&1; then
    pass "the transformation ran and exited zero"
  else
    fail "the transformation failed"
    tail -12 /tmp/staged_smoke.log | sed 's/^/        /'
  fi

  # Exiting zero is not the same as writing data. This stack has already
  # produced the exact failure this checks for: the magic committer wrote
  # _SUCCESS into an otherwise empty prefix, because the staging committers it
  # replaced had left every data file in a local directory the driver could
  # not see. The job succeeded and the bucket held nothing.
  data_files=$(mc ls --recursive local/staged/orders/ | grep -c '\.parquet' || true)
  if [ "${data_files:-0}" -gt 0 ]; then
    pass "${data_files} parquet file(s) in s3://staged/orders/"
  else
    fail "s3://staged/orders/ holds no parquet — check for a lone _SUCCESS marker"
    mc ls --recursive local/staged/orders/ | head -5 | sed 's/^/        /'
  fi
fi

# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$PASSED" "$FAILED" "$SKIPPED"

[ "$FAILED" -eq 0 ]
