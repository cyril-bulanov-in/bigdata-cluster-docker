#!/usr/bin/env sh
#
# Registers the ClickHouse connection, so it exists after `make clean`.
#
# ---------------------------------------------------------------------------
#  Why a script rather than provisioning
# ---------------------------------------------------------------------------
#  Grafana reads a provisioning directory at startup and reconciles what it
#  finds there. Superset has no equivalent: connections live in its metadata
#  database and the only file-based path in is an import.
#
#  So this runs `superset set-database-uri`, which is idempotent — it creates
#  the connection or updates the existing one of that name, and says which.
#  Running it on every start therefore costs nothing and guarantees that a
#  fresh volume comes back with the connection already there.
#
#  A connection clicked into the UI is not part of the project and does not
#  survive a rebuild. That is the same argument as the provisioned Grafana
#  dashboard in step 2, reached by a different route.
#
# ---------------------------------------------------------------------------
#  The password is not in this file
# ---------------------------------------------------------------------------
#  Superset encrypts connection passwords in its metadata database with
#  SECRET_KEY. The URI is assembled here from the environment, so the file
#  carries no credential and can be committed.
#
#  The consequence to remember: change SECRET_KEY after this has run and the
#  stored password becomes unreadable. Superset starts, the connection is
#  listed, and every query through it fails to decrypt — which reads as a
#  ClickHouse problem.
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
# ---------------------------------------------------------------------------
if [ -n "$CH_PASSWORD" ]; then
  URI="clickhousedb://${CH_USER}:${CH_PASSWORD}@${CH_HOST}:${CH_PORT}/${CH_DB}"
else
  URI="clickhousedb://${CH_USER}@${CH_HOST}:${CH_PORT}/${CH_DB}"
fi

echo "registering '${DB_NAME}' -> clickhousedb://${CH_USER}@${CH_HOST}:${CH_PORT}/${CH_DB}"

superset set-database-uri --database_name "${DB_NAME}" --uri "${URI}"

echo "done"
