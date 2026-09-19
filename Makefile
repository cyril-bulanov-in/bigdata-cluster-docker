# ============================================================================
#  bigdata-cluster-docker
# ============================================================================
#  The whole platform, from the top.
#
#    make up      start everything
#    make down    stop it, keep the data
#    make clean   stop it and delete the data
#
#  Run `make` on its own for the full list.
#
# ----------------------------------------------------------------------------
#  This file delegates and does nothing else
# ----------------------------------------------------------------------------
#  Every target here is `cd <stack> && make <target>`. Not one of them runs
#  docker compose directly, and that restraint is the point.
#
#  Each stack's compose file includes the one below it, so the last stack in
#  the chain already describes the whole platform. A root Makefile that
#  assembled its own command would be a ninth place holding the same
#  knowledge — and the first to fall out of step when a stack changes its
#  profiles, its build order, or which services it starts.
#
#  The cost is one extra process per invocation. The benefit is that this file
#  cannot be wrong about a stack, because it does not know anything about one.
# ----------------------------------------------------------------------------

# ----------------------------------------------------------------------------
#  The top of the chain
# ----------------------------------------------------------------------------
#  08-superset includes 07-dbt, which includes 06-spark, and so on down to
#  01-kafka. Starting it starts all eight.
#
#  A variable rather than a literal, so a ninth stack means changing one line
#  here rather than every target below.
# ----------------------------------------------------------------------------
TOP ?= 08-superset

.DEFAULT_GOAL := help
.PHONY: help up down clean restart ps logs config test smoke urls stacks

help: ## show this list
	@echo ""
	@echo "  The whole platform, from the top. Each target delegates to $(TOP),"
	@echo "  whose compose file includes every stack below it."
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) 	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Per-stack commands live in each directory — many are specific to"
	@echo "  one stack and have no meaning here:"
	@echo ""
	@echo "    cd 03-dbms     && make ch-status     the ClickHouse cluster"
	@echo "    cd 04-etl      && make dag-state     an Airflow DAG"
	@echo "    cd 05-minio    && make buckets       the bucket layout"
	@echo "    cd 06-spark    && make cluster       Spark workers and cores"
	@echo "    cd 07-dbt      && make dbt-compare   what FINAL removes"
	@echo "    cd 08-superset && make drivers       Superset's drivers"
	@echo ""

# --- lifecycle ---------------------------------------------------------------

up: ## start the whole platform
	@$(MAKE) -C $(TOP) up

# ----------------------------------------------------------------------------
#  down keeps the data, clean destroys it
# ----------------------------------------------------------------------------
#  `down` removes the containers and leaves the named volumes. Start again and
#  everything is where it was: Kafka topics, ClickHouse tables, the Superset
#  dashboard.
#
#  `clean` adds -v, which deletes every volume in the project. The next start
#  is a blank platform — empty topics, no tables, Superset back to running its
#  migration and re-registering everything from scratch.
#
#  That second one is a bigger gun than its name suggests, which is worth
#  knowing before typing it at three in the morning.
# ----------------------------------------------------------------------------
down: ## stop the containers, keep the data
	@$(MAKE) -C $(TOP) down

clean: ## stop everything and DELETE every volume — topics, tables, dashboards
	@$(MAKE) -C $(TOP) clean

restart: ## restart the containers
	@$(MAKE) -C $(TOP) restart

# --- checks ------------------------------------------------------------------

config: ## validate the compose files and every include
	@$(MAKE) -C $(TOP) config

smoke: ## assert the top of the stack actually works
	@$(MAKE) -C $(TOP) smoke

# ----------------------------------------------------------------------------
#  One stack's test, not all eight
# ----------------------------------------------------------------------------
#  This runs 08-superset's checks. It does not run the other seven, and that
#  is deliberate rather than an omission: each stack's smoke test starts by
#  asserting its own services are up, so running all eight in sequence would
#  take the better part of an hour and mostly re-check the same containers.
#
#  To verify a specific layer, go there — `cd 03-dbms && make test`. The CI
#  workflows do exactly that, one stack per workflow.
# ----------------------------------------------------------------------------
test: ## validate the configuration, then the running stack
	@$(MAKE) -C $(TOP) test

# --- inspection --------------------------------------------------------------

ps: ## container status, across the whole platform
	@$(MAKE) -C $(TOP) ps

logs: ## follow every service
	@$(MAKE) -C $(TOP) logs

urls: ## print every web interface
	@$(MAKE) -C $(TOP) urls

stacks: ## what each stack is, and where to run its own commands
	@echo ""
	@echo "  01-kafka       4-node KRaft cluster"
	@echo "  02-monitoring  Prometheus, Grafana, exporters"
	@echo "  03-dbms        Postgres, Debezium, ClickHouse cluster"
	@echo "  04-etl         Airflow 3, jobs as container images"
	@echo "  05-minio       S3-compatible storage, three-layer buckets"
	@echo "  06-spark       standalone cluster, raw to staged"
	@echo "  07-dbt         models, tests, lineage, one Airflow task per model"
	@echo "  08-superset    connection, datasets and dashboard, all from code"
	@echo ""
	@echo "  Each includes the one above it. Starting 08 starts all eight;"
	@echo "  starting 02 starts only Kafka and its monitoring."
	@echo ""
