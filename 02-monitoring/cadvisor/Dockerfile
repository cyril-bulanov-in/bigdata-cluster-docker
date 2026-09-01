# ============================================================================
#  cAdvisor — per-container CPU, memory, network and disk metrics
# ============================================================================
#
#  Why build this instead of pulling gcr.io/cadvisor/cadvisor: that registry
#  stopped receiving new tags. Recent versions are simply not published there,
#  and pinning to the newest tag that happens to exist means running code that
#  is years old.
#
#  What the project does still ship on every release is a static binary per
#  architecture:
#      cadvisor-<version>-linux-amd64
#      cadvisor-<version>-linux-arm64
#  So we take the binary from the GitHub release and put it on a minimal
#  Debian image. Same reasoning as jmx-exporter/Dockerfile: when there is no
#  maintained image, take the artifact the maintainers actually publish.
#
#  Unlike the JMX exporter, this project publishes no checksum file, so the
#  download cannot be verified against a hash. Instead the binary is executed
#  during the build — see the last RUN.
# ============================================================================

# ---------------------------------------------------------------------------
#  Stage 1 — fetch the binary
# ---------------------------------------------------------------------------
#  A separate stage so that curl, its CA certificates and the apt cache stay
#  out of the image that actually runs.
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim AS fetch

# Supplied by docker-compose.yml, which reads it from .env
ARG CADVISOR_VERSION

# TARGETARCH is filled in by BuildKit automatically: amd64 on an Intel machine,
# arm64 on Apple Silicon or a Raspberry Pi. The release asset names use exactly
# these words, so one Dockerfile covers both without a conditional.
ARG TARGETARCH

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

RUN set -eux; \
    URL="https://github.com/google/cadvisor/releases/download/${CADVISOR_VERSION}/cadvisor-${CADVISOR_VERSION}-linux-${TARGETARCH}"; \
    echo "downloading ${URL}"; \
    curl -fsSL "$URL" -o /cadvisor; \
    chmod +x /cadvisor; \
    # A silent redirect to an error page would leave a small HTML file that
    # looks like a binary until the container starts.
    test -s /cadvisor

# ---------------------------------------------------------------------------
#  Stage 2 — the image that runs
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

# libpfm4 is the perf-event library some cAdvisor builds link against.
# curl exists only so the container can have a healthcheck; without it Docker
# has no way to ask cAdvisor whether it is alive.
RUN apt-get update \
 && apt-get install -y --no-install-recommends libpfm4 curl \
 && rm -rf /var/lib/apt/lists/*

COPY --from=fetch /cadvisor /usr/local/bin/cadvisor

# Run it once at build time. This is the checksum substitute: it catches a
# binary built for the wrong architecture and a missing shared library, both
# of which would otherwise only appear at startup. Failing the build is much
# easier to debug than a container that exits immediately.
RUN /usr/local/bin/cadvisor -version

EXPOSE 8080

# -logtostderr sends logs to the container log, where `docker logs` looks for
# them, instead of to files inside the container.
ENTRYPOINT ["/usr/local/bin/cadvisor", "-logtostderr"]
