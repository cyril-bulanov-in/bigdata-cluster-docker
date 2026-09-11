"""Export one day of orders to object storage, then build the mart.

Two tasks, in order, and the order is the point: the export writes the day to
S3, the mart is computed afterwards. In the target architecture these become
two very different things — an EMR Serverless job and a dbt run — but the DAG
would not change, because it never knew what either of them does.

    make dag-run DAG=20_export_orders
"""
from __future__ import annotations

import pendulum
from airflow import DAG
from airflow.providers.docker.operators.docker import DockerOperator

DOCKER_DEFAULTS = dict(
    docker_url="unix://var/run/docker.sock",
    # Without this the container joins the default bridge, where neither
    # clickhouse-01 nor minio resolves, and fails on a timeout that looks like
    # a storage problem.
    network_mode="dataplatform",
    auto_remove="success",
    # Airflow would otherwise mount a temp directory that exists inside the
    # scheduler container and not on the host running the daemon.
    mount_tmp_dir=False,
    api_version="auto",
)

# run_after, not logical_date and not data_interval_end. Airflow 3 leaves both
# of those undefined for a manual run, and Jinja's StrictUndefined raises on
# the name before any `or` can help. run_after exists for every kind of run.
TARGET_DATE = "{{ dag_run.run_after | ds }}"

with DAG(
    dag_id="20_export_orders",
    description="Export a day of orders to S3 as Parquet, then rebuild the mart",
    schedule="30 1 * * *",
    start_date=pendulum.datetime(2026, 9, 1, tz="UTC"),
    catchup=False,
    max_active_runs=1,
    tags=["04-etl", "s3", "parquet"],
    default_args={"retries": 2, "retry_delay": pendulum.duration(minutes=2)},
) as dag:

    export = DockerOperator(
        task_id="export_orders_to_s3",
        image="dataplatform/job-export-orders:0.1.0",
        environment={
            "CLICKHOUSE_URL": "http://clickhouse-01:8123",
            "CLICKHOUSE_DB": "analytics",
            # The endpoint and the keys are the only things that change when
            # this runs against AWS instead. Nothing else in the image knows
            # which S3 it is talking to.
            "S3_ENDPOINT": "http://minio:9000",
            "S3_ACCESS_KEY": "minioadmin",
            "S3_SECRET_KEY": "minioadmin",
            "S3_BUCKET": "raw",
            "TARGET_DATE": TARGET_DATE,
            "DRY_RUN": "0",
        },
        **DOCKER_DEFAULTS,
    )

    mart = DockerOperator(
        task_id="daily_sales_by_category",
        image="dataplatform/job-daily-sales:0.1.0",
        environment={
            "CLICKHOUSE_URL": "http://clickhouse-01:8123",
            "CLICKHOUSE_DB": "analytics",
            "TARGET_DATE": TARGET_DATE,
            "DRY_RUN": "0",
        },
        **DOCKER_DEFAULTS,
    )

    export >> mart
