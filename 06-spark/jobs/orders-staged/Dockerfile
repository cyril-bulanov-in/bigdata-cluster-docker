# ============================================================================
#  raw -> staged, as an image
# ============================================================================
#  FROM the cluster image, so the driver and the executors run the same Spark
#  build and the same jars. Two images that drifted apart produce
#  serialisation errors naming a class and not the reason.
# ============================================================================
ARG SPARK_IMAGE_LOCAL
FROM ${SPARK_IMAGE_LOCAL}

USER root
COPY app.py /app/app.py
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
USER spark

ENTRYPOINT ["/app/entrypoint.sh"]
