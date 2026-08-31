#!/usr/bin/env bash
#
# Smoke test for the Kafka stack.
#
# Runs against an already-running cluster and asserts the things that a
# successful `docker compose up` does NOT prove: that four brokers actually
# registered, that the controller quorum has exactly three voters, that the
# demo topic is replicated the way it was asked to be, and that a message
# written on one end comes back out the other.
#
# Exits non-zero on the first failed assertion, so it works as a CI gate.
#
# Usage:  ./scripts/smoke.sh          (or: make smoke)

set -euo pipefail

# ---------------------------------------------------------------------------
#  Settings
# ---------------------------------------------------------------------------
cd "$(dirname "$0")/.."

COMPOSE="docker compose"
BOOTSTRAP="kafka-1:9092,kafka-2:9092,kafka-3:9092,kafka-4:9092"
KAFKA_BIN="/opt/kafka/bin"

EXPECTED_BROKERS=4
EXPECTED_VOTERS=3
DEMO_TOPIC="demo.events"
EXPECTED_PARTITIONS=6
EXPECTED_RF=3
SMOKE_TOPIC="smoke.roundtrip"

READY_TIMEOUT=180        # seconds to wait for all brokers to register
UI_TIMEOUT=90            # seconds to wait for Kafbat UI to report healthy

# Host port of Kafbat UI. Read from .env when present, default 8080.
KAFBAT_PORT="$(grep -E '^KAFBAT_PORT=' .env 2>/dev/null | cut -d= -f2 || true)"
KAFBAT_PORT="${KAFBAT_PORT:-8080}"

# ---------------------------------------------------------------------------
#  Output helpers
# ---------------------------------------------------------------------------
PASSED=0
FAILED=0

pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# Run a Kafka CLI tool inside kafka-1. -T disables TTY allocation, which CI needs.
kafka_exec() {
  $COMPOSE exec -T kafka-1 "$@"
}

# ---------------------------------------------------------------------------
#  0a. Is the stack even running?
# ---------------------------------------------------------------------------
#  Checked before anything else. Without this the script spends three minutes
#  waiting for brokers that were never started and then reports "0 of 4",
#  which points at Kafka instead of at the missing `make up`.
# ---------------------------------------------------------------------------
# `compose ps` lists only running containers unless -a is passed, so --services
# on its own is already the running set. Deliberately avoiding --status/--filter:
# if a compose version did not support the flag, the command would error, the
# count would come out as 0 and the script would blame a stack that is fine.
running=$($COMPOSE ps --services 2>/dev/null | grep -c '^kafka-[1-4]$' || true)

if [ "${running:-0}" -eq 0 ]; then
  printf '\n\033[31mThe stack is not running.\033[0m\n\n'
  echo "  Start it first, then test it:"
  echo "      make up"
  echo "      make test"
  echo ""
  exit 1
fi

if [ "$running" -lt "$EXPECTED_BROKERS" ]; then
  printf '\n\033[31mOnly %s of %s broker containers are running.\033[0m\n\n' "$running" "$EXPECTED_BROKERS"
  $COMPOSE ps
  echo ""
  echo "  hint: make logs"
  exit 1
fi

# ---------------------------------------------------------------------------
#  0b. Wait until the brokers answer over the network
# ---------------------------------------------------------------------------
#  Containers can be running while Kafka is still formatting storage or
#  electing a controller. This waits for the protocol, not for the process.
# ---------------------------------------------------------------------------
info "Waiting for brokers to register (timeout ${READY_TIMEOUT}s)"

deadline=$(( $(date +%s) + READY_TIMEOUT ))
while :; do
  count=$(kafka_exec "${KAFKA_BIN}/kafka-broker-api-versions.sh" \
            --bootstrap-server "$BOOTSTRAP" 2>/dev/null | grep -c '(id: ' || true)
  if [ "${count:-0}" -ge "$EXPECTED_BROKERS" ]; then
    echo "  all ${EXPECTED_BROKERS} brokers responding"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "  only ${count:-0} of ${EXPECTED_BROKERS} brokers responded before timeout"
    echo ""
    echo "  the underlying error, with stderr this time:"
    kafka_exec "${KAFKA_BIN}/kafka-broker-api-versions.sh" \
      --bootstrap-server "$BOOTSTRAP" 2>&1 | head -20 || true
    echo ""
    echo "  hint: make logs"
    exit 1
  fi
  sleep 5
done

# ---------------------------------------------------------------------------
#  1. Cluster membership
# ---------------------------------------------------------------------------
info "Cluster membership"

brokers=$(kafka_exec "${KAFKA_BIN}/kafka-broker-api-versions.sh" \
            --bootstrap-server "$BOOTSTRAP" | grep -c '(id: ' || true)

if [ "$brokers" -eq "$EXPECTED_BROKERS" ]; then
  pass "broker count is ${EXPECTED_BROKERS}"
else
  fail "broker count is ${brokers}, expected ${EXPECTED_BROKERS}"
fi

# ---------------------------------------------------------------------------
#  2. Controller quorum
# ---------------------------------------------------------------------------
#  In the replication view every node shows a status: Leader or Follower means
#  it votes, Observer means it is a plain broker. Node 4 must be an Observer —
#  that is the whole point of the 3-controller topology.
# ---------------------------------------------------------------------------
info "Controller quorum"

