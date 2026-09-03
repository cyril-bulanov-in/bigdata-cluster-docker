# bigdata-cluster-docker

[![01-kafka](https://github.com/cyril-bulanov-in/bigdata-cluster-docker/actions/workflows/01-kafka.yml/badge.svg?branch=main)](https://github.com/cyril-bulanov-in/bigdata-cluster-docker/actions/workflows/01-kafka.yml)
[![02-monitoring](https://github.com/cyril-bulanov-in/bigdata-cluster-docker/actions/workflows/02-monitoring.yml/badge.svg?branch=main)](https://github.com/cyril-bulanov-in/bigdata-cluster-docker/actions/workflows/02-monitoring.yml)
[![03-dbms](https://github.com/cyril-bulanov-in/bigdata-cluster-docker/actions/workflows/03-dbms.yml/badge.svg?branch=main)](https://github.com/cyril-bulanov-in/bigdata-cluster-docker/actions/workflows/03-dbms.yml)

A working data platform, assembled with Docker Compose one component at a time.

Most "data engineering portfolio" repositories are a single `docker-compose.yml`
that starts nine services at once and prints a word count. This one is built the
way a platform is actually built: incrementally, with each layer running,
monitored and understood before the next one is added.

Every numbered directory is a self-contained stack with its own compose file,
README and `make up`. They all attach to one shared Docker network, so the
pieces combine into a single platform instead of a pile of unrelated demos.

---

## The idea

Two things shape every decision in this repository.

### Infrastructure and jobs are different things

In a real organisation nobody runs stateful Kafka in Compose and hopes the
volumes survive. Kafka is MSK or Confluent Cloud, storage is S3 plus a
warehouse, orchestration metadata lives in RDS. That side is owned by a platform
team.

What a data engineer actually ships in a container is **code**: a Spark
application, a dbt project, a Python transformation. The container is a unit of
delivery, not a way to host a service. Airflow starts it, it does its work,
it exits.

This repository reproduces that boundary rather than blurring it. The numbered
stacks are the platform: long-lived, stateful, started once and left running.
Job images are versioned artifacts that know nothing about how the platform was
brought up, only the addresses and credentials they were handed. That split is
the point of the whole exercise.

### Everything must be portable

Nothing here is allowed to depend on running on a laptop. Object storage speaks
the S3 protocol, so the same `s3a://` path works locally and in AWS with one
environment variable changed. Job code receives every endpoint through the
environment. Nothing is hardcoded that would have to be rewritten to run
somewhere else.

| Component | Local (this repo) | Self-hosted cluster | AWS |
|---|---|---|---|
| Broker | Kafka in Compose | Kafka on a Pi cluster | MSK |
| Change capture | Debezium in Kafka Connect | same | MSK Connect or DMS |
| Object storage | MinIO | MinIO on local disks | S3 |
| Processing | Spark standalone | Spark standalone | EMR Serverless |
| Orchestration | Airflow + DockerOperator | same | MWAA + ECS tasks |
| Warehouse | ClickHouse cluster | ClickHouse on the Pi cluster | ClickHouse Cloud |

The job code is identical in all three columns. Only the operator in the DAG
and a handful of environment variables change.

---

## Target architecture

```mermaid
flowchart LR
    subgraph SRC[Sources]
        API[APIs and generators]
        OLTP[(Operational DB)]
    end

    subgraph PLATFORM[Platform - long-lived]
        K[Kafka cluster]
        S3[(MinIO / S3)]
        CH[(ClickHouse)]
        AF[Airflow]
        SP[Spark cluster]
        BI[Superset]
        MON[Prometheus + Grafana]
    end

    subgraph JOBS[Jobs - ephemeral containers]
        SJ[Spark applications]
        DBT[dbt models]
        PY[Python transforms]
    end

    API --> K
    OLTP -- CDC --> K
    K --> SJ
    K --> CH
    SJ --> S3
    S3 --> PY
    PY --> CH
    DBT --> CH
    CH --> BI
    AF -.starts.-> SJ
    AF -.starts.-> DBT
    AF -.starts.-> PY
    MON -.scrapes.-> PLATFORM
```

Solid arrows are data. Dotted arrows are control: the orchestrator starts job
containers and the monitoring stack scrapes everything, but neither of them
touches the data itself.

---

## Roadmap

| Step | Stack | What gets built | State |
|---|---|---|---|
| 01 | [Kafka](01-kafka/) | 4-node KRaft cluster, 3-controller quorum, Kafbat UI, JMX metrics | done |
| 02 | [Monitoring](02-monitoring/) | Prometheus with Docker service discovery, Grafana, JMX / lag / host / container exporters, provisioned dashboard | done |
| 03 | [DBMS](03-dbms/) | Postgres, Debezium change capture, ClickHouse cluster of 4 shards x 2 replicas with Keeper, deduplicating staging layer | done |
| 04 | ETL | Airflow, DAGs that launch containers rather than run code in-process | next |
| 05 | Spark | standalone master and workers, resource limits, a job image | planned |
| 06 | dbt | staging and mart models on ClickHouse, tests, documentation | planned |
| 07 | MinIO | S3-compatible storage, bucket layout, lifecycle, presigned URLs | planned |
| 08 | Superset | dashboards on top of the marts | planned |

Steps are ordered so that each one can be verified on its own. Monitoring comes
second on purpose: from that point on, every stack added later arrives with
metrics rather than getting them bolted on at the end.

Candidates for what comes after step 08, not yet committed: an open table
format for the object storage layer, integration tests with Testcontainers, and
a Terraform deployment of the same architecture to AWS.

---

## What you can practise here

The point is not that the containers start. It is what you can break, measure
and reason about once they do.

**Distributed systems behaviour.** Kill a Kafka broker and watch partition
leadership move and the ISR shrink. Kill a ClickHouse replica and watch writes
keep succeeding on the survivor, then watch the returning node catch up. Work
out why a quorum of four controllers buys nothing over three, and why three
Keepers are right for eight ClickHouse nodes. Each stack README ends with a
failure drill of this kind.

**Failures that leave everything green.** An exporter whose endpoint answers
while exporting nothing usable. A Kafka consumer subscribed to a topic it will
never read. A `CREATE ... ON CLUSTER` that succeeds while every distributed
query fails, because the two use different transports. Change capture that
stops, leaving the warehouse serving stale data and reporting no problem at all.
These are the ones the smoke tests exist for.

**Correctness under change.** Deduplicating a stream of inserts, updates and
deletes so that readers see one current row. Why the version column must be a
log position and not a timestamp. Why the sharding key must be the source
primary key, and why partitioning by a mutable column silently breaks
deduplication forever.

**Operational habits.** Pinned image versions, health checks that mean
something, resource limits, credentials outside version control, one-command
teardown and rebuild from scratch.

**Cloud migration mechanics.** Every design note states what the component maps
to in AWS and what would change.

---

## Getting started

Each stack runs independently, and the later ones pull in what they need
through Compose `include`. Starting step 3 starts all three.

```bash
cd 03-dbms
cp .env.example .env
cp ../02-monitoring/.env.example ../02-monitoring/.env
cp ../01-kafka/.env.example ../01-kafka/.env
make up
make connector
make test
```

To start only the broker and its monitoring, do the same from `02-monitoring`.
To run step 3 without the ClickHouse cluster on a smaller machine, use
`make up-light`.

Memory is the binding constraint. The full platform wants roughly 24 GiB
available to Docker; 48 is comfortable. Each stack README states its own needs.

---

## Layout

```
bigdata-cluster-docker/
├── README.md              you are here
├── .gitignore             repository-wide
├── .github/workflows/     one CI workflow per stack
└── NN-name/               one directory per stack
    ├── README.md          what it is, how to run it, what to look at
    ├── docker-compose.yml the stack itself, commented line by line
    ├── .env.example       configuration template, copy to .env
    ├── Makefile           up / down / logs / test / stack-specific helpers
    └── scripts/smoke.sh   assertions about the running stack
```

---

## Conventions

These hold everywhere, so adding a stack never means learning new rules.

**One shared network.** The first stack you start creates a bridge network
called `dataplatform`; later stacks join it, either by `include` or as an
external network. Containers reach each other by service name, never by IP
address.

**Nothing runs as `latest`.** Every image tag is pinned in `.env.example`, and
pinned from the registry rather than from the project's source releases — the
two are not always in step. Where a project publishes no maintained image, the
Dockerfile takes the artifact from its GitHub release and verifies it.

**Configuration through `.env`.** Secrets and machine-specific values stay out
of the repository. Each stack ships a documented `.env.example`, and `make up`
refuses to start if the real file is missing.

**Comments explain the why.** Compose files are written for someone who knows
what a container is but has not memorised Kafka listener semantics or
ClickHouse deduplication rules. Where a setting exists to avoid a specific
failure, the comment says which one — often with the exact error message it
produces.

**A `Makefile` per stack.** Standard targets everywhere: `up`, `down`, `clean`,
`ps`, `logs`, `config`, `smoke`, `test`. Run `make` on its own for the full
list, including helpers specific to that stack.

**Every stack is verified.** `make config` validates the compose file and every
configuration it depends on; `make smoke` asserts properties of the running
stack that a successful start does not prove. GitHub Actions runs both on every
change, on a clean runner, from an empty state.

Where CI cannot cover something, the stack README says so explicitly and gives
the commands that do. Step 3 is the current example: eight ClickHouse nodes do
not fit on a GitHub runner, so its workflow starts everything else and the
skipped assertions print as `SKIP` rather than quietly disappearing.

---

## Requirements

Docker Engine 24 or newer with Compose v2. Memory is the binding constraint:
Kafka alone wants roughly 8 GB available to Docker, and the full platform with
the ClickHouse cluster wants 24 or more. On Docker Desktop this is under
Settings → Resources.

Images are multi-architecture, so the stacks run on both x86-64 and arm64
(Apple Silicon, Raspberry Pi 5).
