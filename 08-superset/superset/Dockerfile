# ============================================================================
#  Superset with the drivers it needs
# ============================================================================
#  The only reason this image exists. Everything else about Superset is
#  configuration, which is mounted rather than baked — the drivers cannot be,
#  because a driver is code.
# ============================================================================
ARG SUPERSET_VERSION
FROM apache/superset:${SUPERSET_VERSION}

# The base image runs as the `superset` user. Installing needs root.
USER root

COPY superset/requirements.txt /tmp/requirements.txt

# ----------------------------------------------------------------------------
#  Installing into a pip-less virtualenv
# ----------------------------------------------------------------------------
#  Superset 6 runs from a virtualenv at /app/.venv, built by uv. Three things
#  follow from that, and each produced a different failure:
#
#    `pip install`                   succeeds, and installs into the system
#                                    interpreter at /usr/local/bin/pip that
#                                    Superset never consults. The package is
#                                    on disk and absent from the application:
#                                      ModuleNotFoundError: No module named 'psycopg2'
#                                      ... File "/app/.venv/lib/python3.10/..."
#                                    The path in that traceback is the whole
#                                    diagnosis and is easy to read past — the
#                                    error names a module while the fix is
#                                    about an interpreter.
#
#    `/app/.venv/bin/pip`            exit 127. The file does not exist; uv
#                                    does not put pip in the venvs it creates.
#
#    `/app/.venv/bin/python -m pip`  No module named pip, for the same reason.
#
#  uv installs into a venv it did not have to create, given the interpreter to
#  target.
# ----------------------------------------------------------------------------
RUN uv pip install --python /app/.venv/bin/python \
      --no-cache -r /tmp/requirements.txt

# ----------------------------------------------------------------------------
#  Assert rather than assume
# ----------------------------------------------------------------------------
#  Every one of the three failures above "succeeded" in some sense: the build
#  finished, the layer was cached, and the image looked ready. The driver was
#  missing only when Superset first needed it, minutes later, in a container
#  whose error mentioned neither the build nor the install.
#
#  An explicit import moves that discovery to build time, where it belongs.
# ----------------------------------------------------------------------------
RUN /app/.venv/bin/python -c "import psycopg2, clickhouse_connect, statsd; \
print('drivers present:', psycopg2.__version__, clickhouse_connect.__version__, statsd.__version__)"

# Back to the unprivileged user the image was built around. Superset does not
# need root at runtime, and leaving it as root would be a habit worth not
# forming.
USER superset
