#!/usr/bin/env bash
#
# Registers the Debezium Postgres connector with Kafka Connect.
#
# Why a script rather than a .json file: the configuration needs the database
# credentials, and Kafka Connect does not expand environment variables inside
# a connector config. Something has to substitute them, and a shell heredoc
# does it without a templating tool — while also allowing real comments, which
# JSON does not have.
#
# Idempotent: it PUTs to /connectors/<name>/config, which creates the connector
# if it is absent and updates it if it exists. Running it twice is harmless,
# and changing a setting here and re-running is the normal way to edit one.
#
# Usage:  ./connect/register-connector.sh        (or: make connector)

set -euo pipefail

cd "$(dirname "$0")/.."

read_env() {
  grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

PG_DB="$(read_env POSTGRES_DB .env)";        PG_DB="${PG_DB:-shop}"
PG_USER="$(read_env POSTGRES_USER .env)";    PG_USER="${PG_USER:-app}"
PG_PASS="$(read_env POSTGRES_PASSWORD .env)"; PG_PASS="${PG_PASS:-app}"
CONNECT_PORT="$(read_env CONNECT_PORT .env)"; CONNECT_PORT="${CONNECT_PORT:-8083}"

CONNECT="http://localhost:${CONNECT_PORT}"
NAME="postgres-source"

# ---------------------------------------------------------------------------
#  Wait for the Connect REST API
# ---------------------------------------------------------------------------
#  The container reports healthy once the port answers, but the worker needs a
#  further moment to finish joining its group and loading plugins. Registering
#  during that window returns a confusing 500.
# ---------------------------------------------------------------------------
printf 'waiting for Kafka Connect at %s ' "$CONNECT"
for _ in $(seq 1 60); do
  if curl -fsS --max-time 3 "${CONNECT}/connector-plugins" >/dev/null 2>&1; then
    echo "— ready"
    break
  fi
  printf '.'
  sleep 3
done
echo ""

if ! curl -fsS --max-time 5 "${CONNECT}/connector-plugins" >/dev/null 2>&1; then
  echo "ERROR: Kafka Connect did not answer at ${CONNECT}" >&2
  echo "       check: docker logs kafka-connect" >&2
  exit 1
fi

# Confirm the Postgres plugin is actually in the image before trying to use it.
# A missing plugin otherwise surfaces as a class-not-found error buried in the
# connector's status.
if ! curl -fsS "${CONNECT}/connector-plugins" | grep -q 'PostgresConnector'; then
  echo "ERROR: the Debezium Postgres plugin is not present in this image" >&2
  curl -fsS "${CONNECT}/connector-plugins" | tr ',' '\n' | grep '"class"' >&2 || true
  exit 1
fi

# ---------------------------------------------------------------------------
#  The configuration
# ---------------------------------------------------------------------------
read -r -d '' CONFIG <<JSON || true
{
  "connector.class": "io.debezium.connector.postgresql.PostgresConnector",

  "database.hostname": "postgres",
  "database.port": "5432",
  "database.user": "${PG_USER}",
  "database.password": "${PG_PASS}",
  "database.dbname": "${PG_DB}",

  "topic.prefix": "cdc",
  "table.include.list": "public.customers,public.products,public.orders,public.order_items",

  "plugin.name": "pgoutput",
  "slot.name": "debezium_slot",
  "publication.name": "debezium_pub",
  "publication.autocreate.mode": "filtered",

  "snapshot.mode": "initial",

  "decimal.handling.mode": "string",
  "time.precision.mode": "connect",

  "transforms": "unwrap",
  "transforms.unwrap.type": "io.debezium.transforms.ExtractNewRecordState",
  "transforms.unwrap.delete.tombstone.handling.mode": "rewrite",
  "transforms.unwrap.add.fields": "op,source.lsn,source.ts_ms,table",

  "topic.creation.enable": "true",
  "topic.creation.default.replication.factor": "3",
  "topic.creation.default.partitions": "6",
  "topic.creation.default.cleanup.policy": "delete",
  "topic.creation.default.retention.ms": "604800000",

  "heartbeat.interval.ms": "10000",
  "tasks.max": "1"
}
JSON

# ---------------------------------------------------------------------------
#  What each group of settings does
# ---------------------------------------------------------------------------
#
#  topic.prefix + table.include.list
#      Topics come out as <prefix>.<schema>.<table>: cdc.public.orders and so
#      on. Only the four listed tables are captured.
#
#  plugin.name = pgoutput
#      The logical decoding plugin built into Postgres itself. The alternatives
#      (decoderbufs, wal2json) are extensions that would have to be installed
#      into the database image.
#
#  slot.name / publication.name / publication.autocreate.mode
#      Debezium creates both on first start. This is why the schema does not
#      create them: a replication slot with no consumer makes Postgres retain
#      write-ahead log forever, and the disk fills with no obvious culprit.
#      `filtered` means the publication covers only the listed tables.
#
#  snapshot.mode = initial
#      Take a consistent snapshot of existing rows, then switch to streaming.
#      Snapshot rows arrive with op = 'r' (read), which is how you tell a
#      backfill row from a live insert.
#
#  decimal.handling.mode = string
#      The default, `precise`, encodes numeric as base64 bytes plus a scale —
#      correct and unreadable. `string` keeps full precision, stays legible,
#      and ClickHouse parses it straight into Decimal without a float in the
#      middle losing a cent.
#
#  time.precision.mode = connect
#      The default gives microseconds for timestamptz. `connect` gives
#      milliseconds, which maps directly onto DateTime64(3).
#
#  transforms.unwrap
#      Debezium's native message is an envelope: {before, after, source, op,
#      ts_ms}. ExtractNewRecordState replaces it with the row itself plus a few
#      metadata columns, which is far easier to consume.
#
#      For a delete there is no `after`, so the transform falls back to
#      `before` — and that is precisely why REPLICA IDENTITY FULL was set on
#      the tables in the schema. Without it a delete would arrive as a primary
#      key and nothing else.
#
#      `rewrite` emits the deleted row with a __deleted flag rather than
#      dropping it. That flag becomes is_deleted in the ClickHouse staging
#      table. (The option was renamed in Debezium 2.5; the old name was
#      delete.handling.mode, and older examples on the internet still use it.)
#
#      add.fields gives __op, __source_lsn, __source_ts_ms and __table.
#      __source_lsn is the write-ahead log position, monotonic per database —
#      it is what ReplacingMergeTree will use as its version column.
#
#  topic.creation.*
#      Stated explicitly rather than relying on broker auto-creation, so the
#      replication factor is a decision rather than a default.
#
#  heartbeat.interval.ms
#      If the watched tables go idle while the rest of the server is busy, the
#      slot's confirmed position stops advancing and WAL piles up. A periodic
#      heartbeat keeps it moving.
#
#  tasks.max = 1
#      The Postgres connector cannot be parallelised: one replication slot,
#      one ordered stream. A higher number is silently ignored.
# ---------------------------------------------------------------------------

echo "registering connector '${NAME}'"
http_code=$(curl -s -o /tmp/connect-response.json -w '%{http_code}' \
  -X PUT "${CONNECT}/connectors/${NAME}/config" \
  -H 'Content-Type: application/json' \
  -d "$CONFIG")

if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
  echo "accepted (HTTP ${http_code})"
else
  echo "ERROR: Connect returned HTTP ${http_code}" >&2
  # The body carries the actual complaint — usually a rejected option name.
  cat /tmp/connect-response.json >&2
  echo "" >&2
  exit 1
fi

echo ""
echo "status (tasks take a few seconds to reach RUNNING):"
sleep 5
curl -fsS "${CONNECT}/connectors/${NAME}/status" | tr ',' '\n' | grep -E '"(name|state|worker_id|trace)"' | sed 's/[{}"]//g' || true
