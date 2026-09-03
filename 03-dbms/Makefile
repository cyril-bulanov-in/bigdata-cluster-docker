# Short entry points for the databases stack.
#
# This stack includes 02-monitoring, which includes 01-kafka, so `make up`
# here starts the whole platform. Run every command from this directory:
# from a lower one, Compose reports this stack's containers as orphans.
#
#   make               - list the available commands
#   make up            - start everything and wire the whole pipeline
#   make connector     - register the Debezium connector (idempotent)
#   make test          - assert the whole chain actually works
#   make ch-e2e        - one row from Postgres to ClickHouse and back out
#   make clean         - stop everything and wipe every volume in the project

# ----------------------------------------------------------------------------
#  The clickhouse profile
# ----------------------------------------------------------------------------
#  The eight ClickHouse nodes and three Keepers carry profiles: [clickhouse] in
#  the compose file, so they start only when the profile is enabled. It is on
#  by default here, which makes `make up` behave as if profiles did not exist.
#
#  `make up-light` overrides PROFILES to nothing and starts everything else.
#  That is what continuous integration runs: eight nodes at 2 GiB do not fit on
#  a GitHub runner, so CI covers the source, the capture and the broker and
#  says plainly that it did not cover the warehouse.
#
#  The override has to reach `down`, `ps` and `clean` too — a profiled
#  container that was never started is also not stopped or removed by a
#  command that does not know about its profile.
# ----------------------------------------------------------------------------
PROFILES ?= --profile clickhouse

COMPOSE := docker compose $(PROFILES)

ENV       := .env
MON_ENV   := ../02-monitoring/.env
KAFKA_ENV := ../01-kafka/.env

# The eight ClickHouse nodes, as suffixes. Loops below iterate over this, so
# growing the cluster again means changing one line here.
CH_NODES := 01 02 03 04 05 06 07 08

# The Kafka consumer groups ClickHouse creates, one per source table.
CH_GROUPS := clickhouse-orders clickhouse-order-items clickhouse-customers clickhouse-products

