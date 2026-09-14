#!/usr/bin/env bash
#
# Submits the application to the standalone cluster.
#
# Everything configurable arrives as an environment variable, so the same
# image runs against this cluster, a bigger one, or EMR Serverless with a
# different --master and nothing else changed.

set -euo pipefail

MASTER="${SPARK_MASTER_URL:-spark://spark-master:7077}"

# ---------------------------------------------------------------------------
#  Why spark.driver.host has to be set explicitly
# ---------------------------------------------------------------------------
#  This runs in client mode: the driver lives in this container and the
#  executors live on the workers. Executors connect BACK to the driver, so
#  they need a name that resolves to it.
#
#  Left alone, Spark advertises whatever the container thinks its hostname is
#  — a random hex id that no other container can resolve. The job then starts,
#  gets executors, and hangs: the driver waits for executors that are failing
#  to connect to it, with nothing in the driver log to say so.
#
#  DRIVER_HOST must therefore match the --name the container was started with,
#  so Docker's DNS resolves it on the platform network. See `make spark-job`.
# ---------------------------------------------------------------------------
DRIVER_HOST="${SPARK_DRIVER_HOST:-$(hostname)}"

exec /opt/spark/bin/spark-submit \
  --master "$MASTER" \
  --deploy-mode client \
  --name "${SPARK_APP_NAME:-spark-smoke}" \
  --conf "spark.driver.host=${DRIVER_HOST}" \
  --conf "spark.driver.memory=${SPARK_DRIVER_MEMORY:-1g}" \
  --conf "spark.executor.memory=${SPARK_EXECUTOR_MEMORY:-1g}" \
  --conf "spark.executor.cores=${SPARK_EXECUTOR_CORES:-1}" \
  --conf "spark.cores.max=${SPARK_CORES_MAX:-4}" \
  --conf "spark.hadoop.fs.s3a.endpoint=${S3_ENDPOINT:-http://minio:9000}" \
  --conf "spark.hadoop.fs.s3a.access.key=${AWS_ACCESS_KEY_ID:-minioadmin}" \
  --conf "spark.hadoop.fs.s3a.secret.key=${AWS_SECRET_ACCESS_KEY:-minioadmin}" \
  /app/app.py "$@"
