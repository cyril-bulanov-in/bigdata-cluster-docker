# ============================================================================
#  Export one day of orders from ClickHouse to object storage as Parquet
# ============================================================================
#  The first job in this repository that writes to S3. Everything it needs —
#  the endpoint, the credentials, the bucket, the day — arrives as an
#  environment variable, so pointing it at AWS means changing the endpoint and
#  the keys and nothing else.
# ============================================================================
FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY run.py /app/run.py

ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["python", "/app/run.py"]