# $(call getenv,VARNAME,FILE) — Compose reads .env, make does not.
getenv = $(shell grep -E '^$(1)=' $(2) 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

PG_DB        := $(or $(call getenv,POSTGRES_DB,$(ENV)),shop)
PG_USER      := $(or $(call getenv,POSTGRES_USER,$(ENV)),app)
PG_PORT      := $(or $(call getenv,POSTGRES_PORT,$(ENV)),5432)
CH_DB        := $(or $(call getenv,CH_DB,$(ENV)),analytics)
CH_HTTP      := $(or $(call getenv,CH_HTTP_PORT_01,$(ENV)),8123)
CONNECT_PORT := $(or $(call getenv,CONNECT_PORT,$(ENV)),8083)
PROM_PORT    := $(or $(call getenv,PROMETHEUS_PORT,$(MON_ENV)),9090)
GRAF_PORT    := $(or $(call getenv,GRAFANA_PORT,$(MON_ENV)),3000)

PROM      := http://localhost:$(PROM_PORT)
CONNECT   := http://localhost:$(CONNECT_PORT)
PSQL      := $(COMPOSE) exec -T postgres psql -U $(PG_USER) -d $(PG_DB) -v ON_ERROR_STOP=1
KBIN      := $(COMPOSE) exec -T kafka-1 /opt/kafka/bin
BOOTSTRAP := kafka-1:9092

# clickhouse-client on node 1, deliberately WITHOUT --database.
#
# Cluster questions live in system tables, which exist regardless of what
# databases have been created — and a client pinned to a database that does
# not exist yet fails with "Database analytics does not exist" before it can
# even tell you the cluster is fine.
CH := $(COMPOSE) exec -T clickhouse-01 clickhouse-client

define promq
curl -fsS --get --data-urlencode 'query=$(1)' "$(PROM)/api/v1/query" 2>/dev/null \
  | grep -o '"[0-9.e+-]*"]' | head -1 | tr -d '"]' | grep . || echo "no data"
endef

.DEFAULT_GOAL := help
.PHONY: help check-env up up-core up-light down restart clean ps logs config smoke test \
        seed psql counts schema generator-logs pg-metrics pg-alerts discovery \
        connector connector-delete connector-restart cdc-status cdc-topics \
        cdc-tail cdc-deletes cdc-slot connect-logs connect-metrics cdc-alerts \
        ch ch-init ch-schema ch-ingest ch-ingest-reset ch-cluster ch-keeper \
        ch-macros ch-metrics ch-logs ch-tables ch-replicas ch-rows ch-shards \
        ch-queues ch-consumers ch-compare ch-e2e ch-insert-test ch-dedup-test \
        ch-cleanup-test ch-drill-down ch-drill-up urls

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

# --- guard ------------------------------------------------------------------

check-env:
	@test -f $(ENV) || { \
	  echo ""; echo "ERROR: .env is missing in $$(pwd)"; \
	  ls -a | grep -qx 'env' && echo "       There is a file called 'env' here — rename it:  mv env .env"; \
	  echo "       Otherwise create it:  cp .env.example .env"; echo ""; exit 1; }
	@test -f $(MON_ENV) || { \
	  echo ""; echo "ERROR: ../02-monitoring/.env is missing"; \
	  echo "       Create it:  cp ../02-monitoring/.env.example ../02-monitoring/.env"; echo ""; exit 1; }
	@test -f $(KAFKA_ENV) || { \
	  echo ""; echo "ERROR: ../01-kafka/.env is missing"; \
	  echo "       Create it:  cp ../01-kafka/.env.example ../01-kafka/.env"; echo ""; exit 1; }
	@test -x connect/register-connector.sh || { \
	  echo ""; echo "ERROR: connect/register-connector.sh is missing or not executable"; \
	  echo "       chmod +x connect/register-connector.sh"; echo ""; exit 1; }
	@test -x scripts/smoke.sh || { \
	  echo ""; echo "ERROR: scripts/smoke.sh is missing or not executable"; \
	  echo "       chmod +x scripts/smoke.sh"; echo ""; exit 1; }
	@for f in postgres/init/01-schema.sql \
	          clickhouse/keeper/keeper-1.xml clickhouse/keeper/keeper-2.xml \
	          clickhouse/keeper/keeper-3.xml clickhouse/server/config.d/10-cluster.xml \
	          clickhouse/server/config.d/20-prometheus.xml clickhouse/server/config.d/30-limits.xml \
	          clickhouse/server/users.d/99-default.xml \
	          clickhouse/sql/10-staging.sql clickhouse/sql/20-kafka-ingest.sql \
	          clickhouse/sql/21-drop-ingest.sql; do \
	  test -f $$f || { echo ""; echo "ERROR: $$f is missing"; \
	    echo "       Compose mounts several of these as files. If one does not"; \
	    echo "       exist, Docker creates a directory with that name and the"; \
	    echo "       node fails to parse its configuration."; echo ""; exit 1; }; \
	 done
	@for n in $(CH_NODES); do \
	  test -f clickhouse/server/macros/clickhouse-$$n.xml || { \
	    echo ""; echo "ERROR: clickhouse/server/macros/clickhouse-$$n.xml is missing"; \
	    echo "       Without it the node has no shard or replica and cannot"; \
	    echo "       create a ReplicatedMergeTree table."; echo ""; exit 1; }; \
	 done
	@[ "$(call getenv,JMX_EXPORTER_VERSION,$(ENV))" = "$(call getenv,JMX_EXPORTER_VERSION,$(MON_ENV))" ] || { \
	  echo ""; echo "ERROR: JMX_EXPORTER_VERSION differs between .env files"; \
	  echo "       here:          $(call getenv,JMX_EXPORTER_VERSION,$(ENV))"; \
	  echo "       02-monitoring: $(call getenv,JMX_EXPORTER_VERSION,$(MON_ENV))"; \
	  echo "       The image is built by 02-monitoring and reused here."; echo ""; exit 1; }

# --- lifecycle --------------------------------------------------------------

up-core: check-env ## start the containers and seed Postgres (no warehouse setup)
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory seed

up: up-core ## start everything and wire the whole pipeline
	@$(MAKE) --no-print-directory ch-schema
	@$(MAKE) --no-print-directory ch-ingest
	@$(MAKE) --no-print-directory urls
	@echo "  Change capture needs the connector registered:"
	@echo "      make connector"
	@echo ""
	@echo "  Then give it a minute and check the whole chain:"
	@echo "      make test"
	@echo ""

# Everything except the warehouse. The schema and ingestion steps are skipped
# because there is nothing to create them on.
up-light: ## start everything except ClickHouse and Keeper
	@$(MAKE) --no-print-directory PROFILES= up-core
	@echo ""
	@echo "  Started without the warehouse. Postgres, the generator, Debezium"
	@echo "  and Kafka are running; ClickHouse and Keeper are not."
	@echo ""
	@echo "      make connector"
	@echo "      SKIP_CLICKHOUSE=1 make smoke"
	@echo ""

down: ## stop the containers, keep the data
	$(COMPOSE) down

restart: ## restart the containers
	$(COMPOSE) restart

clean: ## stop everything and delete every volume in the project
	$(COMPOSE) down -v

urls: ## print the web interfaces
	@echo ""
	@echo "  Postgres    localhost:$(PG_PORT)  db=$(PG_DB) user=$(PG_USER)"
	@echo "  ClickHouse  http://localhost:$(CH_HTTP)/play   db=$(CH_DB)"
	@echo "  Connect API $(CONNECT)"
	@echo "  Kafbat UI   http://localhost:8080"
	@echo "  Grafana     http://localhost:$(GRAF_PORT)"
	@echo "  Prometheus  $(PROM)"
	@echo ""

# --- checks -----------------------------------------------------------------

config: check-env ## validate the compose file and the includes
	@$(COMPOSE) config -q && echo "compose file is valid, all variables resolved"

# SKIP_CLICKHOUSE=1 runs only the checks that do not need the warehouse, and
# prints the rest as SKIP rather than omitting them — a summary that says
# "14 passed" should not look like full coverage of a half-tested stack.
smoke: ## assert the whole chain actually works
	@SKIP_CLICKHOUSE=$${SKIP_CLICKHOUSE:-0} ./scripts/smoke.sh

test: config smoke ## validate the configuration, then the running stack

# --- ClickHouse: database, schema, ingestion --------------------------------

# The image's entrypoint honours CLICKHOUSE_DB only while initialising an
# EMPTY data directory. A node that started once and failed has already
# written into its volume, so the initialisation is skipped forever after and
# the symptom appears much later as "Database analytics does not exist".
ch-init: ## create the ClickHouse database on every node (idempotent)
	@printf 'waiting for clickhouse-01 '
	@for i in $$(seq 1 40); do \
	   if $(COMPOSE) exec -T clickhouse-01 clickhouse-client --query "SELECT 1" >/dev/null 2>&1; then \
	     echo "— ready"; break; \
	   fi; \
	   printf '.'; sleep 3; \
	 done
	@$(CH) --query "CREATE DATABASE IF NOT EXISTS $(CH_DB) ON CLUSTER platform" >/dev/null \
	  && echo "database $(CH_DB) present on every node" \
	  || { echo "failed to create the database — check: make ch-logs"; exit 1; }

ch-schema: ## create the staging tables on every node (idempotent)
	@$(MAKE) --no-print-directory ch-init
	@$(COMPOSE) exec -T clickhouse-01 clickhouse-client --multiquery < clickhouse/sql/10-staging.sql >/dev/null \
	  && echo "staging tables created on every node" \
	  || { echo "schema failed — check: make ch-logs"; exit 1; }

ch-ingest: ## create the Kafka queues and materialized views (idempotent)
	@$(COMPOSE) exec -T clickhouse-01 clickhouse-client --multiquery < clickhouse/sql/20-kafka-ingest.sql >/dev/null \
	  && echo "kafka queues and materialized views created on every node" \
	  || { echo "ingestion setup failed — check: make ch-logs"; exit 1; }
	@echo "  consumers take up to a minute to join their groups and start reading;"
	@echo "  check with: make ch-queues"

# The SETTINGS of a Kafka engine table cannot be altered in place — not the
# group name, not the topic list, not the format. Changing any of them means
# dropping the queue and its view and creating them again.
#
# The consumer group's committed offsets live in Kafka and survive that, so
# the groups are deleted too. Kafka refuses to delete a group that still has
# members, and members linger for the session timeout after their consumer
# disappears — hence the retry loop rather than a single attempt.
#
# The staging tables are not touched. Replaying a topic writes the same
# versions again: same source_lsn, same ORDER BY key, so ReplacingMergeTree
# collapses them back to one. Idempotent by construction, which is the whole
# reason the version column is the log position and not an arrival timestamp.
ch-ingest-reset: ## rebuild the queues and replay the topics from the beginning
	@echo "dropping the views and queues..."
	@$(COMPOSE) exec -T clickhouse-01 clickhouse-client --multiquery < clickhouse/sql/21-drop-ingest.sql >/dev/null \
	  || { echo "drop failed — check: make ch-logs"; exit 1; }
	@echo "deleting the consumer groups (waiting for members to leave)..."
	@for g in $(CH_GROUPS); do \
	   printf '  %-26s ' "$$g"; \
	   for i in $$(seq 1 20); do \
	     if $(KBIN)/kafka-consumer-groups.sh --bootstrap-server $(BOOTSTRAP) \
	          --delete --group $$g >/dev/null 2>&1; then \
	       echo "deleted"; break; \
	     fi; \
	     printf '.'; sleep 5; \
	     [ $$i -eq 20 ] && echo " gave up — the group still has members"; \
	   done; \
	 done
	@echo "recreating..."
	@$(MAKE) --no-print-directory ch-ingest

ch: ## interactive clickhouse-client on node 1
	@$(COMPOSE) exec -it clickhouse-01 clickhouse-client --database $(CH_DB)

# --- ClickHouse: is it built correctly --------------------------------------

# Run this one first. Sharding and replication are configured in two different
# places, and when they disagree the cluster looks correct in system.clusters
# while quietly failing to replicate.
ch-macros: ## what shard and replica each node believes it is
	@for n in $(CH_NODES); do \
	   printf '  clickhouse-%s  ' "$$n"; \
	   $(COMPOSE) exec -T clickhouse-$$n clickhouse-client --query \
	     "SELECT concat('shard=', getMacro('shard'), '  replica=', getMacro('replica'))" 2>/dev/null \
	     || echo "not responding"; \
	 done
	@echo "  (expect shards 1,1,2,2,3,3,4,4 and eight distinct replica names)"

ch-cluster: ## the cluster as ClickHouse sees it — expect 4 shards, 8 replicas
	@echo "topology from system.clusters:"
	@$(CH) --query "SELECT shard_num, replica_num, host_name, errors_count FROM system.clusters WHERE cluster = 'platform' ORDER BY shard_num, replica_num FORMAT PrettyCompact"
	@echo ""
	@echo "every node answering, asked through the cluster:"
	@echo "  (no skip_unavailable_shards here on purpose: this target checks that"
	@echo "   the cluster is healthy, so an unreachable node must be an error)"
	@$(CH) --query "SELECT hostName() AS node, uptime() AS uptime_s FROM clusterAllReplicas('platform', system.one) ORDER BY node FORMAT PrettyCompact"

ch-keeper: ## is the Keeper quorum formed and who leads it
	@echo "readiness of each Keeper node (exactly one leader, two followers):"
	@for n in 1 2 3; do \
	   printf '  keeper-%s  ' "$$n"; \
	   $(COMPOSE) exec -T keeper-$$n wget -qO- http://127.0.0.1:9182/ready 2>/dev/null || printf 'not answering'; \
	   echo ""; \
	 done
	@echo ""
	@echo "shards registered in Keeper:"
	@$(CH) --query "SELECT name AS shard FROM system.zookeeper WHERE path = '/clickhouse/tables' ORDER BY name FORMAT PrettyCompact" 2>/dev/null \
	  || echo "  no tables registered yet — run: make ch-schema"

ch-tables: ## which objects exist, and on how many nodes
	@$(CH) --query "SELECT name, engine, count() AS on_nodes FROM clusterAllReplicas('platform', system.tables) WHERE database = '$(CH_DB)' GROUP BY name, engine ORDER BY name FORMAT PrettyCompact SETTINGS skip_unavailable_shards = 1"
	@echo "  (on_nodes should be 8 for every object)"

ch-replicas: ## replication health — queues empty, is_readonly zero
	@$(CH) --query "SELECT hostName() AS node, table, is_readonly, absolute_delay, queue_size FROM clusterAllReplicas('platform', system.replicas) ORDER BY table, node FORMAT PrettyCompact SETTINGS skip_unavailable_shards = 1"

# ---------------------------------------------------------------------------
#  Two details in the query below, both learned the hard way.
#
#  getMacro('shard'), not a scalar subquery over system.macros. A scalar
#  subquery is evaluated once on the initiator and shipped to the other nodes
#  as a constant, so every row came back claiming to be shard 1.
#
#  total_rows from system.tables, not count() over the table. With count() and
#  GROUP BY, a node holding no rows produces no groups and vanishes from the
#  output — so freshly added, empty shards looked absent rather than empty.
#
#  skip_unavailable_shards = 1 makes this usable during a failure drill. The
#  default is to fail outright when a replica is unreachable, which is right
#  for a warehouse and wrong for a diagnostic meant to run while a node is down.
# ---------------------------------------------------------------------------
ch-rows: ## rows per node — equal within a shard, split across shards
	@$(CH) --query "SELECT getMacro('shard') AS shard, hostName() AS node, total_rows AS rows FROM clusterAllReplicas('platform', system.tables) WHERE database = '$(CH_DB)' AND name = 'orders_local' ORDER BY shard, node FORMAT PrettyCompact SETTINGS skip_unavailable_shards = 1"
	@echo "  (the two nodes of a shard must match; shards must differ)"
	@echo "  (a missing node is down; 0 is a node that is up and empty)"

# ClickHouse never rebalances an existing table when shards are added. Rows
# already written stay on the shard that received them; only new rows spread
# over the larger set. There is no command that moves them.
ch-shards: ## rows per shard — after growing the cluster, the new shards are empty
	@$(CH) --query "SELECT shard, max(rows) AS rows_in_shard, count() AS replicas FROM (SELECT getMacro('shard') AS shard, hostName() AS node, total_rows AS rows FROM clusterAllReplicas('platform', system.tables) WHERE database = '$(CH_DB)' AND name = 'orders_local') GROUP BY shard ORDER BY shard FORMAT PrettyCompact SETTINGS skip_unavailable_shards = 1"
	@echo "  max() rather than sum(): the two replicas of a shard hold the same"
	@echo "  rows, so adding them would double every shard."

# --- ingestion: is the pipeline flowing -------------------------------------

# Three separate questions, three targets, because they fail independently:
#   ch-queues     is ClickHouse subscribed and reading at all
#   ch-consumers  how far behind Kafka thinks those consumers are
#   ch-compare    do both sides hold the same rows
ch-queues: ## are the Kafka engine tables consuming, and are they erroring
	@echo "consumers registered by ClickHouse:"
	@$(CH) --query "SELECT table, count() AS consumers, sum(num_messages_read) AS messages_read, max(last_poll_time) AS last_poll FROM clusterAllReplicas('platform', system.kafka_consumers) GROUP BY table ORDER BY table FORMAT PrettyCompact SETTINGS skip_unavailable_shards = 1" 2>&1 \
	  || echo "  system.kafka_consumers is empty — the queues were never created"
	@echo ""
	@echo "recent exceptions (empty is what you want):"
	@$(CH) --query "SELECT table, arrayJoin(\`exceptions.text\`) AS err FROM clusterAllReplicas('platform', system.kafka_consumers) WHERE notEmpty(\`exceptions.text\`) LIMIT 5 FORMAT PrettyCompact SETTINGS skip_unavailable_shards = 1" 2>&1 \
	  | grep . || echo "  none"
	@echo ""
	@echo "  The column is the nested array exceptions.text, not last_exception —"
	@echo "  ClickHouse's \"maybe you meant\" hint on that name is misleading."
	@echo ""
	@echo "  messages_read = 0 right after ch-ingest is normal: consumers take up"
	@echo "  to a minute to join their groups. Zero that stays zero is not."

ch-consumers: ## Kafka's view of the ClickHouse consumer groups
	@for g in $(CH_GROUPS); do \
	   echo "  $$g"; \
	   $(KBIN)/kafka-consumer-groups.sh --bootstrap-server $(BOOTSTRAP) \
	     --describe --group $$g 2>&1 | grep -v '^$$' | sed 's/^/    /' | head -10; \
	   echo ""; \
	 done
	@echo "  LAG is the column to read. A group with no members means ClickHouse"
	@echo "  is not subscribed — check: make ch-queues"

ch-compare: ## row counts on both sides, table by table
	@printf '  %-14s %-12s %-12s\n' "table" "postgres" "clickhouse"
	@for t in customers products orders order_items; do \
	   p=$$($(PSQL) -t -A -c "SELECT count(*) FROM $$t" 2>/dev/null | tr -d '\r'); \
	   c=$$($(CH) --query "SELECT count() FROM $(CH_DB).$$t FINAL WHERE is_deleted = 0" 2>/dev/null | tr -d '\r'); \
	   printf '  %-14s %-12s %-12s\n' "$$t" "$${p:-?}" "$${c:-?}"; \
	 done
	@echo ""
	@echo "  FINAL and is_deleted = 0 on the ClickHouse side: without them you"
	@echo "  would count every version of every row plus the tombstones."
	@echo ""
	@echo "  products should match exactly — it is only ever updated in place."
	@echo "  orders and order_items differ by a few rows because the generator"
	@echo "  keeps writing while the two sides are counted. A gap that grows is"
	@echo "  the thing to worry about."

# ---------------------------------------------------------------------------
#  End to end
# ---------------------------------------------------------------------------
#  One row through every hop: Postgres WAL, Debezium, Kafka, the ClickHouse
#  Kafka engine, the materialized view, the Distributed table, the sharding
#  key, ReplicatedReplacingMergeTree and FINAL.
#
#  A customer rather than an order, because customers can be deleted: orders
#  have foreign keys pointing at them.
#
#  Note the `| head -1` on the INSERT. psql prints the RETURNING value AND a
#  status line like "INSERT 0 1"; without head the status line gets
#  concatenated into the next query and ClickHouse reports a syntax error at
#  a position that has nothing to do with anything you wrote.
# ---------------------------------------------------------------------------
ch-e2e: ## one row from Postgres to ClickHouse: insert, update, delete
	@id=$$($(PSQL) -t -A -c "INSERT INTO customers (email, full_name, country_code) VALUES ('e2e-$$$$@example.com','End To End','XX') RETURNING customer_id" | head -1 | tr -d '\r'); \
	 echo "1. inserted customer_id=$$id in Postgres"; \
	 printf '   waiting for it in ClickHouse '; \
	 for i in $$(seq 1 60); do \
	   n=$$($(CH) --query "SELECT count() FROM $(CH_DB).customers FINAL WHERE customer_id = $$id AND is_deleted = 0" 2>/dev/null | tr -d '\r'); \
	   if [ "$$n" = "1" ]; then echo "— arrived after $${i}s"; break; fi; \
	   printf '.'; sleep 1; \
	 done; \
	 echo ""; \
	 echo "2. updating it"; \
	 $(PSQL) -q -c "UPDATE customers SET full_name = 'End To End (updated)', updated_at = now() WHERE customer_id = $$id" >/dev/null; \
	 printf '   waiting for the new value '; \
	 for i in $$(seq 1 60); do \
	   v=$$($(CH) --query "SELECT full_name FROM $(CH_DB).customers FINAL WHERE customer_id = $$id" 2>/dev/null | tr -d '\r'); \
	   case "$$v" in *updated*) echo "— arrived after $${i}s"; break;; esac; \
	   printf '.'; sleep 1; \
	 done; \
	 echo ""; \
	 echo "3. deleting it"; \
	 $(PSQL) -q -c "DELETE FROM customers WHERE customer_id = $$id" >/dev/null; \
	 printf '   waiting for it to leave FINAL '; \
	 for i in $$(seq 1 60); do \
	   n=$$($(CH) --query "SELECT count() FROM $(CH_DB).customers FINAL WHERE customer_id = $$id AND is_deleted = 0" 2>/dev/null | tr -d '\r'); \
	   if [ "$$n" = "0" ]; then echo "— gone after $${i}s"; break; fi; \
	   printf '.'; sleep 1; \
	 done; \
	 echo ""; \
	 echo "   every version still stored, newest last:"; \
	 $(CH) --query "SELECT op, full_name, source_lsn, is_deleted FROM $(CH_DB).customers WHERE customer_id = $$id ORDER BY source_lsn FORMAT PrettyCompact"; \
	 echo ""; \
	 echo "   the tombstone carries the whole row, not just the key."; \
	 echo "   That is REPLICA IDENTITY FULL on the source doing its job —"; \
	 echo "   without it these columns would be empty:"; \
	 $(CH) --query "SELECT email, full_name, country_code FROM $(CH_DB).customers WHERE customer_id = $$id AND is_deleted = 1 LIMIT 1 FORMAT PrettyCompact"

