#!/usr/bin/env bash
#
# The exporter's config names the JVM it connects to, and the JMX exporter does
# not expand environment variables inside that file. Four brokers would
# therefore mean four nearly identical configs that drift apart over time.
#
# Instead there is one template with a placeholder, filled in here at startup
# from JMX_TARGET. One image, four containers, one set of rules to maintain.

set -euo pipefail

: "${JMX_TARGET:?JMX_TARGET must be set, for example kafka-1:9999}"
LISTEN_PORT="${LISTEN_PORT:-5556}"

sed "s|__JMX_TARGET__|${JMX_TARGET}|g" /opt/jmx/kafka.tpl.yml > /tmp/kafka.yml

echo "jmx-exporter: scraping ${JMX_TARGET}, serving metrics on :${LISTEN_PORT}"

# Usage: java -jar <jar> [HOST:]PORT CONFIG
exec java -jar /opt/jmx/jmx_prometheus_standalone.jar "${LISTEN_PORT}" /tmp/kafka.yml
