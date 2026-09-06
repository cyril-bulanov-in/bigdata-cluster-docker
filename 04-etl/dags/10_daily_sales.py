"""Recompute the sales-by-category mart, one day per run.

The DAG holds no logic. It decides *when* and *with what parameters*; the
work happens inside a container that knows nothing about Airflow. Swap
DockerOperator for EcsRunTaskOperator and the same image runs in AWS with the
image tag and the endpoints unchanged.

That split is the point of this stack, and it is worth stating plainly: if
the SQL were in this file, moving to a managed Airflow would mean moving the
transformation logic too, and the job would stop being a versioned artifact.
"""
from __future__ import annotations

import pendulum
from airflow import DAG
from airflow.providers.docker.operators.docker import DockerOperator

DOCKER_DEFAULTS = dict(
    docker_url="unix://var/run/docker.sock",
    # Without this the container lands on the default bridge and cannot
    # resolve clickhouse-01 — which surfaces as a connection timeout that
    # looks like a warehouse problem.
    network_mode="dataplatform",
    auto_remove="success",
    # Airflow would otherwise mount a temp directory that exists inside the
    # scheduler container and not on the host the daemon runs on.
    mount_tmp_dir=False,
    api_version="auto",
)

with DAG(
    dag_id="10_daily_sales",
    description="Daily sales by category, computed from the CDC staging tables",
    # Every day at 01:00 UTC, for the day that just ended.
    schedule="0 1 * * *",
    start_date=pendulum.datetime(2026, 9, 1, tz="UTC"),
    # No backfill on unpause. Turning a DAG on should not silently launch
    # weeks of runs; a backfill is a decision, made with `airflow backfill`.
    catchup=False,
    # One run at a time. The job is idempotent, but two runs computing the
    # same day concurrently would race on the same mart rows for no benefit.
    max_active_runs=1,
    tags=["04-etl", "mart", "clickhouse"],
    default_args={
        "retries": 2,
        "retry_delay": pendulum.duration(minutes=2),
    },
) as dag:

    daily_sales = DockerOperator(
        task_id="daily_sales_by_category",
        image="dataplatform/job-daily-sales:{{ var.value.get('job_version', '0.1.0') }}",
        environment={
            "CLICKHOUSE_URL": "http://clickhouse-01:8123",
            "CLICKHOUSE_DB": "analytics",
            # A scheduled run has an interval and computes the day it covers.
            # A manual run has none — Airflow 3 leaves both logical_date and
            # data_interval_end undefined, and referencing either kills the
            # task during template rendering, before the operator runs.
            #
            # run_after is set for every kind of run: it is when the run
            # became eligible to start. So a manual trigger computes the day
            # it was triggered on, which is the sensible thing for a manual
            # trigger to do.
            "TARGET_DATE": "{{ (dag_run.data_interval_end or dag_run.run_after) | ds }}",
            "RUN_ID": "{{ run_id }}",
            "DRY_RUN": "0",
        },
        **DOCKER_DEFAULTS,
    )