ch-insert-test: ## write 1000 rows through the Distributed table and see where they land
	@$(CH) --query "INSERT INTO $(CH_DB).orders (order_id, customer_id, status, total_amount, created_at, updated_at, op, source_lsn, source_ts, is_deleted) SELECT number + 900000, 1, 'pending', 10.00, now64(3), now64(3), 'c', number, now64(3), 0 FROM numbers(1000)"
	@echo "inserted 1000 rows through the Distributed table"
	@sleep 3
	@$(MAKE) --no-print-directory ch-rows

# Note the `< /dev/null` on every INSERT ... VALUES below.
#
# clickhouse-client keeps reading stdin after an inline VALUES clause, in case
# more rows follow, and `docker compose exec -T` leaves stdin open — so the
# command sits there forever with no output and no error.
ch-dedup-test: ## prove that versions collapse and deletes disappear
	@$(CH) --query "INSERT INTO $(CH_DB).orders (order_id, customer_id, status, total_amount, created_at, updated_at, op, source_lsn, source_ts, is_deleted) VALUES (999001, 1, 'pending', 10.00, '2026-01-01 00:00:00.000', '2026-01-01 00:00:00.000', 'c', 100, '2026-01-01 00:00:00.000', 0)" < /dev/null
	@$(CH) --query "INSERT INTO $(CH_DB).orders (order_id, customer_id, status, total_amount, created_at, updated_at, op, source_lsn, source_ts, is_deleted) VALUES (999001, 1, 'paid', 42.00, '2026-01-01 00:00:00.000', '2026-01-01 00:01:00.000', 'u', 200, '2026-01-01 00:01:00.000', 0)" < /dev/null
	@sleep 2
	@echo "after insert + update"
	@printf '  rows stored (2, unless a merge already collapsed them): '
	@$(CH) --query "SELECT count() FROM $(CH_DB).orders WHERE order_id = 999001"
	@echo "  with FINAL, highest source_lsn wins:"
	@$(CH) --query "SELECT status, total_amount, source_lsn FROM $(CH_DB).orders FINAL WHERE order_id = 999001 FORMAT PrettyCompact"
	@$(CH) --query "INSERT INTO $(CH_DB).orders (order_id, customer_id, status, total_amount, created_at, updated_at, op, source_lsn, source_ts, is_deleted) VALUES (999001, 1, 'paid', 42.00, '2026-01-01 00:00:00.000', '2026-01-01 00:02:00.000', 'd', 300, '2026-01-01 00:02:00.000', 1)" < /dev/null
	@sleep 2
	@echo "after the delete event"
	@printf '  rows stored (the tombstone is a version like any other): '
	@$(CH) --query "SELECT count() FROM $(CH_DB).orders WHERE order_id = 999001"
	@printf '  with FINAL (expect 0 — gone as far as readers are concerned): '
	@$(CH) --query "SELECT count() FROM $(CH_DB).orders FINAL WHERE order_id = 999001"

