# ============================================================================
#  dbt with the ClickHouse adapter
# ============================================================================
#  A job image like every other in this repository: nothing starts it and
#  leaves it running. Airflow runs `dbt build` and the container exits.
#
#  The project is baked in rather than mounted, for the same reason the SQL is
#  baked into the Spark job images: the models are part of what a version of
#  this image means. An image tag that runs different SQL depending on what is
#  on someone's disk is not a versioned artifact.
#
#  `make dbt-dev` mounts the local project over the baked one for iteration —
#  the exception that proves the rule, and it is a development command rather
#  than something a DAG ever does.
# ============================================================================
FROM python:3.12-slim

# git is not optional: dbt uses it for package management, and `dbt deps`
# fails with a confusing error about the package index if it is absent.
RUN apt-get update \
 && apt-get install -y --no-install-recommends git \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /dbt

# Paths are relative to the build CONTEXT, not to this file. The context is
# 07-dbt/ — it has to be, so that COPY project/ below can reach the models —
# which makes this dbt/requirements.txt rather than requirements.txt.
#
# The error when this is wrong names the path it looked for and not the
# directory it looked in, so it reads as a missing file that is plainly there.
COPY dbt/requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# DBT_PROFILES_DIR rather than the default ~/.dbt, so the profile lives with
# the project instead of in a home directory that changes with the user the
# container happens to run as.
ENV DBT_PROFILES_DIR=/dbt \
    PYTHONUNBUFFERED=1

COPY project/ /dbt/

# ----------------------------------------------------------------------------
#  No ENTRYPOINT, deliberately
# ----------------------------------------------------------------------------
#  ENTRYPOINT ["dbt"] is the obvious choice and it breaks Cosmos. Cosmos builds
#  the full command itself, starting with the word dbt, so the container runs
#
#      dbt dbt run --select stg_orders
#
#  and fails with `No such command 'dbt'` — which reads as dbt being absent
#  from an image that plainly contains it.
#
#  Leaving the entrypoint alone means every caller passes the whole command.
#  The Makefile targets do that already; only the bare `docker run` in
#  `make dbt-version` needed the word added.
# ----------------------------------------------------------------------------
CMD ["dbt", "--version"]
