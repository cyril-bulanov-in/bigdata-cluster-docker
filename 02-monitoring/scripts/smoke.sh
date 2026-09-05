#!/usr/bin/env bash
#
# Smoke test for the monitoring stack.
#
# "Prometheus is running" proves nothing. Four things can each be false while
# every container is green:
#   * a target is unreachable, so a whole component is invisible
#   * a target answers but exports nothing useful — a wrong JMX rule set
#     produces a perfectly valid, perfectly empty endpoint
#   * the alerting rules failed to parse, so nothing would ever fire
#   * Grafana never picked up the datasource or the dashboard
#
# Exits non-zero on the first failed assertion, so it works as a CI gate.
#
# Usage:  ./scripts/smoke.sh          (or: make smoke)

set -euo pipefail

cd "$(dirname "$0")/.."

COMPOSE="docker compose"

# ---------------------------------------------------------------------------
#  Configuration, read from the same files Compose reads
# ---------------------------------------------------------------------------
#  cut -d= -f2- keeps everything after the first = , so a password containing
#  an = survives. Same helper as in the Makefile, for the same reason: none of
#  these variables exist in the shell just because Compose knows about them.
# ---------------------------------------------------------------------------
read_env() {
  grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"' || true
}

PROM_PORT="$(read_env PROMETHEUS_PORT .env)";        PROM_PORT="${PROM_PORT:-9090}"
GRAF_PORT="$(read_env GRAFANA_PORT .env)";           GRAF_PORT="${GRAF_PORT:-3000}"
GRAF_USER="$(read_env GRAFANA_ADMIN_USER .env)";     GRAF_USER="${GRAF_USER:-admin}"
GRAF_PASS="$(read_env GRAFANA_ADMIN_PASSWORD .env)"; GRAF_PASS="${GRAF_PASS:-admin}"

PROM="http://localhost:${PROM_PORT}"
GRAF="http://localhost:${GRAF_PORT}"

# prometheus, 4x kafka-jmx, node, cadvisor, kafka-lag
EXPECTED_TARGETS=8
EXPECTED_RULES=10
EXPECTED_BROKERS=4

READY_TIMEOUT=240     # cAdvisor and the JMX exporters are the slow ones
GRAF_TIMEOUT=90       # Grafana is a Spring-sized application, it takes a while

# ---------------------------------------------------------------------------
#  How long to wait for a metric to appear
# ---------------------------------------------------------------------------
#  A target counts as up the moment its endpoint returns 200. That is not the
#  same as having the data you want.
#
#  node-exporter and cAdvisor read local state and serve it immediately. The
#  JMX exporters hold an open connection and are just as prompt. But
#  kafka-lag-exporter has to go and ask Kafka for cluster metadata on its own
#  schedule before it can report anything about topics, and its scrape
#  interval is 30s. So there is a window, right after startup, where every
#  target is up and kafka_topic_partitions does not exist yet.
#
#  Checking each metric once turned that window into a failing test. Retrying
#  costs nothing when the metric is already there — the first attempt
#  succeeds — and removes a whole class of false red builds.
# ---------------------------------------------------------------------------
METRIC_TIMEOUT=90
METRIC_INTERVAL=5

PASSED=0
FAILED=0
pass() { printf '  \033[32mPASS\033[0m  %s\n' "$1"; PASSED=$((PASSED + 1)); }
fail() { printf '  \033[31mFAIL\033[0m  %s\n' "$1"; FAILED=$((FAILED + 1)); }
info() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# ---------------------------------------------------------------------------
#  Counting helper
# ---------------------------------------------------------------------------
#  `set -o pipefail` is on, and grep exits 1 when it matches nothing. Without
#  the trailing `|| true` that non-zero status propagates out of the command
#  substitution and `set -e` kills the script — silently, and only when there
#  is nothing to count. In other words, exactly in the failure case the
#  diagnostics were written for.
#
#  Every JSON pattern below is written as '"key": *"value"' with an optional
#  space. Prometheus and Grafana both emit compact JSON today, but matching on
#  somebody else's whitespace is a dependency nobody declares and nobody
#  remembers — until a version bump turns every count into zero.
# ---------------------------------------------------------------------------
count_matches() {
  printf '%s' "$1" | grep -o "$2" | wc -l | tr -d ' ' || true
}