ch-cleanup-test: ## remove everything the test targets wrote
	@$(CH) --query "TRUNCATE TABLE $(CH_DB).orders_local ON CLUSTER platform" >/dev/null \
	  && echo "orders_local truncated on every node"
	@echo "  note: this also removes the captured orders. Ingestion will only"
	@echo "  bring back events produced from now on; to replay everything,"
	@echo "  use make ch-ingest-reset."

# ---------------------------------------------------------------------------
#  Failure drill: lose a replica, keep writing, get it back
# ---------------------------------------------------------------------------
#  Three things to watch: writes keep succeeding while a replica is down, the
#  returning replica is behind for a moment, and it converges on its own.
#
#  The middle one needs volume. An earlier version wrote 500 rows and the
#  replica caught up before the first measurement — the drill passed while
#  demonstrating nothing. Even two million can converge within a second,
#  because ClickHouse replicates whole compressed parts rather than rows.
# ---------------------------------------------------------------------------
DRILL_ROWS ?= 2000000

ch-drill-down: ## stop one replica of shard 1 and write a lot while it is gone
	docker stop clickhouse-02
	@sleep 2
	@echo "writing $(DRILL_ROWS) rows with clickhouse-02 down..."
	@$(CH) --query "INSERT INTO $(CH_DB).orders (order_id, customer_id, status, total_amount, created_at, updated_at, op, source_lsn, source_ts, is_deleted) SELECT number + 800000, 1, 'pending', 10.00, now64(3), now64(3), 'c', number, now64(3), 0 FROM numbers($(DRILL_ROWS))"
	@echo ""
	@echo "the write succeeded: the Distributed table sent every row to the"
	@echo "surviving replica of its shard. Nothing was lost and nothing errored."
	@echo ""
	@$(MAKE) --no-print-directory ch-rows
	@echo ""
	@echo "Bring it back:  make ch-drill-up"

