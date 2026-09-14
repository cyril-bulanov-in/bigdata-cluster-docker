# ============================================================================
#  A Spark job, as an image
# ============================================================================
#  Built FROM the cluster image, not from the base Spark image. That is not a
#  convenience: the driver and the executors must run the same Spark build and
#  the same jars, and inheriting guarantees it. Two images that drifted apart
#  produce serialisation errors that name a class and not the reason.
# ============================================================================
ARG SPARK_IMAGE_LOCAL
FROM ${SPARK_IMAGE_LOCAL}

USER root
COPY app.py /app/app.py
COPY entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh
USER spark

ENTRYPOINT ["/app/entrypoint.sh"]
