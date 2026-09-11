#!/usr/bin/env bash
#
# Smoke test for the object storage stack.
#
# What can be broken while the container is green:
#
#   the buckets exist but versioning was never enabled, so every overwrite
#     destroys the previous result and nothing says so
#   the lifecycle rules were never applied, so noncurrent versions accumulate
#     for ever — invisible in the console, which shows current versions only
#   Prometheus scrapes MinIO on the default /metrics path and gets a 404, so
#     the target is red for a reason that has nothing to do with MinIO
#   a job writes an object that cannot be read back
#
# The last group runs the export job end to end and checks the object it
# claims to have written.
#
# Usage:  ./scripts/smoke.sh          (or: make smoke)

set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose"

read_env() {
  grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

API_PORT="$(read_env MINIO_API_PORT .env)";       API_PORT="${API_PORT:-9000}"
MINIO_USER="$(read_env MINIO_ROOT_USER .env)";    MINIO_USER="${MINIO_USER:-minioadmin}"
MINIO_PASS="$(read_env MINIO_ROOT_PASSWORD .env)"; MINIO_PASS="${MINIO_PASS:-minioadmin}"
MC_VERSION="$(read_env MC_VERSION .env)";         MC_VERSION="${MC_VERSION:-latest}"
RAW="$(read_env BUCKET_RAW .env)";                RAW="${RAW:-raw}"
STAGED="$(read_env BUCKET_STAGED .env)";          STAGED="${STAGED:-staged}"
CURATED="$(read_env BUCKET_CURATED .env)";        CURATED="${CURATED:-curated}"
PROM_PORT="$(read_env PROMETHEUS_PORT ../02-monitoring/.env)"; PROM_PORT="${PROM_PORT:-9090}"
JOB_VERSION="$(read_env JOB_VERSION ../04-etl/.env)"; JOB_VERSION="${JOB_VERSION:-0.1.0}"

PROM="http://localhost:${PROM_PORT}"

# Prometheus polls Docker for new containers every 30s, so a container started
# in the same wave as Prometheus is not discovered on the first pass. Retrying
# costs nothing when the answer is already there.
METRIC_TIMEOUT=120
METRIC_INTERVAL=10

PASSED=0; FAILED=0; SKIPPED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# The client as a throwaway container on the platform network, so it reaches
# MinIO by service name exactly as a job would.
mc() {
  docker run --rm --network dataplatform \
    -e "MC_HOST_local=http://${MINIO_USER}:${MINIO_PASS}@minio:9000" \
    "minio/mc:${MC_VERSION}" "$@" 2>/dev/null | tr -d '\r' || true
}

# ---------------------------------------------------------------------------
#  0. Is it running
# ---------------------------------------------------------------------------
if ! $COMPOSE ps --services 2>/dev/null | grep -qx minio; then
  printf '\n\033[31mMinIO is not running.\033[0m\n\n  make up\n  make test\n\n'
  exit 1
fi

# ---------------------------------------------------------------------------
#  1. The service
# ---------------------------------------------------------------------------
info "MinIO"

curl -fsS --max-time 5 "http://localhost:${API_PORT}/minio/health/live" >/dev/null 2>&1 \
  && pass "the S3 API answers on port ${API_PORT}" \
  || fail "no answer on port ${API_PORT}"

info_out=$(mc admin info local)
printf '%s' "$info_out" | grep -qi online \
  && pass "the server reports itself online" \
  || fail "mc admin info does not report an online server"

# ---------------------------------------------------------------------------
#  2. The bucket layout
# ---------------------------------------------------------------------------
info "Buckets"

bucket_list=$(mc ls local)
for b in "$RAW" "$STAGED" "$CURATED"; do
  printf '%s' "$bucket_list" | grep -q "${b}/" \
    && pass "bucket ${b} exists" \
    || fail "bucket ${b} is missing — run: make buckets-init"
done

# ---------------------------------------------------------------------------
#  3. Versioning
# ---------------------------------------------------------------------------
#  On for raw and staged, off for curated. The consequence of getting this
#  wrong is silent: a re-run overwrites the previous result and there is
#  nothing left to compare against.
# ---------------------------------------------------------------------------
info "Versioning"

for b in "$RAW" "$STAGED"; do
  mc version info "local/${b}" | grep -qi enabled \
    && pass "versioning is enabled on ${b}" \
    || fail "versioning is NOT enabled on ${b} — overwrites would be unrecoverable"
done

# curated is derived and rebuildable, so keeping every version costs storage
# for no recovery value.
mc version info "local/${CURATED}" | grep -qiE 'suspended|un-versioned|not versioned' \
  && pass "versioning is off on ${CURATED}, as intended" \
  || fail "versioning is on for ${CURATED} — it is derived data, this only costs storage"

# ---------------------------------------------------------------------------
#  4. Lifecycle
# ---------------------------------------------------------------------------
#  This is the check that pays for itself. A versioned bucket without a
#  noncurrent-expiry rule accumulates every overwrite for ever, and nothing in
#  the console shows it: the object listing counts current versions only, so
#  the total looks correct while the storage grows.
# ---------------------------------------------------------------------------
info "Lifecycle"

raw_ilm=$(mc ilm rule ls "local/${RAW}")
printf '%s' "$raw_ilm" | grep -qi 'noncurrent' \
  && pass "noncurrent version expiry is set on ${RAW}" \
  || fail "no noncurrent expiry on ${RAW} — old versions would accumulate for ever"

printf '%s' "$raw_ilm" | grep -qiE 'expiration|days to expire' \
  && pass "object expiry is set on ${RAW}" \
  || fail "no object expiry on ${RAW}"

mc ilm rule ls "local/${STAGED}" | grep -qi 'noncurrent' \
  && pass "noncurrent version expiry is set on ${STAGED}" \
  || fail "no noncurrent expiry on ${STAGED}"

# ---------------------------------------------------------------------------
#  5. Metrics
# ---------------------------------------------------------------------------
#  MinIO serves metrics on /minio/v2/metrics/cluster, not /metrics. Without
#  the prometheus.path label and the matching relabel rule in docker-sd, the
#  target is discovered and scrapes a 404 — red for a reason that has nothing
#  to do with MinIO.
# ---------------------------------------------------------------------------
info "Metrics (waiting up to ${METRIC_TIMEOUT}s)"

waited=0
targets=0
while :; do
  body=$(curl -fsS --max-time 10 "${PROM}/api/v1/targets?state=active" 2>/dev/null || true)
  targets=$(printf '%s' "$body" | grep -o '"job": *"minio"' | wc -l | tr -d ' ' || true)
  [ "${targets:-0}" -ge 1 ] && break
  [ "$waited" -ge "$METRIC_TIMEOUT" ] && break
  sleep "$METRIC_INTERVAL"; waited=$((waited + METRIC_INTERVAL))
done
[ "${targets:-0}" -ge 1 ] \
  && pass "Prometheus is scraping MinIO (after ${waited}s)" \
  || fail "no minio scrape target after ${METRIC_TIMEOUT}s — check the prometheus.path label"

series=$(curl -fsS --max-time 10 --get \
           --data-urlencode 'query=count({__name__=~"minio_.*"})' \
           "${PROM}/api/v1/query" 2>/dev/null | grep -o '"[0-9]*"\]' | head -1 | tr -d '"]' || true)
[ "${series:-0}" -gt 0 ] 2>/dev/null \
  && pass "${series} minio metric series present" \
  || fail "no minio metrics — the target may be scraping the wrong path"

# Every metric named by the rules in 02-monitoring/prometheus/rules/05-minio.yml
# must actually exist. A rule naming a metric that is absent never fires and
# never complains; it sits in the UI looking like coverage. Two of the names in
# the first draft of that file were invented by analogy and did nothing.
info "Metrics the alerting rules depend on"

for m in minio_cluster_health_status \
         minio_cluster_capacity_usable_free_bytes \
         minio_cluster_capacity_usable_total_bytes \
         minio_cluster_drive_offline_total \
         minio_s3_requests_errors_total \
         minio_cluster_usage_object_total \
         minio_cluster_usage_version_total \
         minio_node_ilm_expiry_pending_tasks \
         minio_node_ilm_expiry_missed_tasks \
         minio_node_ilm_expiry_missed_freeversions; do
  n=$(curl -fsS --max-time 10 --get --data-urlencode "query=count(${m})" \
        "${PROM}/api/v1/query" 2>/dev/null | grep -o '"[0-9]*"\]' | head -1 | tr -d '"]' || true)
  [ -n "${n}" ] \
    && pass "${m}" \
    || fail "${m} does not exist — the rule using it can never fire"
done

# ---------------------------------------------------------------------------
#  6. The S3 protocol itself
# ---------------------------------------------------------------------------
#  Write an object, read it back, compare it, delete it.
#
#  This depends on nothing but MinIO, which is the point: the export job below
#  needs ClickHouse, and continuous integration runs without the warehouse. If
#  this group were skipped there too, CI would verify that buckets exist and
#  never once confirm that anything can be stored in them.
#
#  Round-tripping the content matters more than the write succeeding. An
#  upload that returns 200 and a GET that returns a truncated body both look
#  like success from one side.
# ---------------------------------------------------------------------------
info "The S3 protocol"

probe_key="_smoke/probe-$(date +%s).txt"
probe_body="smoke test $(date -u +%FT%TZ) $$"

# mc reads from a file, so the payload goes through a throwaway container that
# writes it and uploads it in one step. Piping into `mc pipe` would work too,
# but this way the failure of each half is distinguishable.
if docker run --rm --network dataplatform \
     -e "MC_HOST_local=http://${MINIO_USER}:${MINIO_PASS}@minio:9000" \
     --entrypoint sh "minio/mc:${MC_VERSION}" \
     -c "printf '%s' '${probe_body}' | mc pipe local/${RAW}/${probe_key}" \
     >/dev/null 2>&1; then
  pass "wrote s3://${RAW}/${probe_key}"
else
  fail "could not write to ${RAW} — the bucket exists but is not writable"
fi

fetched=$(docker run --rm --network dataplatform \
  -e "MC_HOST_local=http://${MINIO_USER}:${MINIO_PASS}@minio:9000" \
  --entrypoint sh "minio/mc:${MC_VERSION}" \
  -c "mc cat local/${RAW}/${probe_key}" 2>/dev/null | tr -d '\r' || true)

if [ "$fetched" = "$probe_body" ]; then
  pass "read it back byte for byte"
else
  fail "read back '${fetched:-nothing}', expected '${probe_body}'"
fi

# The bucket is versioned, so the object written a moment ago has a version
# id. Confirming it is what makes the versioning check above more than a
# reading of configuration.
versions=$(mc ls --versions "local/${RAW}/${probe_key}" | grep -c . || true)
[ "${versions:-0}" -ge 1 ] \
  && pass "the object has ${versions} version(s) recorded" \
  || fail "no version recorded — versioning is configured but not taking effect"

# Clean up. A smoke test that leaves debris behind eventually leaves enough of
# it to change what the next run measures.
if mc rm --versions --force "local/${RAW}/${probe_key}" >/dev/null 2>&1; then
  pass "removed the probe object and its versions"
else
  fail "could not remove ${probe_key} — it will accumulate on every run"
fi

# ---------------------------------------------------------------------------
#  6. A job writing through the S3 protocol
# ---------------------------------------------------------------------------
#  Skipped when ClickHouse is absent: the export reads from it. The stack
#  below is what CI runs without the warehouse, and this test has to stay
#  usable there rather than failing on something it was never given.
# ---------------------------------------------------------------------------
info "The export job"

if ! docker ps --format '{{.Names}}' | grep -qx clickhouse-01; then
  skip "export job — ClickHouse is not running"
  skip "exported object — ClickHouse is not running"
elif ! docker image inspect "dataplatform/job-export-orders:${JOB_VERSION}" >/dev/null 2>&1; then
  fail "dataplatform/job-export-orders:${JOB_VERSION} is missing — run: cd ../04-etl && make jobs"
  skip "exported object — the image is missing"
else
  # The most recent day that actually has orders, rather than yesterday. The
  # generator only produces data while the platform is up, so a fixed
  # "yesterday" makes this test pass or fail on whether the stand ran last
  # night — which says nothing about the code.
  day=$($COMPOSE exec -T clickhouse-01 clickhouse-client --database analytics \
          --query "SELECT toDate(created_at) FROM orders FINAL WHERE is_deleted = 0 ORDER BY created_at DESC LIMIT 1" \
          2>/dev/null | tr -d '\r' || true)

  if [ -z "$day" ]; then
    skip "export job — no orders in ClickHouse to export"
    skip "exported object — no orders in ClickHouse to export"
  else
    if docker run --rm --network dataplatform \
         -e CLICKHOUSE_URL=http://clickhouse-01:8123 \
         -e CLICKHOUSE_DB=analytics \
         -e S3_ENDPOINT=http://minio:9000 \
         -e S3_ACCESS_KEY="${MINIO_USER}" \
         -e S3_SECRET_KEY="${MINIO_PASS}" \
         -e S3_BUCKET="${RAW}" \
         -e TARGET_DATE="$day" \
         "dataplatform/job-export-orders:${JOB_VERSION}" >/tmp/export_smoke.log 2>&1; then
      pass "the export job ran for ${day} and exited zero"
    else
      fail "the export job failed for ${day}"
      tail -10 /tmp/export_smoke.log | sed 's/^/        /'
    fi

    # Exiting zero is not the same as writing something. Check the object from
    # outside the job, because the job verifying itself is not a test.
    key="orders/dt=${day}/orders.parquet"
    if mc stat "local/${RAW}/${key}" | grep -qi 'size'; then
      size=$(mc stat "local/${RAW}/${key}" | grep -i '^Size' | head -1 | tr -s ' ')
      pass "object exists in ${RAW}: ${key} (${size})"
    else
      fail "no object at s3://${RAW}/${key} despite the job succeeding"
    fi
  fi
fi

# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$PASSED" "$FAILED" "$SKIPPED"

[ "$FAILED" -eq 0 ]