ch-drill-up: ## start the replica again and watch it catch up in real time
	docker start clickhouse-02
	@printf 'waiting for clickhouse-02 to accept queries '
	@for i in $$(seq 1 30); do \
	   if $(COMPOSE) exec -T clickhouse-02 clickhouse-client --query "SELECT 1" >/dev/null 2>&1; then \
	     echo "— up"; break; \
	   fi; printf '.'; sleep 1; \
	 done
	@echo ""
	@echo "polling every second until the two replicas of shard 1 agree:"
	@start=$$(date +%s); \
	 while :; do \
	   a=$$($(COMPOSE) exec -T clickhouse-01 clickhouse-client --query "SELECT count() FROM $(CH_DB).orders_local" 2>/dev/null | tr -d '\r'); \
	   b=$$($(COMPOSE) exec -T clickhouse-02 clickhouse-client --query "SELECT count() FROM $(CH_DB).orders_local" 2>/dev/null | tr -d '\r'); \
	   q=$$($(COMPOSE) exec -T clickhouse-02 clickhouse-client --query "SELECT queue_size FROM system.replicas WHERE table = 'orders_local'" 2>/dev/null | tr -d '\r'); \
	   t=$$(( $$(date +%s) - start )); \
	   printf '  t+%-3ss clickhouse-01=%-10s clickhouse-02=%-10s queue=%s\n' "$$t" "$${a:-?}" "$${b:-?}" "$${q:-?}"; \
	   if [ -n "$$a" ] && [ "$$a" = "$$b" ]; then echo "  caught up after $${t}s"; break; fi; \
	   if [ "$$t" -ge 120 ]; then echo "  still behind after 120s — check: make ch-replicas"; break; fi; \
	   sleep 1; \
	 done
	@echo ""
	@$(MAKE) --no-print-directory ch-rows

