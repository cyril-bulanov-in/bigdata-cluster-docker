# ============================================================================
#  Daily sales by category — a real job
# ============================================================================
#  Reads the staging tables produced by change capture and writes one row per
#  day and category into a mart.
#
#  Everything it needs to know arrives as an environment variable: which
#  ClickHouse to talk to, which day to compute. Nothing is hardcoded that
#  would have to change to run this against ClickHouse Cloud instead — which
#  is the entire point of shipping jobs as images rather than as Airflow code.
# ============================================================================
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# The SQL is baked in, not mounted. A job image is a versioned artifact: the
# query it runs is part of what that version means. Mounting the SQL from
# outside would make two runs of the same image tag do different things.
COPY sql/ /app/sql/
COPY run.py /app/run.py

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/run.py"]
