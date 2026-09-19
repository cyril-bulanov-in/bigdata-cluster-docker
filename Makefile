# ============================================================================
#  bigdata-cluster-docker
# ============================================================================
#  The whole platform, from the top.
#
#    make up        everything, full size
#    make up-16     everything, on a 16 GiB laptop
#    make up-light  everything, on a CI runner
#    make down      stop it, keep the data
#    make clean     stop it and delete the data
#
#  Run `make` on its own for the full list.
#
# ----------------------------------------------------------------------------
#  This file delegates and does nothing else
# ----------------------------------------------------------------------------
#  Every target here is `cd <stack> && make <target>`, with a profile sourced
#  first. Not one of them runs docker compose directly, and that restraint is
#  the point.
#
#  Each stack's compose file includes the one below it, so the last stack in
#  the chain already describes the whole platform. A root Makefile that
#  assembled its own command would be a ninth place holding the same
#  knowledge — and the first to fall out of step when a stack changes.
# ----------------------------------------------------------------------------

TOP ?= 08-superset

# ----------------------------------------------------------------------------
#  Three sizes of the same platform
# ----------------------------------------------------------------------------
#  Not three subsets of it. Every profile starts every subsystem; what differs
#  is how much memory each container may take, and how many ClickHouse nodes
#  there are.
#
#  That distinction is the reason these exist. The `up-light` they replaced
#  simply omitted the warehouse, which left six stacks' smoke tests printing
#  SKIP — CI was verifying that things start, not that they work.
#
#    full    8 ClickHouse nodes, 4 shards x 2 replicas   ~24 GiB + Spark
#    16      4 nodes, 2 shards x 2 replicas              ~13.8 GiB
#    light   2 nodes, 2 shards x 1 replica               ~11.6 GiB
#
#  The light profile is the only one that gives something up: replication.
#  A runner has about 14 GiB usable, and the four-node warehouse leaves
#  nothing spare — an out-of-memory kill at 98% of capacity is intermittent,
#  and intermittent CI is worse than CI that skips something openly.
#
# ----------------------------------------------------------------------------
#  Why sourcing rather than --env-file
# ----------------------------------------------------------------------------
#  Compose resolves ${VAR} from the process environment first, and only falls
#  back to the .env beside the file it is reading. Exporting the profile
#  therefore reaches all eight stacks at once.
#
#  --env-file would not. It applies to the top-level compose file, while each
#  included stack reads the .env in its OWN directory — the trap that left
#  Prometheus half-blind for five steps, because a variable set in one stack
#  was invisible when the same service was started from another.
#
#  Each stack's .env keeps working as the default for anyone running
#  `cd 03-dbms && make up` directly. A profile holds only what differs.
#
#  Variables a stack does not use are inert: Compose interpolates only the
#  names that appear in the file it is processing.
# ----------------------------------------------------------------------------
PROFILE_DIR := profiles

# set -a exports every assignment the file makes, which is what puts them in
# the environment Compose reads. Without it they would be shell variables of
# this recipe and nothing more.
define with_profile
	@test -f $(PROFILE_DIR)/$(1).env || { \
	  echo "ERROR: $(PROFILE_DIR)/$(1).env is missing"; exit 1; }
	@echo "profile: $(1)"
	@set -a; . ./$(PROFILE_DIR)/$(1).env; set +a; \
	 $(MAKE) -C $(TOP) $(2)
endef

.DEFAULT_GOAL := help
.PHONY: help up up-16 up-light down clean restart ps logs config test smoke \
        urls stacks profiles

help: ## show this list
	@echo ""
	@echo "  The whole platform, from the top. Each target delegates to $(TOP),"
	@echo "  whose compose file includes every stack below it."
	@echo ""
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
	  | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "  Per-stack commands live in each directory — many are specific to"
	@echo "  one stack and have no meaning here:"
	@echo ""
	@echo "    cd 03-dbms     && make ch-status     the ClickHouse cluster"
	@echo "    cd 04-etl      && make dag-state     an Airflow DAG"
	@echo "    cd 05-minio    && make buckets       the bucket layout"
	@echo "    cd 06-spark    && make cluster       Spark workers and cores"
	@echo "    cd 07-dbt      && make dbt-compare   what FINAL removes"
	@echo "    cd 08-superset && make drivers       Superset drivers"
	@echo ""

# --- starting ----------------------------------------------------------------

up: ## start everything, full size (8 ClickHouse nodes)
	$(call with_profile,full,up)

up-16: ## start everything on a 16 GiB machine (4 ClickHouse nodes)
	$(call with_profile,16,up)

up-light: ## start everything on a CI runner (2 nodes, no replication)
	$(call with_profile,light,up)

# --- lifecycle ---------------------------------------------------------------

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
#  Both take the full profile, because stopping does not depend on how the
#  platform was started: compose removes the containers it finds.
# ----------------------------------------------------------------------------
down: ## stop the containers, keep the data
	$(call with_profile,full,down)

clean: ## stop everything and DELETE every volume — topics, tables, dashboards
	$(call with_profile,full,clean)

restart: ## restart the containers
	$(call with_profile,full,restart)

# --- checks ------------------------------------------------------------------

config: ## validate the compose files and every include
	$(call with_profile,full,config)

smoke: ## assert the top of the stack actually works
	$(call with_profile,full,smoke)

# ----------------------------------------------------------------------------
#  One stack's test, not all eight
# ----------------------------------------------------------------------------
#  This runs 08-superset's checks. Each stack's smoke test begins by asserting
#  its own services are up, so running all eight in sequence would take the
#  better part of an hour and mostly re-check the same containers.
#
#  To verify a specific layer, go there — `cd 03-dbms && make test`. The CI
#  workflows do exactly that, one stack per workflow.
# ----------------------------------------------------------------------------
test: ## validate the configuration, then the running stack
	$(call with_profile,full,test)

# --- inspection --------------------------------------------------------------

ps: ## container status, across the whole platform
	$(call with_profile,full,ps)

logs: ## follow every service
	$(call with_profile,full,logs)

urls: ## print every web interface
	$(call with_profile,full,urls)

profiles: ## what the three sizes differ in
	@echo ""
	@printf '  %-10s %-34s %s\n' "profile" "ClickHouse" "memory"
	@printf '  %-10s %-34s %s\n' "full"  "8 nodes, 4 shards x 2 replicas" "as each stack sets it"
	@printf '  %-10s %-34s %s\n' "16"    "4 nodes, 2 shards x 2 replicas" "~13.8 GiB"
	@printf '  %-10s %-34s %s\n' "light" "2 nodes, 2 shards x 1 replica"  "~11.6 GiB"
	@echo ""
	@echo "  Every profile starts every subsystem. Only light gives anything"
	@echo "  up — replication — and it does so because a runner has roughly"
	@echo "  14 GiB usable and four nodes leave nothing spare."
	@echo ""
	@echo "  The values live in $(PROFILE_DIR)/. Each holds only what differs"
	@echo "  from a stack's own .env."
	@echo ""

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