ch-metrics: ## what Prometheus sees of ClickHouse and Keeper
	@printf 'clickhouse targets discovered (expect 8): '
	@curl -fsS "$(PROM)/api/v1/targets?state=active" 2>/dev/null \
	  | grep -o '"job": *"clickhouse"' | wc -l | tr -d ' '
	@printf 'keeper targets discovered (expect 3):     '
	@curl -fsS "$(PROM)/api/v1/targets?state=active" 2>/dev/null \
	  | grep -o '"job": *"clickhouse-keeper"' | wc -l | tr -d ' '
	@printf 'nodes reporting uptime:                   '
	@$(call promq,count(ClickHouseAsyncMetrics_Uptime))
	@printf 'memory used across the cluster, GiB:      '
	@$(call promq,sum(ClickHouseMetrics_MemoryTracking) / 1024 / 1024 / 1024)

ch-logs: ## follow the ClickHouse and Keeper logs
	$(COMPOSE) logs -f $(foreach n,$(CH_NODES),clickhouse-$(n)) keeper-1 keeper-2 keeper-3

# --- change data capture ----------------------------------------------------

connector: check-env ## register or update the Debezium connector
	@./connect/register-connector.sh

connector-delete: ## remove the connector (the replication slot goes with it)
	@curl -fsS -X DELETE "$(CONNECT)/connectors/postgres-source" \
	  && echo "connector deleted" || echo "no connector to delete"