# Ask Prometheus a PromQL question and print the scalar it returns.
# grep rather than jq or python, so the script needs nothing but curl.
promq() {
  curl -fsS --max-time 10 --get --data-urlencode "query=$1" \
    "${PROM}/api/v1/query" 2>/dev/null \
    | grep -o '"[0-9.]*"\]' | head -1 | tr -d '"]' || true
}

# Does this query return any series at all?
has_series() {
  local body
  body=$(curl -fsS --max-time 10 --get --data-urlencode "query=$1" \
           "${PROM}/api/v1/query" 2>/dev/null || true)
  printf '%s' "$body" | grep -q '"status": *"success"' || return 1
  printf '%s' "$body" | grep -q '"result": *\[ *\]' && return 1
  return 0
}

# ---------------------------------------------------------------------------
#  0a. Is the stack running?
# ---------------------------------------------------------------------------
#  Checked before anything else. Without it the script spends four minutes
#  waiting for targets that were never started, then blames Prometheus.
# ---------------------------------------------------------------------------
running=$($COMPOSE ps --services 2>/dev/null | grep -cE '^(prometheus|grafana)$' || true)
if [ "${running:-0}" -lt 2 ]; then
  printf '\n\033[31mThe monitoring stack is not running.\033[0m\n\n'
  echo "  Start it first, then test it:"
  echo "      make up"
  echo "      make test"
  echo ""
  exit 1
fi

# ---------------------------------------------------------------------------
#  0b. Wait for every scrape target to report up
# ---------------------------------------------------------------------------
info "Waiting for all scrape targets (timeout ${READY_TIMEOUT}s)"

deadline=$(( $(date +%s) + READY_TIMEOUT ))
while :; do
  body=$(curl -fsS --max-time 10 "${PROM}/api/v1/targets?state=active" 2>/dev/null || true)
  up=$(count_matches "$body" '"health": *"up"')
  down=$(count_matches "$body" '"health": *"down"')

  if [ "${down:-0}" -eq 0 ] && [ "${up:-0}" -ge "$EXPECTED_TARGETS" ]; then
    echo "  ${up} targets up, none down"
    break
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo ""
    if [ -z "$body" ]; then
      # No answer at all is a different failure from "a target is down", and
      # the fix is somewhere else entirely.
      printf '  \033[31mPrometheus itself did not answer at %s\033[0m\n' "$PROM"
      echo ""
      echo "  It is not a scrape problem — the API is unreachable. Check:"
      echo "      make ps                 is the prometheus container up?"
      echo "      docker logs prometheus  did it exit on a config error?"
      echo "      grep PROMETHEUS_PORT .env   does the port match?"
    else
      echo "  ${up:-0} up / ${down:-0} down after ${READY_TIMEOUT}s"
      echo ""
      echo "  what Prometheus says about the unhealthy ones:"
      printf '%s' "$body" | tr ',' '\n' \
        | grep -E '"(scrapeUrl|health|lastError)"' | sed 's/"//g' | head -40
    fi
    echo ""
    exit 1
  fi
  sleep 5
done

# ---------------------------------------------------------------------------
#  1. Prometheus itself
# ---------------------------------------------------------------------------
info "Prometheus"

if curl -fsS --max-time 10 "${PROM}/-/healthy" >/dev/null 2>&1; then
  pass "reports healthy"
else
  fail "health endpoint did not answer on ${PROM}"
fi

targets_body=$(curl -fsS --max-time 10 "${PROM}/api/v1/targets?state=active" || true)
up_count=$(count_matches "$targets_body" '"health": *"up"')
down_count=$(count_matches "$targets_body" '"health": *"down"')

