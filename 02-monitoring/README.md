# 02-monitoring — Prometheus, Grafana and exporters

Metrics for everything the platform runs: the Kafka cluster's own internals,
consumer lag, the host machine, and every container separately. Prometheus
collects and evaluates alerting rules, Grafana draws, four kinds of exporter
translate.

Step 2 of [bigdata-cluster-docker](../README.md). It **includes** step 1, so
`make up` here starts Kafka as well — you do not need to start `01-kafka`
separately.

## Quick start

```bash
cp .env.example .env
cp ../01-kafka/.env.example ../01-kafka/.env   # if you have not already
make up
```

The first start builds two images and pulls five, so give it a few minutes.

| | |
|---|---|
| Grafana | http://localhost:3000 (login in `.env`) |
| Dashboard | http://localhost:3000/d/platform-overview |
| Prometheus | http://localhost:9090 |
| Alerts | http://localhost:9090/alerts |
| cAdvisor | http://localhost:8082 |
| Kafbat UI | http://localhost:8080 |

The **Platform overview** dashboard is already there, connected and populated.
Nothing to import.

Then check that it is really collecting, rather than merely running:

```bash
make test
```

## What is inside

| Container | What it produces | Port |
|---|---|---|
| `prometheus` | collects, stores, evaluates alerting rules | 9090 |
| `grafana` | dashboards, provisioned from files | 3000 |
| `jmx-kafka-1..4` | Kafka internals over JMX, one per broker | 5556 |
| `kafka-lag-exporter` | consumer lag, topic and partition counts | 9308 |
| `node-exporter` | host CPU, memory, disks, network | 9100 |
| `cadvisor` | per-container CPU, memory, limits, throttling | 8080 |

Only Prometheus, Grafana and cAdvisor publish a port to the host. The exporters
are reachable inside the `dataplatform` network and nowhere else, which is how
it should be — none of them has authentication.

## Why these exporters

**JMX exporters** cover Kafka's own view of itself: replication state,
throughput, controller elections, JVM heap. Kafka publishes these over JMX,
which Prometheus cannot read, so one exporter per broker sits in between. One
per broker because a JMX connection targets a single JVM.

**kafka-lag-exporter** speaks the Kafka protocol instead and answers the one
question JMX cannot: how far behind each consumer group is. A broker can be
perfectly healthy while a consumer falls hours behind.

**node-exporter** answers "how loaded is the machine". **cAdvisor** answers
"which container is doing it", which is usually the question you actually have.
cAdvisor also exposes each container's memory *limit* and CPU throttling, and
those two earn its place: without them an OOM kill looks like a random restart,
and a container capped at half a core looks merely slow rather than
deliberately paused by the kernel.

## Alerting

Twelve rules in `prometheus/rules/alerts.yml`, in four groups: targets, Kafka,
host, containers.

`TargetDown` is the most valuable one. It catches failures nobody anticipated,
because it does not care what broke — only that something stopped answering.

Every rule has a `for:` clause. That is the part people skip, and it is what
separates an alert from a noise generator: the condition has to hold for that
long before the alert fires, so a two-second blip during a rebalance stays
quiet. A controller election takes seconds, hence two minutes on the controller
rule; a busy minute during compaction is normal, hence ten on host CPU.

There is no Alertmanager. Rules are evaluated and firing alerts show up in
`make alerts` and in the Prometheus UI, but there is nowhere to send them.
That is a deliberate gap: routing to email or Slack is its own container and
its own concern.

## Commands

```
make help        list every command
make up          start Kafka, the exporters, Prometheus and Grafana
make down        stop, keep the data
make clean       stop and wipe all volumes, Kafka data included
make config      validate compose, prometheus.yml, the rules, the dashboard
make smoke       assert the running stack is really collecting
make test        config, then smoke
make targets     which scrape targets are up
make rules       every alerting rule and its state
make alerts      what is pending or firing right now
make kafka-metrics / host-metrics / container-metrics / lag
make datasource  did Grafana pick up the connection
make dashboards  which dashboards Grafana loaded
make reload      re-read prometheus.yml and rules, no restart
make drill-down  run the failure drill below
make drill-up    undo it
```

## Failure drill

Monitoring that has never seen a failure is decoration. This takes two minutes
and exercises the whole chain: broker, exporter, scrape, rule, dashboard.

```bash
make drill-down          # stops kafka-2
```

Then watch it land, in this order:

1. **~30 seconds** — `make targets` shows `jmx-kafka-2` down. The exporter is
   alive; it is the JMX connection behind it that failed.
2. **~1 minute** — `make alerts` shows `TargetDown` firing.
3. **~2 minutes** — `KafkaUnderReplicatedPartitions` joins it. Partitions that
   had a replica on `kafka-2` are now short one.
4. **Grafana** — "Brokers up" drops to 3, "Under-replicated partitions" turns
   red, one series disappears from the throughput graph.
5. **`KafkaControllerCountWrong` stays quiet.** `kafka-2` is one of the three
   controllers, so the quorum re-elected around it within seconds and the count
   is still exactly 1. That is the interesting result: a controller died and
   the cluster did not notice.

```bash
make drill-up            # starts kafka-2 again
```

Alerts clear once the replicas catch up, another minute or two.

For contrast, run the same drill against `kafka-4`. It is a broker only, so the
quorum is not involved at all and only the replication metrics move.

## Configuration notes

**`include`, not a copy.** This stack pulls in `../01-kafka/docker-compose.yml`
rather than redefining Kafka. Both files declare `name: platform`, so it is the
same Compose project: if Kafka is already running from `01-kafka`, `make up`
here leaves it alone and adds only the monitoring containers. The consequence
to know: `make clean` here removes the Kafka volumes too.

**The network is not redeclared.** `dataplatform` is defined in `01-kafka` and
arrives through `include`. Declaring it again — even identically — makes
Compose report a resource name conflict, because `include` copies definitions
rather than merging them.

**Two images are built, not pulled.** Neither the JMX exporter nor cAdvisor has
a maintained official container: the JMX exporter has never had one, and
cAdvisor's registry stopped receiving new tags. Both projects publish the
artifact itself on every GitHub release, so both Dockerfiles take that and put
it on a minimal base. The jar is verified against its published sha256;
cAdvisor publishes no checksum, so the build runs the binary instead.

**cAdvisor needs the containerd socket, not just the Docker one.** Docker has
run containers through containerd for years, and modern cAdvisor asks
containerd for them. Without `/run/containerd/containerd.sock` its docker
factory fails to register, and the symptom is not an error: the endpoint
answers, the target is green, hundreds of `container_*` metrics are exported —
and every one of them is the root cgroup. Any query filtering on `name!=""`
comes back empty.

**The Grafana admin password applies only once.** `GRAFANA_ADMIN_PASSWORD` is
used when the account is created, on the first start with an empty
`grafana-data` volume. Editing `.env` afterwards changes nothing, because the
password then lives in Grafana's own database. To change it:

```bash
docker compose exec grafana grafana cli admin reset-admin-password '<new>'
```

**Provisioning over clicking.** The datasource and the dashboard are files
under `grafana/provisioning`, loaded on startup. A dashboard that exists only
in someone's browser is not part of the project and does not survive
`make clean`. If you improve one in the UI, export its JSON model and paste it
back into the file.

**`make reload` instead of a restart.** Prometheus runs with
`--web.enable-lifecycle`, so a config or rules change is one POST away. A
restart works too but throws away the in-memory block of recent data.