connector-restart: ## restart a failed connector and its task
	@curl -fsS -X POST "$(CONNECT)/connectors/postgres-source/restart?includeTasks=true" \
	  && echo "restart requested" || true

cdc-status: ## connector state, task state, and the replication slot
	@echo "connector and task state (want RUNNING for both):"
	@curl -fsS "$(CONNECT)/connectors/postgres-source/status" 2>/dev/null \
	  | tr ',' '\n' | grep -E '"(state|trace)"' | sed 's/[{}"]//g' \
	  || echo "  not registered — run: make connector"
	@echo ""
	@echo "replication slot in postgres (active must be t):"
	@$(PSQL) -c "SELECT slot_name, plugin, active, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS wal_retained FROM pg_replication_slots;" 2>/dev/null || true

# kafka.tools.GetOffsetShell no longer exists in Kafka 4 — the tools moved
# packages. The supported way is kafka-get-offsets.sh, one call per topic.
cdc-topics: ## the CDC topics and how many messages are in each
	@topics=$$($(KBIN)/kafka-topics.sh --bootstrap-server $(BOOTSTRAP) --list 2>/dev/null | grep '^cdc\.' | tr -d '\r'); \
	 if [ -z "$$topics" ]; then echo "no cdc topics yet — run: make connector"; exit 0; fi; \
	 for t in $$topics; do \
	   n=$$($(KBIN)/kafka-get-offsets.sh --bootstrap-server $(BOOTSTRAP) --topic "$$t" 2>/dev/null \
	        | awk -F: '{s += $$3} END {print s + 0}'); \
	   printf '  %-28s %s messages\n' "$$t" "$$n"; \
	 done