[ "$down_count" -eq 0 ] \
  && pass "no target is down" \
  || fail "${down_count} target(s) down"

[ "$up_count" -ge "$EXPECTED_TARGETS" ] \
  && pass "${up_count} targets up (expected at least ${EXPECTED_TARGETS})" \
  || fail "only ${up_count} targets up, expected at least ${EXPECTED_TARGETS}"

# A typo in a rules file stops Prometheus loading it. Nothing else in the
# stack notices: the UI looks normal, and no alert would ever fire.
#
# The count is a lower bound, not an equality: later stacks add their own
# rules files to the same directory, so this number only grows.
rules_body=$(curl -fsS --max-time 10 "${PROM}/api/v1/rules" 2>/dev/null || true)
rule_count=$(count_matches "$rules_body" '"type": *"alerting"')
[ "${rule_count:-0}" -ge "$EXPECTED_RULES" ] \
  && pass "${rule_count} alerting rules loaded" \
  || fail "${rule_count:-0} alerting rules loaded, expected at least ${EXPECTED_RULES}"

# ---------------------------------------------------------------------------
#  2. The metrics the dashboards and alerts actually query
# ---------------------------------------------------------------------------
#  A target can be up and export nothing this platform cares about. These check
#  the specific series by name, one per exporter, so a failure points straight
#  at the component that stopped producing.
#
#  Each check retries for up to METRIC_TIMEOUT seconds — see the note above on
#  why "target up" and "metric present" are not the same moment.
# ---------------------------------------------------------------------------
info "Metrics present (waiting up to ${METRIC_TIMEOUT}s each)"

check_metric() {
  local label="$1" query="$2"
  local waited=0
  while :; do
    if has_series "$query"; then
      if [ "$waited" -eq 0 ]; then
        pass "$label"
      else
        pass "$label (appeared after ${waited}s)"
      fi
      return
    fi
    if [ "$waited" -ge "$METRIC_TIMEOUT" ]; then
      fail "$label — no series after ${METRIC_TIMEOUT}s for: $query"
      return
    fi
    sleep "$METRIC_INTERVAL"
    waited=$((waited + METRIC_INTERVAL))
  done
}

check_metric "host CPU (node-exporter)"        'node_cpu_seconds_total'
check_metric "host memory (node-exporter)"     'node_memory_MemAvailable_bytes'
check_metric "host filesystem (node-exporter)" 'node_filesystem_avail_bytes'
check_metric "host network (node-exporter)"    'node_network_receive_bytes_total'
check_metric "container CPU (cAdvisor)"        'container_cpu_usage_seconds_total{name!=""}'
check_metric "container memory (cAdvisor)"     'container_memory_usage_bytes{name!=""}'
check_metric "Kafka throughput (JMX)"          'kafka_server_brokertopicmetrics_bytesinpersec_count'
check_metric "Kafka replication (JMX)"         'kafka_server_replicamanager_underreplicatedpartitions'
check_metric "Kafka broker JVM heap (JMX)"     'kafka_jvm_memory_heap_used_bytes'
# The slow one. This exporter queries Kafka for metadata on its own schedule
# before it can report anything about topics, and it is scraped every 30s.
check_metric "Kafka topics (lag exporter)"     'kafka_topic_partitions'

# ---------------------------------------------------------------------------
#  3. Cluster state, read through the monitoring path
# ---------------------------------------------------------------------------
#  01-kafka asserts these same properties directly against Kafka. Here they are
#  read through exporter, scrape and query instead. If the two ever disagree,
#  the monitoring is lying — which is worse than having none.
# ---------------------------------------------------------------------------
info "Cluster state via monitoring"

brokers=$(promq 'count(kafka_server_brokerstate)')
[ "${brokers:-0}" = "$EXPECTED_BROKERS" ] \
  && pass "all ${EXPECTED_BROKERS} brokers exporting JMX metrics" \
  || fail "${brokers:-0} broker(s) exporting JMX metrics, expected ${EXPECTED_BROKERS}"

