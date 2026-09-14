#!/usr/bin/env bash
#
# Submits the application to the standalone cluster. Identical in shape to the
# smoke job's entrypoint — see its comments on why spark.driver.host must be
# set explicitly in client mode.

set -euo pipefail

MASTER="${SPARK_MASTER_URL:-spark://spark-master:7077}"
DRIVER_HOST="${SPARK_DRIVER_HOST:-$(hostname)}"

exec /opt/spark/bin/spark-submit \
  --master "$MASTER" \
  --deploy-mode client \
  --name "${SPARK_APP_NAME:-orders-staged}" \
  --conf "spark.driver.host=${DRIVER_HOST}" \
  --conf "spark.driver.memory=${SPARK_DRIVER_MEMORY:-1g}" \
  --conf "spark.executor.memory=${SPARK_EXECUTOR_MEMORY:-1g}" \
  --conf "spark.executor.cores=${SPARK_EXECUTOR_CORES:-1}" \
  --conf "spark.cores.max=${SPARK_CORES_MAX:-4}" \
  --conf "spark.hadoop.fs.s3a.endpoint=${S3_ENDPOINT:-http://minio:9000}" \
  --conf "spark.hadoop.fs.s3a.access.key=${AWS_ACCESS_KEY_ID:-minioadmin}" \
  --conf "spark.hadoop.fs.s3a.secret.key=${AWS_SECRET_ACCESS_KEY:-minioadmin}" \
  /app/app.py "$@"
