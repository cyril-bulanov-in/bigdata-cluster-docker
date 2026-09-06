# ============================================================================
#  A job image that does nothing useful, on purpose
# ============================================================================
#  This exists to debug the mechanics of running a job container from Airflow
#  separately from any real logic: reaching the Docker socket, joining the
#  right network, passing parameters, and where the output ends up.
#
#  Debugging those four things at the same time as a SQL transformation is how
#  you spend an afternoon deciding whether the query is wrong or the container
#  never received its arguments.
#
#  Note what this image is NOT: it is not built by docker-compose as a service.
#  Nothing starts it and leaves it running. It is an artifact that Airflow
#  runs and that then exits — the boundary this whole repository is built
#  around. `make jobs` builds it.
# ============================================================================
FROM python:3.12-slim

WORKDIR /app
COPY run.py /app/run.py

# Unbuffered, or the output arrives after the container has already exited and
# Airflow captures nothing.
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/run.py"]
