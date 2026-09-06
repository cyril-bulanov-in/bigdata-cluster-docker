"""Proves that Airflow can run a job container, and that a failure is seen.

This DAG does no useful work. It exists because five separate things have to
be right before any real job can run, and each of them fails differently:

    the scheduler can reach the Docker socket
    the job image exists locally
    the container joins the platform network
    parameters reach the job
    a non-zero exit becomes a failed task

Debugging those alongside real logic means never being sure which half is
broken. Here they are alone.

Trigger it by hand from the UI, or:

    make dag-run
"""
from __future__ import annotations

import pendulum
from airflow import DAG
from airflow.providers.docker.operators.docker import DockerOperator

# ---------------------------------------------------------------------------
#  Settings every job task in this repository shares
# ---------------------------------------------------------------------------
#  Kept in one place because getting any of them wrong produces a failure that
#  points somewhere else entirely.
# ---------------------------------------------------------------------------
DOCKER_DEFAULTS = dict(
    # The scheduler talks to the daemon through the mounted socket. It has
    # read-write access to it via group 0 — see the compose file.
    docker_url="unix://var/run/docker.sock",

    # THE important one. Without it the container lands on the default bridge,
    # where `postgres` and `clickhouse-01` do not resolve. The job then fails
    # on a connection timeout that looks like a database problem and is not.
    network_mode="dataplatform",

    # Remove the container once it has succeeded. Failed ones are kept
    # deliberately: `docker logs` on a corpse is often faster than digging
    # through the Airflow UI, and a job that failed is exactly when you want
    # to look inside it.
    auto_remove="success",

    # Airflow otherwise mounts a temporary directory from its own filesystem
    # into the job container. That path exists inside the scheduler container
    # and not on the host the daemon runs on, so the mount fails with a
    # message about a missing directory nobody asked for.
    mount_tmp_dir=False,

    # Never pull: these images are built locally and have no registry to come
    # from. The default would try, fail to find them, and report a missing
    # image rather than the real cause.
    docker_conn_id=None,
    api_version="auto",
)

with DAG(
    dag_id="00_docker_smoke",
    description="Runs a stub job container to prove the mechanics work",
    # Manual only. This DAG proves plumbing; there is nothing to do on a
    # schedule.
    schedule=None,
    start_date=pendulum.datetime(2026, 1, 1, tz="UTC"),
    catchup=False,
    tags=["04-etl", "smoke"],
    default_args={"retries": 0},
) as dag:

    # ---- the one that should succeed --------------------------------------
    hello = DockerOperator(
        task_id="hello",
        image="dataplatform/job-hello:0.1.0",
        environment={
            # Templated at run time. Passing the run identity into the job
            # means its own output can be tied back to the run that produced
            # it, which matters as soon as two runs overlap.
            "RUN_ID": "{{ run_id }}",
                        # Airflow 3 leaves logical_date undefined for a manual run: the
            # run is not tied to a schedule interval, so there is no logical
            # date to speak of. Referencing it directly raises UndefinedError
            # and the task dies before its operator runs.
            #
            # run_after is always set — it is when the run became eligible to
            # start — and it is what a job should key off anyway.
            "LOGICAL_DATE": "{{ dag_run.run_after }}",
            "MESSAGE": "the plumbing works",
            "SHOULD_FAIL": "0",
        },
        **DOCKER_DEFAULTS,
    )

    # ---- the one that should fail -----------------------------------------
    #  Deliberately red. A pipeline where nothing has ever failed is a
    #  pipeline where nobody knows what failure looks like — in the UI, in the
    #  logs, or in the metrics the statsd exporter publishes.
    #
    #  One retry, so the retry behaviour is visible too: the task goes
    #  up_for_retry before it goes failed.
    should_fail = DockerOperator(
        task_id="fails_on_purpose",
        image="dataplatform/job-hello:0.1.0",
        environment={
            "RUN_ID": "{{ run_id }}",
                        # Airflow 3 leaves logical_date undefined for a manual run: the
            # run is not tied to a schedule interval, so there is no logical
            # date to speak of. Referencing it directly raises UndefinedError
            # and the task dies before its operator runs.
            #
            # run_after is always set — it is when the run became eligible to
            # start — and it is what a job should key off anyway.
            "LOGICAL_DATE": "{{ dag_run.run_after }}",
            "MESSAGE": "this one exits 3",
            "SHOULD_FAIL": "1",
        },
        retries=1,
        retry_delay=pendulum.duration(seconds=15),
        **DOCKER_DEFAULTS,
    )

    hello >> should_fail
