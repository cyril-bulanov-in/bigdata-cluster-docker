#!/usr/bin/env bash
#
# Smoke test for the databases stack.
#
# Everything here can be broken while every container is green, which is why
# each assertion exists:
#
#   the generator can be idle, so nothing changes and CDC has nothing to do
#   the connector can be RUNNING while its task has failed
#   the replication slot can be inactive, quietly filling the disk with WAL
#   the ClickHouse cluster can be built with mismatched shards and replicas
#   the Kafka queues can poll happily and read nothing
#   a materialized view can fail on every insert, so topics drain into nowhere
#   rows can arrive on the wrong shard and never deduplicate
#
# The last check runs one row through the whole chain and waits for it.
#
# Usage:  ./scripts/smoke.sh          (or: make smoke)

set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose"

read_env() {
  grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

PG_DB="$(read_env POSTGRES_DB .env)";     PG_DB="${PG_DB:-shop}"
PG_USER="$(read_env POSTGRES_USER .env)"; PG_USER="${PG_USER:-app}"
CH_DB="$(read_env CH_DB .env)";           CH_DB="${CH_DB:-analytics}"
CONNECT_PORT="$(read_env CONNECT_PORT .env)"; CONNECT_PORT="${CONNECT_PORT:-8083}"
CONNECT="http://localhost:${CONNECT_PORT}"

# Set SKIP_CLICKHOUSE=1 to run only the checks that do not need the
# warehouse. Continuous integration does this: eight ClickHouse nodes at 2 GiB
# do not fit on a GitHub runner, so CI starts the source, the capture and the
# broker and skips the rest — see the README.
#
# Skipped checks are printed as SKIP rather than omitted. A summary reading
# "14 passed" would otherwise look like full coverage of a stack that was only
# half tested.
SKIP_CLICKHOUSE="${SKIP_CLICKHOUSE:-0}"

EXPECTED_SHARDS=4
EXPECTED_REPLICAS=8
# 8 staging tables + 4 Kafka queues + 4 materialized views
EXPECTED_OBJECTS=16
E2E_TIMEOUT=60

PASSED=0
FAILED=0
SKIPPED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
skip() { printf '  \033[33mSKIP\033[0m  %s\n' "$1"; SKIPPED=$((SKIPPED + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

psql_q()  { $COMPOSE exec -T postgres psql -U "$PG_USER" -d "$PG_DB" -t -A -c "$1" 2>/dev/null | tr -d '\r' || true; }
# No --database on purpose: a client pinned to a database that does not exist
# fails before it can report anything useful about the cluster.
ch_q()    { $COMPOSE exec -T clickhouse-01 clickhouse-client --query "$1" 2>/dev/null | tr -d '\r' || true; }

# ---------------------------------------------------------------------------
#  0. Is the stack running
# ---------------------------------------------------------------------------
if [ "$SKIP_CLICKHOUSE" = "1" ]; then
  required='^(postgres|kafka-connect)$'; required_count=2
else
  required='^(postgres|clickhouse-01|kafka-connect)$'; required_count=3
fi
running=$($COMPOSE ps --services 2>/dev/null | grep -cE "$required" || true)
if [ "${running:-0}" -lt "$required_count" ]; then
  printf '\n\033[31mThe stack is not running.\033[0m\n\n'
  echo "  Start it first, then test it:"
  echo "      make up"
  echo "      make test"
  echo ""
  exit 1
fi

# ---------------------------------------------------------------------------
#  1. The source database
# ---------------------------------------------------------------------------
info "Postgres, the source"

tables=$(psql_q "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_name IN ('customers','products','orders','order_items')")
[ "${tables:-0}" = "4" ] \
  && pass "all four source tables exist" \
  || fail "${tables:-0} of 4 source tables found"

# 'f' is FULL. Without it a delete event carries the primary key and nothing
# else, and the warehouse learns that a row was removed but not which one.
notfull=$(psql_q "SELECT count(*) FROM pg_class WHERE relname IN ('customers','products','orders','order_items') AND relreplident != 'f'")
[ "${notfull:-1}" = "0" ] \
  && pass "REPLICA IDENTITY FULL on every captured table" \
  || fail "${notfull} table(s) without REPLICA IDENTITY FULL — deletes will arrive empty"

wal=$(psql_q "SHOW wal_level")
[ "$wal" = "logical" ] \
  && pass "wal_level is logical" \
  || fail "wal_level is '${wal}', logical is required for capture"

# ---------------------------------------------------------------------------
#  2. The generator
# ---------------------------------------------------------------------------
#  A static source produces no change events at all, and every check below it
#  would pass on a pipeline that is doing nothing.
# ---------------------------------------------------------------------------
info "Generator, the load"

before=$(psql_q "SELECT count(*) FROM orders")
sleep 8
after=$(psql_q "SELECT count(*) FROM orders")
if [ -n "$before" ] && [ -n "$after" ] && [ "$after" -gt "$before" ]; then
  pass "orders growing: ${before} to ${after} in 8s"
else
  fail "orders did not grow in 8s (${before:-?} to ${after:-?}) — is the generator running?"
fi

# ---------------------------------------------------------------------------
#  3. Change capture
# ---------------------------------------------------------------------------
info "Debezium, the capture"

status=$(curl -fsS --max-time 10 "${CONNECT}/connectors/postgres-source/status" 2>/dev/null || true)
if [ -z "$status" ]; then
  fail "connector not registered — run: make connector"
else
  states=$(printf '%s' "$status" | grep -o '"state": *"[A-Z]*"' | grep -c 'RUNNING' || true)
  # Two states matter: the connector's own and its single task's. A connector
  # can report RUNNING while its task has died.
  [ "${states:-0}" -ge 2 ] \
    && pass "connector and task both RUNNING" \
    || fail "connector or task not RUNNING — see: make cdc-status"
fi

slot=$(psql_q "SELECT active FROM pg_replication_slots WHERE slot_name='debezium_slot'")
[ "$slot" = "t" ] \
  && pass "replication slot is active" \
  || fail "replication slot is '${slot:-missing}' — an inactive slot makes Postgres retain WAL until the disk fills"

topics=$($COMPOSE exec -T kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server kafka-1:9092 --list 2>/dev/null | grep -c '^cdc\.' || true)
[ "${topics:-0}" -ge 4 ] \
  && pass "${topics} cdc topics exist" \
  || fail "${topics:-0} cdc topics — expected at least 4"

# ---------------------------------------------------------------------------
#  4. The ClickHouse cluster
# ---------------------------------------------------------------------------
info "ClickHouse, the warehouse"

if [ "$SKIP_CLICKHOUSE" = "1" ]; then
  skip "cluster topology — SKIP_CLICKHOUSE is set"
  skip "shard and replica identities — SKIP_CLICKHOUSE is set"
  skip "staging objects — SKIP_CLICKHOUSE is set"
  skip "replica read-only state — SKIP_CLICKHOUSE is set"
  skip "Kafka engine ingestion — SKIP_CLICKHOUSE is set"
  skip "consumer exceptions — SKIP_CLICKHOUSE is set"
  skip "row counts on both sides — SKIP_CLICKHOUSE is set"
  skip "end to end insert and delete — SKIP_CLICKHOUSE is set"
  info "Summary"
  printf '  %d passed, %d failed, %d skipped\n' "$PASSED" "$FAILED" "$SKIPPED"
  echo ""
  echo "  The warehouse was not tested. Everything from Postgres through"
  echo "  Debezium to Kafka was. To cover the rest, run without the flag on a"
  echo "  machine that can hold the cluster:"
  echo "      make up && make connector && sleep 60 && make test"
  echo ""
  [ "$FAILED" -eq 0 ]
  exit $?
fi

shards=$(ch_q "SELECT uniqExact(shard_num) FROM system.clusters WHERE cluster='platform'")
replicas=$(ch_q "SELECT count() FROM system.clusters WHERE cluster='platform'")
[ "${shards:-0}" = "$EXPECTED_SHARDS" ] && [ "${replicas:-0}" = "$EXPECTED_REPLICAS" ] \
  && pass "${shards} shards, ${replicas} replicas" \
  || fail "${shards:-0} shards / ${replicas:-0} replicas, expected ${EXPECTED_SHARDS} / ${EXPECTED_REPLICAS}"

# Sharding and replication are configured in two different places. When the
# macros disagree with remote_servers the cluster looks correct here and
# silently fails to replicate.
distinct=$(ch_q "SELECT count(DISTINCT concat(shard, '/', replica)) FROM (SELECT getMacro('shard') AS shard, getMacro('replica') AS replica FROM clusterAllReplicas('platform', system.one))")
[ "${distinct:-0}" = "$EXPECTED_REPLICAS" ] \
  && pass "every node has a distinct shard/replica identity" \
  || fail "${distinct:-0} distinct identities across ${EXPECTED_REPLICAS} nodes — check: make ch-macros"

objects=$(ch_q "SELECT count(DISTINCT name) FROM system.tables WHERE database='${CH_DB}'")
[ "${objects:-0}" -ge "$EXPECTED_OBJECTS" ] \
  && pass "${objects} objects in ${CH_DB}" \
  || fail "${objects:-0} objects, expected at least ${EXPECTED_OBJECTS} — run: make ch-schema && make ch-ingest"

readonly_replicas=$(ch_q "SELECT count() FROM clusterAllReplicas('platform', system.replicas) WHERE is_readonly = 1 SETTINGS skip_unavailable_shards = 1")
[ "${readonly_replicas:-1}" = "0" ] \
  && pass "no replica is read-only" \
  || fail "${readonly_replicas} replica(s) read-only — they have lost Keeper"

# ---------------------------------------------------------------------------
#  5. Ingestion
# ---------------------------------------------------------------------------
#  The queues can poll happily and read nothing, and a materialized view can
#  fail on every insert while the queue keeps consuming. Both look healthy
#  from outside.
# ---------------------------------------------------------------------------
info "Kafka engine, the ingestion"

read_msgs=$(ch_q "SELECT sum(num_messages_read) FROM clusterAllReplicas('platform', system.kafka_consumers) SETTINGS skip_unavailable_shards = 1")
[ "${read_msgs:-0}" -gt 0 ] 2>/dev/null \
  && pass "${read_msgs} messages read from Kafka" \
  || fail "${read_msgs:-0} messages read — the queues are subscribed but not consuming"

# The column is a nested array, exceptions.text, not last_exception.
errs=$(ch_q "SELECT count() FROM clusterAllReplicas('platform', system.kafka_consumers) WHERE notEmpty(\`exceptions.text\`) SETTINGS skip_unavailable_shards = 1")
[ "${errs:-1}" = "0" ] \
  && pass "no consumer exceptions" \
  || fail "${errs} consumer(s) with exceptions — see: make ch-queues"

# products is the table to compare on, and the comparison is exact.
#
# It is a small dimension that is only ever updated in place: rows are never
# inserted or deleted after seeding, so the deduplicated count in ClickHouse
# must equal the count in Postgres. orders and order_items would need a
# tolerance, because the generator writes to them several times a second and
# any two counts taken a moment apart legitimately differ.
#
# Exact rather than approximate on purpose. A tolerance wide enough to absorb
# timing would also absorb a real divergence, and a warehouse quietly holding
# a different number of rows than its source is the failure this whole stack
# exists to make visible.
pg_products=$(psql_q "SELECT count(*) FROM products")
ch_products=$(ch_q "SELECT count() FROM ${CH_DB}.products FINAL WHERE is_deleted = 0")
if [ -n "$pg_products" ] && [ "$pg_products" = "$ch_products" ]; then
  pass "products match exactly: ${pg_products}"
else
  fail "products differ: postgres ${pg_products:-?}, clickhouse ${ch_products:-?}"
  echo "        A difference here is not automatically a bug. The generator"
  echo "        changes a price roughly once a minute, and this check can land"
  echo "        in the second between the write and its arrival."
  echo ""
  echo "        Run the test again. If it passes, it was timing. If the same"
  echo "        gap persists, capture has genuinely stopped or a materialized"
  echo "        view is failing on insert:"
  echo "            make cdc-status     is Debezium still reading the slot"
  echo "            make ch-queues      are the consumers erroring"
fi

# ---------------------------------------------------------------------------
#  6. End to end
# ---------------------------------------------------------------------------
#  One row through every hop: Postgres WAL, Debezium, Kafka, the ClickHouse
#  Kafka engine, the materialized view, the Distributed table, the sharding
#  key, ReplicatedReplacingMergeTree and FINAL.
#
#  A customer rather than an order, because customers can be deleted: orders
#  have foreign keys pointing at them.
#
#  psql prints the RETURNING value AND a status line like "INSERT 0 1", so
#  head -1 takes the value. Without it the status line ends up concatenated
#  into the next SQL statement.
# ---------------------------------------------------------------------------
info "End to end (timeout ${E2E_TIMEOUT}s per step)"

marker="smoke-$(date +%s)@example.com"
id=$(psql_q "INSERT INTO customers (email, full_name, country_code) VALUES ('${marker}','Smoke Test','ZZ') RETURNING customer_id" | head -1)

if ! [ "${id:-}" -eq "${id:-}" ] 2>/dev/null; then
  fail "could not insert a test customer into Postgres"
else
  arrived=0
  for i in $(seq 1 "$E2E_TIMEOUT"); do
    n=$(ch_q "SELECT count() FROM ${CH_DB}.customers FINAL WHERE customer_id = ${id} AND is_deleted = 0")
    if [ "${n:-0}" = "1" ]; then arrived=$i; break; fi
    sleep 1
  done
  [ "$arrived" -gt 0 ] \
    && pass "insert reached ClickHouse in ${arrived}s" \
    || fail "insert never reached ClickHouse within ${E2E_TIMEOUT}s"

  psql_q "DELETE FROM customers WHERE customer_id = ${id}" >/dev/null
  gone=0
  for i in $(seq 1 "$E2E_TIMEOUT"); do
    n=$(ch_q "SELECT count() FROM ${CH_DB}.customers FINAL WHERE customer_id = ${id} AND is_deleted = 0")
    if [ "${n:-1}" = "0" ]; then gone=$i; break; fi
    sleep 1
  done
  [ "$gone" -gt 0 ] \
    && pass "delete removed it from FINAL in ${gone}s" \
    || fail "delete never propagated within ${E2E_TIMEOUT}s"

  # The tombstone must carry every column, not just the key. That is what
  # REPLICA IDENTITY FULL on the source buys, and it is invisible until a
  # delete actually happens.
  tomb=$(ch_q "SELECT email FROM ${CH_DB}.customers WHERE customer_id = ${id} AND is_deleted = 1 LIMIT 1")
  [ "$tomb" = "$marker" ] \
    && pass "tombstone carries the full row, not just the key" \
    || fail "tombstone email is '${tomb:-empty}' — REPLICA IDENTITY FULL is not working"
fi

# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed, %d skipped\n\n' "$PASSED" "$FAILED" "$SKIPPED"

[ "$FAILED" -eq 0 ]