controllers=$(promq 'sum(kafka_controller_kafkacontroller_activecontrollercount)')
[ "${controllers:-0}" = "1" ] \
  && pass "exactly one active controller" \
  || fail "active controller count is ${controllers:-unknown}, expected 1"

urp=$(promq 'sum(kafka_server_replicamanager_underreplicatedpartitions)')
[ "${urp:-1}" = "0" ] \
  && pass "no under-replicated partitions" \
  || fail "${urp} under-replicated partition(s)"

containers=$(promq 'count(container_last_seen{name!=""})')
[ "${containers:-0}" -ge 10 ] 2>/dev/null \
  && pass "cAdvisor sees ${containers} containers" \
  || fail "cAdvisor sees ${containers:-0} containers, expected at least 10"

# No alert should be firing on a healthy stack. A firing alert here is either a
# real problem or a rule that is too tight — both worth knowing about.
alerts_body=$(curl -fsS --max-time 10 "${PROM}/api/v1/alerts" 2>/dev/null || true)
firing=$(count_matches "$alerts_body" '"state": *"firing"')
[ "${firing:-0}" -eq 0 ] \
  && pass "no alert is firing" \
  || fail "${firing} alert(s) firing — see: make alerts"

# ---------------------------------------------------------------------------
#  4. Grafana
# ---------------------------------------------------------------------------
info "Grafana"

# Poll: Grafana takes up to a minute to open its HTTP port.
graf_ok=0
graf_deadline=$(( $(date +%s) + GRAF_TIMEOUT ))
while [ "$(date +%s)" -lt "$graf_deadline" ]; do
  if curl -fsS --max-time 5 "${GRAF}/api/health" 2>/dev/null | grep -q '"database": *"ok"'; then
    graf_ok=1
    break
  fi
  sleep 5
done

if [ "$graf_ok" -eq 1 ]; then
  pass "reports healthy"
else
  fail "health endpoint did not answer within ${GRAF_TIMEOUT}s"
fi

# The API needs credentials, and the admin password is set only when the
# account is first created — editing .env afterwards changes nothing, because
# the password then lives in the grafana-data volume. That mismatch produces a
# 401 that looks nothing like its cause, so it is called out explicitly.
api_probe=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
              -u "${GRAF_USER}:${GRAF_PASS}" "${GRAF}/api/datasources" || true)

if [ "$api_probe" = "401" ]; then
  fail "API rejected ${GRAF_USER} — GRAFANA_ADMIN_PASSWORD in .env does not match"
  echo "        The password only applies when the admin account is created."
  echo "        Fix it one of these ways:"
  echo "          docker compose exec grafana grafana cli admin reset-admin-password '<pass>'"
  echo "          or delete the grafana-data volume and start again"
elif [ "$api_probe" != "200" ]; then
  fail "API returned HTTP ${api_probe} for /api/datasources"
else
  pass "API accepts the credentials from .env"

  ds=$(curl -fsS --max-time 10 -u "${GRAF_USER}:${GRAF_PASS}" "${GRAF}/api/datasources" || true)
  printf '%s' "$ds" | grep -q '"type": *"prometheus"' \
    && pass "Prometheus datasource provisioned" \
    || fail "datasource missing — check grafana/provisioning/datasources"

  dash=$(curl -fsS --max-time 10 -u "${GRAF_USER}:${GRAF_PASS}" \
          "${GRAF}/api/search?type=dash-db" || true)
  printf '%s' "$dash" | grep -q 'platform-overview' \
    && pass "overview dashboard provisioned" \
    || fail "dashboard missing — check grafana/provisioning/dashboards"
fi

# ---------------------------------------------------------------------------
info "Summary"
printf '  %d passed, %d failed\n\n' "$PASSED" "$FAILED"

[ "$FAILED" -eq 0 ]
