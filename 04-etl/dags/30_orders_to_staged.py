"""Export a day of orders to object storage, then shape it into the staged layer.

Two tasks, two different runtimes, one DAG that knows about neither:

    export_orders_to_s3       a plain Python container, reads ClickHouse,
                              writes Parquet to s3://raw/
    orders_raw_to_staged      a Spark application, submitted to the standalone
                              cluster, reads s3://raw/ and writes s3://staged/

The second is the point of this file. Nothing in the DAG says "Spark": it
names an image and passes environment variables, exactly as it does for the
Python job above it. The image happens to run spark-submit internally.

That is what makes the move to EMR Serverless a change of operator rather
than a rewrite — and it is why the submit logic lives in the job image's
entrypoint rather than here.

    make dag-run DAG=30_orders_to_staged
"""
from __future__ import annotations

import pendulum
from airflow import DAG
from airflow.providers.docker.operators.docker import DockerOperator

DOCKER_DEFAULTS = dict(
    docker_url="unix://var/run/docker.sock",
    # Without this the container joins the default bridge, where neither
    # clickhouse-01 nor minio nor spark-master resolves.
    network_mode="dataplatform",
    auto_remove="success",
    # Airflow would otherwise mount a temp directory that exists inside the
    # scheduler container and not on the host running the daemon.
    mount_tmp_dir=False,
    api_version="auto",
)

# run_after, not logical_date and not data_interval_end. Airflow 3 leaves both
# of those undefined for a manual run, and Jinja's StrictUndefined raises on
# the name before any `or` can help.
TARGET_DATE = "{{ dag_run.run_after | ds }}"

S3 = {
    "S3_ENDPOINT": "http://minio:9000",
    "AWS_ACCESS_KEY_ID": "minioadmin",
    "AWS_SECRET_ACCESS_KEY": "minioadmin",
}

with DAG(
    dag_id="30_orders_to_staged",
    description="ClickHouse -> raw Parquet -> staged, the second step on Spark",
    schedule="0 2 * * *",
    start_date=pendulum.datetime(2026, 9, 1, tz="UTC"),
    catchup=False,
    max_active_runs=1,
    tags=["04-etl", "06-spark", "s3", "parquet"],
    default_args={"retries": 2, "retry_delay": pendulum.duration(minutes=2)},
) as dag:

    export = DockerOperator(
        task_id="export_orders_to_s3",
        image="dataplatform/job-export-orders:0.1.0",
        environment={
            "CLICKHOUSE_URL": "http://clickhouse-01:8123",
            "CLICKHOUSE_DB": "analytics",
            "S3_ACCESS_KEY": "minioadmin",
            "S3_SECRET_KEY": "minioadmin",
            "S3_BUCKET": "raw",
            "TARGET_DATE": TARGET_DATE,
            "DRY_RUN": "0",
            **{k: v for k, v in S3.items() if k == "S3_ENDPOINT"},
        },
        **DOCKER_DEFAULTS,
    )

    # ---- the Spark task -----------------------------------------------------
    #  Note what is NOT here: no --master, no --conf, no mention of executors.
    #  All of that is in the image's entrypoint, because it is a property of
    #  the job rather than of the schedule.
    #
    #  The container name matters and is not cosmetic. The job runs in client
    #  mode: the driver lives in this container and the executors on the
    #  workers connect back to it. They need a name that resolves, and Docker
    #  only publishes one for a container that was given one.
    #
    #  DockerOperator has no --name flag; container_name is the equivalent, and
    #  SPARK_DRIVER_HOST has to agree with it. Without both, the job starts,
    #  acquires executors and hangs — the driver waiting for executors that
    #  cannot reach it, with nothing in the log to say so.
    #
    #  A fixed name also means two runs cannot overlap, which max_active_runs=1
    #  already guarantees. If that ever changes, this has to become unique per
    #  run as well.
    staged = DockerOperator(
        task_id="orders_raw_to_staged",
        image="dataplatform/spark-job-orders-staged:0.1.0",
        container_name="spark-driver-airflow",
        environment={
            "SPARK_MASTER_URL": "spark://spark-master:7077",
            "SPARK_DRIVER_HOST": "spark-driver-airflow",
            "SPARK_DRIVER_MEMORY": "2g",
            "SPARK_EXECUTOR_MEMORY": "6g",
            "SPARK_EXECUTOR_CORES": "2",
            "SPARK_CORES_MAX": "8",
            "SRC_BUCKET": "raw",
            "DST_BUCKET": "staged",
            "ENTITY": "orders",
            "TARGET_DATE": TARGET_DATE,
            "DRY_RUN": "0",
            **S3,
        },
        **DOCKER_DEFAULTS,
    )

    export >> staged
