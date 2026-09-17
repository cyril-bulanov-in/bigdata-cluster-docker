# ============================================================================
#  Airflow with the Docker provider and Cosmos
# ============================================================================
#  The base image includes neither, and both are needed for what the DAGs
#  here do: start job containers, and turn a dbt project into one task per
#  model.
#
#  Installed with the constraint file for this exact Airflow version.
#  Installing a provider without constraints is how you silently upgrade a
#  transitive dependency of Airflow itself and get an import error on a class
#  that has nothing to do with what you installed.
# ============================================================================
ARG AIRFLOW_VERSION
FROM apache/airflow:${AIRFLOW_VERSION}

# Repeated after FROM on purpose: an ARG declared before the first FROM is
# only visible to that line, not to the build stage that follows it. This is
# the single most common reason a build argument silently becomes empty.
ARG AIRFLOW_VERSION
ARG PYTHON_VERSION=3.12

USER airflow

# ----------------------------------------------------------------------------
#  Cosmos, and what it does NOT bring with it
# ----------------------------------------------------------------------------
#  astronomer-cosmos turns a dbt project into an Airflow task group with one
#  task per model, so a failed model is a red task rather than a line in the
#  log of a single opaque `dbt build`.
#
#  Note that dbt itself is deliberately absent from this image. Cosmos can run
#  models in-process, which is the usual arrangement and would require it —
#  but that puts the SQL in a mounted directory and the execution inside the
#  scheduler, which is the opposite of how every other job in this repository
#  works.
#
#  Instead Cosmos runs each model with ExecutionMode.DOCKER: a container from
#  dataplatform/dbt, with the project baked in, started and discarded per
#  model. Cosmos needs the project's manifest.json to build the graph, and
#  nothing else — no dbt, no adapter, no database driver.
#
#  The cost is a container start per model. At ten models that is seconds; at
#  a thousand it would not be acceptable, and the in-process mode would be the
#  right answer instead.
# ----------------------------------------------------------------------------
RUN pip install --no-cache-dir \
      "apache-airflow-providers-docker" \
      "astronomer-cosmos" \
      --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
