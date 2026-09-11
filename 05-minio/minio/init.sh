#!/usr/bin/env sh
#
# Creates the bucket layout and its policies. Runs once at startup, then exits.
#
# Everything here is idempotent: buckets are created only if absent, policies
# are set to a fixed state rather than appended to. Running it again on a
# populated MinIO changes nothing, which is what lets `make up` call it every
# time without a guard.
#
# Runs inside the mc image, on the platform network, so it reaches MinIO by
# service name exactly as a job would.

set -eu

MINIO_URL="${MINIO_URL:-http://minio:9000}"
RAW="${BUCKET_RAW:-raw}"
STAGED="${BUCKET_STAGED:-staged}"
CURATED="${BUCKET_CURATED:-curated}"
RAW_RETENTION_DAYS="${RAW_RETENTION_DAYS:-30}"

echo "waiting for MinIO at ${MINIO_URL}"
# The container healthcheck already gates this, but a healthy MinIO can still
# refuse the first API call for a moment while it finishes starting.
i=1
while [ "$i" -le 30 ]; do
  if mc alias set local "$MINIO_URL" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null 2>&1; then
    echo "connected on attempt $i"
    break
  fi
  i=$((i + 1))
  sleep 2
done
mc alias set local "$MINIO_URL" "$MINIO_ROOT_USER" "$MINIO_ROOT_PASSWORD" >/dev/null

# ---------------------------------------------------------------------------
#  The three layers
# ---------------------------------------------------------------------------
#  raw       exactly what arrived, never edited. If a transformation turns out
#            to be wrong, this is what it is re-run against — so it is the one
#            layer that must never be "fixed in place".
#  staged    parsed, typed, deduplicated. Still one file per source entity.
#  curated   modelled for reading: joined, aggregated, partitioned for the
#            queries that actually run.
#
#  Three buckets rather than three prefixes in one bucket, because policies,
#  lifecycle rules and access are set per bucket. Separate buckets mean a
#  retention rule on raw cannot accidentally reach curated.
#
#  In AWS these become three buckets or three prefixes of one, and nothing in
#  the job code changes: it only ever sees s3a://<layer>/<path>.
# ---------------------------------------------------------------------------
for bucket in "$RAW" "$STAGED" "$CURATED"; do
  if mc ls "local/${bucket}" >/dev/null 2>&1; then
    echo "bucket ${bucket} already exists"
  else
    mc mb "local/${bucket}"
    echo "created bucket ${bucket}"
  fi
done

# ---------------------------------------------------------------------------
#  Versioning
# ---------------------------------------------------------------------------
#  On raw and staged, off on curated.
#
#  raw and staged are written by jobs that can be re-run. A re-run that
#  overwrites an object destroys the evidence of what the first run produced,
#  and with versioning on it does not: the previous version is still there.
#
#  curated is derived and rebuildable from staged, so keeping every version of
#  it costs storage for no recovery value.
#
#  Versioning is also what makes the lifecycle rule below meaningful — without
#  it, "expire noncurrent versions" has nothing to expire.
# ---------------------------------------------------------------------------
mc version enable "local/${RAW}"    >/dev/null && echo "versioning on:  ${RAW}"
mc version enable "local/${STAGED}" >/dev/null && echo "versioning on:  ${STAGED}"
mc version suspend "local/${CURATED}" >/dev/null 2>&1 || true
echo "versioning off: ${CURATED}"

# ---------------------------------------------------------------------------
#  Lifecycle
# ---------------------------------------------------------------------------
#  Two rules on raw, and they do different things.
#
#  Expiring current objects after N days is a retention decision: how far back
#  the raw layer is kept at all.
#
#  Expiring NONCURRENT versions after 7 days is a cost decision. Without it,
#  versioning quietly accumulates every overwrite for ever — the single most
#  common way an object storage bill grows with no visible cause, because the
#  console shows only current versions and the total looks fine.
#
#  --expire-delete-marker cleans up the tombstones a delete leaves behind in a
#  versioned bucket. They are tiny, but they slow down listing, which is the
#  operation everything else depends on.
# ---------------------------------------------------------------------------
mc ilm rule add "local/${RAW}" \
  --expire-days "${RAW_RETENTION_DAYS}" \
  --noncurrent-expire-days 7 \
  >/dev/null 2>&1 && echo "lifecycle on ${RAW}: expire after ${RAW_RETENTION_DAYS}d, noncurrent after 7d" \
  || echo "lifecycle on ${RAW}: already configured"

mc ilm rule add "local/${STAGED}" \
  --noncurrent-expire-days 7 \
  >/dev/null 2>&1 && echo "lifecycle on ${STAGED}: noncurrent after 7d" \
  || echo "lifecycle on ${STAGED}: already configured"

# ---------------------------------------------------------------------------
#  Access
# ---------------------------------------------------------------------------
#  All three stay private. Stated explicitly rather than left to the default,
#  because "the default is probably fine" is how a data lake ends up readable
#  by anyone who guesses the URL.
# ---------------------------------------------------------------------------
for bucket in "$RAW" "$STAGED" "$CURATED"; do
  mc anonymous set none "local/${bucket}" >/dev/null 2>&1 || true
done
echo "all three buckets are private"

echo ""
echo "layout:"
mc ls local
