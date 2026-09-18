#!/usr/bin/env sh
#
# Registers everything Superset needs to be useful on a fresh volume: the
# warehouse connection, the datasets over it, and the dashboard on top.
#
# All three are idempotent, so this runs on every start. A fresh `make clean`
# comes back with the platform connected and its dashboard built, rather than
# waiting for someone to click it in — which is the whole point: a dashboard
# that exists only in a browser is not part of the project.
#
# ---------------------------------------------------------------------------
#  SUPERSET_SKIP_DATASETS
# ---------------------------------------------------------------------------
#  The connection is a string; registering it needs nobody to be listening.
#  The datasets are not: datasets.py asks ClickHouse what columns each mart
#  has, because a hand-written column list drifts the moment a model changes.
#  The dashboard in turn needs the datasets.
#
#  So on a machine without the warehouse — the CI runner, which starts only
#  the three Superset services — both steps fail on name resolution:
#
#      Failed to resolve 'clickhouse-01' ... Temporary failure in name resolution
#
#  Set SUPERSET_SKIP_DATASETS=1 there. They are then deliberately not run and
#  say so, rather than being wrapped in a `|| true` that would swallow a real
#  failure just as quietly.
#
#  That distinction — could not, versus chose not to — is the same one the
#  smoke tests make by printing SKIP instead of nothing.
# ---------------------------------------------------------------------------
set -eu

DB_NAME="${SUPERSET_CLICKHOUSE_NAME:-ClickHouse marts}"

CH_USER="${CLICKHOUSE_USER:-default}"
CH_PASSWORD="${CLICKHOUSE_PASSWORD:-}"
CH_HOST="${CLICKHOUSE_HOST:-clickhouse-01}"
CH_PORT="${CLICKHOUSE_PORT:-8123}"
CH_DB="${CLICKHOUSE_MARTS_DB:-marts_marts}"

# ---------------------------------------------------------------------------
#  The URI, and the two things easy to get wrong in it
# ---------------------------------------------------------------------------
#  clickhousedb:// — the dialect clickhouse-connect registers. The older
#  clickhouse+native:// belongs to clickhouse-sqlalchemy, which is not what is
#  installed here, and produces "Can't load plugin" naming the dialect rather
#  than the package.
#
#  Port 8123, the HTTP interface, not 9000. clickhouse-connect speaks HTTP;
#  pointing it at the native port produces a timeout rather than a protocol
#  error, because the native port accepts the connection and then waits for
#  bytes that never make sense.
#
#  The password is assembled from the environment rather than written here, so
#  this file carries no credential and can be committed. The consequence to
#  remember: Superset encrypts it with SECRET_KEY, so changing that key later
#  makes the stored connection unreadable — it stays listed and every query
#  fails to decrypt, which reads as a ClickHouse problem.
# ---------------------------------------------------------------------------
if [ -n "$CH_PASSWORD" ]; then
  URI="clickhousedb://${CH_USER}:${CH_PASSWORD}@${CH_HOST}:${CH_PORT}/${CH_DB}"
else
  URI="clickhousedb://${CH_USER}@${CH_HOST}:${CH_PORT}/${CH_DB}"
fi

echo "registering connection '${DB_NAME}' -> clickhousedb://${CH_USER}@${CH_HOST}:${CH_PORT}/${CH_DB}"
superset set-database-uri --database_name "${DB_NAME}" --uri "${URI}"

if [ "${SUPERSET_SKIP_DATASETS:-0}" = "1" ]; then
  echo "datasets:  SKIPPED (SUPERSET_SKIP_DATASETS=1 — no warehouse to read columns from)"
  echo "dashboard: SKIPPED (it needs the datasets)"
  exit 0
fi

# Through the venv's interpreter explicitly. `python` alone resolves to it
# today and need not tomorrow, and the whole class of failure this image has
# already produced is code running under the wrong interpreter.
echo "registering datasets"
/app/.venv/bin/python /app/datasets.py

echo "building the dashboard"
/app/.venv/bin/python /app/dashboard.py