cdc-tail: ## watch change events on the orders topic
	@$(KBIN)/kafka-console-consumer.sh --bootstrap-server $(BOOTSTRAP) \
	  --topic cdc.public.orders --max-messages 20 2>/dev/null

cdc-deletes: ## recent delete events, to check REPLICA IDENTITY FULL
	@$(KBIN)/kafka-console-consumer.sh --bootstrap-server $(BOOTSTRAP) \
	  --topic cdc.public.customers --from-beginning --max-messages 5000 --timeout-ms 15000 2>/dev/null \
	  | grep '"__deleted":"true"' | tail -2 || echo "  none yet — deletes happen every few minutes"

cdc-slot: ## how much write-ahead log the slot is holding
	@$(PSQL) -c "SELECT slot_name, active, confirmed_flush_lsn, pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), confirmed_flush_lsn)) AS retained FROM pg_replication_slots;"

connect-logs: ## follow Kafka Connect
	$(COMPOSE) logs -f kafka-connect

connect-metrics: ## what monitoring sees of the capture pipeline
	@printf 'kafka-connect targets discovered (expect 1): '
	@curl -fsS "$(PROM)/api/v1/targets?state=active" 2>/dev/null \
	  | grep -o '"job": *"kafka-connect"' | wc -l | tr -d ' '
	@printf 'running tasks (expect 1):        '
	@$(call promq,sum(connect_connector_running_tasks))
	@printf 'failed tasks (expect 0):         '
	@$(call promq,sum(connect_connector_failed_tasks))
	@printf 'debezium connected (expect 1):   '
	@$(call promq,max(debezium_connected))
	@printf 'capture lag, ms (near zero):     '
	@$(call promq,max(debezium_milliseconds_behind_source))

cdc-alerts: ## capture-related alerting rules
	@curl -fsS "$(PROM)/api/v1/rules" 2>/dev/null \
	  | tr ',' '\n' | grep -E '"name": *"(Connect|Debezium|Postgres|ClickHouse|Keeper)' | sed 's/"//g'

# --- Postgres ---------------------------------------------------------------

seed: ## fill the reference tables (safe to re-run: exits if already seeded)
	@$(COMPOSE) run --rm --no-deps generator seed

psql: ## interactive SQL prompt against the source database
	@$(COMPOSE) exec -it postgres psql -U $(PG_USER) -d $(PG_DB)

schema: ## list the Postgres tables and their replica identity
	@$(PSQL) -c "\\dt"
	@echo "replica identity (f = FULL, needed for CDC deletes):"
	@$(PSQL) -c "SELECT relname, relreplident FROM pg_class WHERE relname IN ('customers','products','orders','order_items') ORDER BY relname;"

counts: ## row counts and order status breakdown in Postgres
	@$(PSQL) -c "SELECT 'customers' AS table, count(*) FROM customers UNION ALL SELECT 'products', count(*) FROM products UNION ALL SELECT 'orders', count(*) FROM orders UNION ALL SELECT 'order_items', count(*) FROM order_items;"
	@$(PSQL) -c "SELECT status, count(*) FROM orders GROUP BY status ORDER BY count(*) DESC;"

generator-logs: ## follow what the generator is doing
	$(COMPOSE) logs -f generator

pg-metrics: ## did Prometheus discover the exporter, and what does it report
	@printf 'postgres targets discovered (expect 1): '
	@curl -fsS "$(PROM)/api/v1/targets?state=active" 2>/dev/null \
	  | grep -o '"job": *"postgres"' | wc -l | tr -d ' '
	@printf 'pg_up: '
	@$(call promq,pg_up)
	@printf 'commits/sec in $(PG_DB): '
	@$(call promq,rate(pg_stat_database_xact_commit{datname="$(PG_DB)"}[1m]))

pg-alerts: ## postgres alerting rules Prometheus has loaded
	@curl -fsS "$(PROM)/api/v1/rules" 2>/dev/null \
	  | tr ',' '\n' | grep -E '"name": *"Postgres' | sed 's/"//g'

discovery: ## what docker-sd found, by job
	@curl -fsS "$(PROM)/api/v1/targets?state=active" 2>/dev/null \
	  | tr '{' '\n' | grep -oE '"job": *"(postgres|kafka-connect|clickhouse|clickhouse-keeper)"' \
	  | sed 's/.*"\(.*\)"/  \1/' | sort | uniq -c

# --- inspection -------------------------------------------------------------

ps: ## container status
	$(COMPOSE) ps

logs: ## follow the logs of every service (Ctrl+C to exit)
	$(COMPOSE) logs -f
