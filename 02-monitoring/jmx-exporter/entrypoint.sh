#!/usr/bin/env bash
#
# The exporter's config names the JVM it connects to, and the JMX exporter does
# not expand environment variables inside that file. Four brokers would
# therefore mean four nearly identical configs that drift apart over time.
#
# Instead there is one template per kind of JVM, and this script fills in the
# target at startup. One image serves every JMX source on the platform:
#
#   JMX_CONFIG=kafka    (default)  Kafka brokers
#   JMX_CONFIG=connect             Kafka Connect and the Debezium connectors
#
# Each template exposes a different set of beans, because the MBeans of a
# broker and of a Connect worker have nothing in common. Pointing the Kafka
# template at Connect produces a valid, empty endpoint — the worst kind of
# failure, since the scrape target stays green.

set -euo pipefail

: "${JMX_TARGET:?JMX_TARGET must be set, for example kafka-1:9999}"
JMX_CONFIG="${JMX_CONFIG:-kafka}"
LISTEN_PORT="${LISTEN_PORT:-5556}"

TEMPLATE="/opt/jmx/${JMX_CONFIG}.tpl.yml"

if [ ! -f "$TEMPLATE" ]; then
  echo "ERROR: no template for JMX_CONFIG='${JMX_CONFIG}'" >&2
  echo "       available:" >&2
  ls -1 /opt/jmx/*.tpl.yml | sed 's|/opt/jmx/||; s|\.tpl\.yml||; s|^|         |' >&2
  exit 1
fi

sed "s|__JMX_TARGET__|${JMX_TARGET}|g" "$TEMPLATE" > /tmp/jmx.yml

echo "jmx-exporter: config=${JMX_CONFIG} target=${JMX_TARGET} port=${LISTEN_PORT}"

# Usage: java -jar <jar> [HOST:]PORT CONFIG
exec java -jar /opt/jmx/jmx_prometheus_standalone.jar "${LISTEN_PORT}" /tmp/jmx.yml