quorum=$(kafka_exec "${KAFKA_BIN}/kafka-metadata-quorum.sh" \
           --bootstrap-server "$BOOTSTRAP" describe --replication || true)

voters=$(printf '%s\n' "$quorum" | awk 'NR > 1 && ($NF == "Leader" || $NF == "Follower")' | wc -l | tr -d ' ')
observers=$(printf '%s\n' "$quorum" | awk 'NR > 1 && $NF == "Observer"' | wc -l | tr -d ' ')
leaders=$(printf '%s\n' "$quorum" | awk 'NR > 1 && $NF == "Leader"' | wc -l | tr -d ' ')

if [ "$voters" -eq "$EXPECTED_VOTERS" ]; then
  pass "quorum has ${EXPECTED_VOTERS} voters"
else
  fail "quorum has ${voters} voters, expected ${EXPECTED_VOTERS}"
  printf '%s\n' "$quorum"
fi

if [ "$leaders" -eq 1 ]; then
  pass "exactly one active controller"
else
  fail "found ${leaders} controller leaders, expected 1"
fi

if [ "$observers" -ge 1 ]; then
  pass "broker-only node present as observer"
else
  fail "no observer found — is kafka-4 still running as a controller?"
fi

# ---------------------------------------------------------------------------
#  3. Demo topic layout
# ---------------------------------------------------------------------------
info "Topic ${DEMO_TOPIC}"

if ! desc=$(kafka_exec "${KAFKA_BIN}/kafka-topics.sh" \
              --bootstrap-server "$BOOTSTRAP" --describe --topic "$DEMO_TOPIC" 2>&1); then
  fail "topic ${DEMO_TOPIC} not found — did kafka-init run?"
  desc=""
fi

if printf '%s\n' "$desc" | grep -q "PartitionCount: ${EXPECTED_PARTITIONS}"; then
  pass "partition count is ${EXPECTED_PARTITIONS}"
else
  fail "unexpected partition count"
fi

if printf '%s\n' "$desc" | grep -q "ReplicationFactor: ${EXPECTED_RF}"; then
  pass "replication factor is ${EXPECTED_RF}"
else
  fail "unexpected replication factor"
fi

# Every partition must have a full in-sync replica set. A short ISR means a
# replica is lagging or a broker is down — the cluster still answers, so this
# is exactly the kind of thing that silently passes an "is it up" check.
short_isr=$(printf '%s\n' "$desc" \
  | awk -F'Isr: ' 'NF > 1 {
        split($2, tail, "\t");
        gsub(/ /, "", tail[1]);
        n = split(tail[1], members, ",");
        if (n != '"$EXPECTED_RF"') bad++;
      }
      END { print bad + 0 }')

if [ "$short_isr" -eq 0 ]; then
  pass "all partitions have a full ISR"
else
  fail "${short_isr} partition(s) with an incomplete ISR"
  printf '%s\n' "$desc"
fi

# ---------------------------------------------------------------------------
#  4. Round trip
# ---------------------------------------------------------------------------
#  Membership and metadata can all look right while the data path is broken.
#  Write a message, read it back.
# ---------------------------------------------------------------------------
info "Produce and consume"

marker="smoke-$(date +%s)-$$"

kafka_exec "${KAFKA_BIN}/kafka-topics.sh" --bootstrap-server "$BOOTSTRAP" \
  --create --if-not-exists --topic "$SMOKE_TOPIC" \
  --partitions 1 --replication-factor "$EXPECTED_RF" >/dev/null 2>&1 || true

if printf '%s\n' "$marker" | kafka_exec "${KAFKA_BIN}/kafka-console-producer.sh" \
     --bootstrap-server "$BOOTSTRAP" --topic "$SMOKE_TOPIC" \
     --producer-property acks=all >/dev/null 2>&1; then
  pass "produced with acks=all"
else
  fail "produce failed"
fi

received=$(kafka_exec "${KAFKA_BIN}/kafka-console-consumer.sh" \
             --bootstrap-server "$BOOTSTRAP" --topic "$SMOKE_TOPIC" \
             --from-beginning --max-messages 1 --timeout-ms 30000 2>/dev/null || true)

if printf '%s\n' "$received" | grep -q "$marker"; then
  pass "consumed the same message back"
else
  fail "message did not come back within 30s"
fi

# ---------------------------------------------------------------------------
#  5. Kafbat UI
# ---------------------------------------------------------------------------
info "Kafbat UI"

# The UI is a Spring application and can take up to a minute to come up,
# so this polls rather than asking once.
ui_ok=0
ui_deadline=$(( $(date +%s) + UI_TIMEOUT ))
while [ "$(date +%s)" -lt "$ui_deadline" ]; do
  if curl -fsS --max-time 5 "http://localhost:${KAFBAT_PORT}/actuator/health" 2>/dev/null \
       | grep -q '"status":"UP"'; then
    ui_ok=1
    break
  fi
  sleep 5
done

if [ "$ui_ok" -eq 1 ]; then
  pass "UI reports healthy on port ${KAFBAT_PORT}"
else
  fail "UI did not report healthy on port ${KAFBAT_PORT} within ${UI_TIMEOUT}s"
fi

# ---------------------------------------------------------------------------
#  Summary
# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed\n\n' "$PASSED" "$FAILED"

[ "$FAILED" -eq 0 ]
