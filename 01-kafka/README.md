# Local data platform — step 1: Kafka cluster

A four-node Apache Kafka cluster running in KRaft mode (no ZooKeeper), with
the Kafbat UI web interface collecting metrics over JMX.

This is the first step of the platform. Object storage, an analytical database
and an orchestrator will be added later, each as its own step, joining the same
docker network.

## Quick start

```bash
cp .env.example .env
make up
```

The first start pulls images and formats the KRaft metadata store, so give it a
minute or two. The interface is then at **http://localhost:8080**

Check that the cluster came together:

```bash
make describe
```

You should see six partitions of the `demo.events` topic, three replicas each,
all three in the ISR. If the ISR is shorter than the replica list, some node
did not come up — check `make logs`.

## What is inside

| Container | Role | Host port |
|---|---|---|
| `kafka-1` | broker + controller, node id 1 | 29091 |
| `kafka-2` | broker + controller, node id 2 | 29092 |
| `kafka-3` | broker + controller, node id 3 | 29093 |
| `kafka-4` | broker only, node id 4 | 29094 |
| `kafka-ui` | Kafbat UI, JMX metrics | 8080 |
| `kafka-init` | creates `demo.events` once, then exits | — |

## How to connect

From inside the `dataplatform` docker network, by container name:

```
kafka-1:9092,kafka-2:9092,kafka-3:9092,kafka-4:9092
```

From the host, through the published ports:

```
localhost:29091,localhost:29092,localhost:29093,localhost:29094
```

These are two different listeners on the same brokers. The comments inside
`docker-compose-platform.yml` explain why one address cannot serve both cases.

## Commands

```
make help      list every command
make up        start the cluster
make down      stop it, keep the data
make clean     stop it and wipe the broker volumes
make ps        container status
make logs      follow the logs
make health    cluster membership as Kafka sees it
make topics    list topics
make describe  partitions, leaders, replicas and ISR for demo.events
make produce   write to demo.events from the console
make consume   read demo.events from the beginning
```

## Try a failure

The point of four nodes is that the cluster survives losing one. It takes a
minute to see for yourself:

```bash
make describe            # note which node leads which partition
docker stop kafka-2      # drop a node
make describe            # leaders moved, ISR is down to 2
docker start kafka-2     # bring it back
make describe            # the replica caught up, ISR is 3 again
```

Writes keep working throughout: `min.insync.replicas=2`, and two live replicas
remain. Because `kafka-2` is also a controller, this exercises a controller
election at the same time — the remaining two controllers still form a majority.

To watch a pure data-node failure instead, stop `kafka-4`: the quorum is not
touched at all, only replica placement.

## Configuration notes

**Topology.** Nodes 1-3 run in combined mode, acting as both brokers and
controllers; node 4 is a plain broker. KRaft controllers decide by majority
vote, so a quorum of three survives the loss of one controller. A fourth
controller would not improve on that — the majority would simply rise from two
to three — which is why controller quorums are kept odd. The fourth node
therefore carries data only. Data durability is a separate matter, handled by
partition replication (`replication.factor=3`), not by the quorum.

**`CLUSTER_ID`.** Set in `.env` and burned into the metadata store on first
start. It cannot be changed on a running cluster — nodes reject a foreign id.
If you change it, run `make clean` first.

**Pinned versions.** Image tags live in `.env.example`. A `latest` tag will
eventually pull an incompatible version and break the cluster without a single
change on your side.

## Requirements

Docker Desktop (or any Docker Engine) with at least 8 GB of memory available:
four brokers at 2 GB each plus the UI. In Docker Desktop this is under
Settings → Resources.
