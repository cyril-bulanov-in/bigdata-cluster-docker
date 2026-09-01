# ============================================================================
#  JMX exporter — turns Kafka's JMX metrics into something Prometheus can read
# ============================================================================
#
#  Why build this instead of pulling a ready-made image: there is no maintained
#  official container for the JMX exporter. What sits on Docker Hub is either
#  years out of date or repackaged by a vendor. The exporter itself is a single
#  jar published by the Prometheus project on every release, so we take that
#  jar and put it on a plain JDK image.
#
#  This is the same reasoning that applied to cAdvisor: when there is no
#  maintained image, take the artifact the maintainers actually ship.
# ============================================================================

# eclipse-temurin is the reference OpenJDK build. The -jre variant is the
# smaller runtime-only image: we run a jar, we never compile anything.
FROM eclipse-temurin:21-jre

# Supplied by docker-compose.yml, which reads it from .env
ARG JMX_EXPORTER_VERSION

WORKDIR /opt/jmx

# There are three jars in each release. We want "standalone": it runs its own
# HTTP server and connects to a remote JVM over the network. The "javaagent"
# flavour runs inside the JVM being measured, which would mean editing the
# Kafka containers — those belong to step 1 and are not ours to modify.
#
# The project publishes a .sha256 next to every jar, so the download is
# verified rather than trusted. A truncated download or a proxy serving an
# error page would otherwise only surface at startup, as a confusing Java
# stack trace.
RUN set -eux; \
    BASE="https://github.com/prometheus/jmx_exporter/releases/download/${JMX_EXPORTER_VERSION}"; \
    JAR="jmx_prometheus_standalone-${JMX_EXPORTER_VERSION}.jar"; \
    curl -fsSL "${BASE}/${JAR}"        -o "/opt/jmx/${JAR}"; \
    curl -fsSL "${BASE}/${JAR}.sha256" -o /tmp/jar.sha256; \
    cd /opt/jmx && sha256sum -c /tmp/jar.sha256; \
    mv "/opt/jmx/${JAR}" /opt/jmx/jmx_prometheus_standalone.jar; \
    rm -f /tmp/jar.sha256

# Which JMX beans to collect and what to name them. A template rather than the
# final config — see entrypoint.sh for why.
COPY kafka.tpl.yml /opt/jmx/kafka.tpl.yml
COPY entrypoint.sh /opt/jmx/entrypoint.sh
RUN chmod +x /opt/jmx/entrypoint.sh

# Documentation only. EXPOSE publishes nothing; it records intent for whoever
# reads the image later.
EXPOSE 5556

ENTRYPOINT ["/opt/jmx/entrypoint.sh"]
