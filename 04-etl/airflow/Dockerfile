# ============================================================================
#  Airflow with the Docker provider
# ============================================================================
#  The base image does not include apache-airflow-providers-docker, and
#  DockerOperator is the whole point of this stack: DAGs here start job
#  containers, they do not run job code in-process.
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

RUN pip install --no-cache-dir \
      "apache-airflow-providers-docker" \
      --constraint "https://raw.githubusercontent.com/apache/airflow/constraints-${AIRFLOW_VERSION}/constraints-${PYTHON_VERSION}.txt"
