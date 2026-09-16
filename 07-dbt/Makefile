# Short entry points for the dbt stack.
#
# This stack includes 06-spark and everything below it, so `make up` here
# starts the whole platform. dbt itself is not a service — it is an image that
# runs and exits.
#
#   make             - list the available commands
#   make up          - start the platform and build the dbt image
#   make dbt-debug   - can dbt reach ClickHouse
#   make dbt-build-all - run the models and their tests, in dependency order
#   make clean       - stop everything and wipe every volume in the project

PROFILES ?= --profile clickhouse
COMPOSE := docker compose $(PROFILES)

ENV        := .env
SPARK_ENV  := ../06-spark/.env
MINIO_ENV  := ../05-minio/.env
ETL_ENV    := ../04-etl/.env
DBMS_ENV   := ../03-dbms/.env
MON_ENV    := ../02-monitoring/.env
KAFKA_ENV  := ../01-kafka/.env

getenv = $(shell grep -E '^$(1)=' $(2) 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

DBT_VERSION := $(or $(call getenv,DBT_VERSION,$(ENV)),0.1.0)
DBT_IMAGE   := dataplatform/dbt:$(DBT_VERSION)
SOURCE_DB   := $(or $(call getenv,SOURCE_DATABASE,$(ENV)),analytics)
DBT_SCHEMA  := $(or $(call getenv,DBT_SCHEMA,$(ENV)),marts)

CH := $(COMPOSE) exec -T clickhouse-01 clickhouse-client

# ----------------------------------------------------------------------------
#  Everything dbt needs, as environment variables
# ----------------------------------------------------------------------------
#  Collected once here rather than repeated on every target. profiles.yml and
#  the source definitions read them through env_var, so the image carries no
#  addresses and no credentials of its own.
# ----------------------------------------------------------------------------
DBT_ENV := \
  -e CLICKHOUSE_HOST=$(or $(call getenv,CLICKHOUSE_HOST,$(ENV)),clickhouse-01) \
  -e CLICKHOUSE_PORT=$(or $(call getenv,CLICKHOUSE_PORT,$(ENV)),9000) \
  -e CLICKHOUSE_USER=$(or $(call getenv,CLICKHOUSE_USER,$(ENV)),default) \
  -e CLICKHOUSE_PASSWORD=$(call getenv,CLICKHOUSE_PASSWORD,$(ENV)) \
  -e DBT_SCHEMA=$(DBT_SCHEMA) \
  -e DBT_TARGET=$(or $(call getenv,DBT_TARGET,$(ENV)),dev) \
  -e SOURCE_DATABASE=$(SOURCE_DB) \
  -e POSTGRES_HOST=$(or $(call getenv,POSTGRES_HOST,$(ENV)),postgres) \
  -e POSTGRES_PORT=$(or $(call getenv,POSTGRES_PORT,$(ENV)),5432) \
  -e POSTGRES_DB=$(or $(call getenv,POSTGRES_DB,$(ENV)),shop) \
  -e POSTGRES_USER=$(or $(call getenv,POSTGRES_USER,$(ENV)),app) \
  -e POSTGRES_PASSWORD=$(or $(call getenv,POSTGRES_PASSWORD,$(ENV)),app) \
  -e S3_ENDPOINT=$(or $(call getenv,S3_ENDPOINT,$(ENV)),http://minio:9000) \
  -e S3_ACCESS_KEY=$(or $(call getenv,S3_ACCESS_KEY,$(ENV)),minioadmin) \
  -e S3_SECRET_KEY=$(or $(call getenv,S3_SECRET_KEY,$(ENV)),minioadmin) \
  -e S3_BUCKET_STAGED=$(or $(call getenv,S3_BUCKET_STAGED,$(ENV)),staged)

DBT := docker run --rm --network dataplatform $(DBT_ENV) $(DBT_IMAGE)

# The development variant: the local project is mounted over the baked one, so
# an edit takes effect without a rebuild. Deliberately a separate command —
# a DAG never does this, because then the image tag would stop describing what
# runs.
DBT_DEV := docker run --rm --network dataplatform $(DBT_ENV) \
  -v $(PWD)/project:/dbt $(DBT_IMAGE)

.DEFAULT_GOAL := help
.PHONY: help check-env up up-light down restart clean ps logs config urls \
        dbt-build dbt-version dbt-debug dbt-ls dbt-run dbt-test dbt-build-all \
        dbt-freshness dbt-compare dbt-dev dbt-shell models smoke test

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

check-env:
	@for f in $(ENV) $(SPARK_ENV) $(MINIO_ENV) $(ETL_ENV) $(DBMS_ENV) $(MON_ENV) $(KAFKA_ENV); do \
	  test -f $$f || { echo ""; echo "ERROR: $$f is missing"; \
	    echo "       Create it from the .env.example next to it."; echo ""; exit 1; }; \
	 done
	@test -f project/dbt_project.yml || { echo "ERROR: project/dbt_project.yml is missing"; exit 1; }
	@test -f project/profiles.yml || { echo "ERROR: project/profiles.yml is missing"; exit 1; }
	@test -x scripts/smoke.sh || { echo "ERROR: scripts/smoke.sh is missing or not executable"; \
	  echo "       chmod +x scripts/smoke.sh"; exit 1; }

up: check-env ## start the platform and build the dbt image
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory dbt-build
	@$(MAKE) --no-print-directory urls

up-light: ## start without the ClickHouse cluster
	@$(MAKE) --no-print-directory PROFILES= up

down: ## stop the containers, keep the data
	$(COMPOSE) down

restart: ## restart the containers
	$(COMPOSE) restart

clean: ## stop everything and delete every volume in the project
	$(COMPOSE) down -v

urls: ## print the web interfaces
	@echo ""
	@echo "  Spark master   http://localhost:8090"
	@echo "  MinIO console  http://localhost:9001"
	@echo "  Airflow        http://localhost:8081"
	@echo "  ClickHouse     http://localhost:8123/play"
	@echo "  Grafana        http://localhost:3000"
	@echo ""
	@echo "  dbt is not a service. Check it with:  make dbt-debug"
	@echo ""

# --- dbt --------------------------------------------------------------------

# Deliberately NOT dependent on check-env.
#
# check-env requires the .env of every stack below, because `make up` starts
# the whole platform. Building an image needs none of that — it reads the
# Dockerfile and the project directory and nothing else.
#
# The distinction is not academic: the CI workflow builds and parses without
# starting anything, and hanging check-env here made it demand six .env files
# for stacks it never touches.
dbt-build: ## build the dbt image
	@printf 'building %s ... ' "$(DBT_IMAGE)"
	@docker build -q -t $(DBT_IMAGE) -f dbt/Dockerfile . >/dev/null \
	  && echo "ok" || { echo "FAILED"; exit 1; }

# Which dbt-core pip actually chose. requirements.txt pins only the adapter —
# see the comment there — so the core version is a result rather than a
# decision, and worth being able to read.
dbt-version: ## which dbt and adapter versions are installed
	@$(DBT) --version

dbt-debug: ## can dbt reach ClickHouse
	@$(DBT) debug

dbt-ls: ## what dbt sees in the project
	@$(DBT) ls

dbt-run: ## run the models (ARGS="--select stg_orders")
	@$(DBT) run $(ARGS)

dbt-test: ## run the tests (ARGS="--select stg_orders")
	@$(DBT) test $(ARGS)

dbt-build-all: ## run and test in dependency order
	@$(DBT) build $(ARGS)

# ----------------------------------------------------------------------------
#  The check that catches a stopped pipeline
# ----------------------------------------------------------------------------
#  When change capture breaks, nothing errors. The topics stop receiving
#  messages, which looks exactly like an idle database, and every model keeps
#  building happily from data that stopped moving hours ago.
#
#  Freshness is measured on source_ts — the timestamp Debezium read from the
#  source — rather than on when the row arrived here. A replay of a week-old
#  backlog would look perfectly fresh by arrival time.
# ----------------------------------------------------------------------------
dbt-freshness: ## how old is the newest row in each source
	@$(DBT) source freshness

# ----------------------------------------------------------------------------
#  Does FINAL actually do anything
# ----------------------------------------------------------------------------
#  Compares each staging model against its source counted without FINAL. The
#  source number is higher by however many versions change capture has
#  produced, and that gap is the whole reason the staging layer exists.
#
#  If the two ever match exactly for orders, either nothing has been updated
#  since the last merge — or FINAL has quietly been dropped from the model.
# ----------------------------------------------------------------------------
dbt-compare: ## staging rows against raw source rows, per table
	@printf '  %-16s %-14s %-14s %s\n' "table" "source rows" "staged rows" "versions collapsed"
	@for t in orders order_items customers products; do \
	   raw=$$($(CH) --query "SELECT count() FROM $(SOURCE_DB).$$t" 2>/dev/null | tr -d '\r'); \
	   stg=$$($(CH) --query "SELECT count() FROM $(DBT_SCHEMA)_staging.stg_$$t" 2>/dev/null | tr -d '\r'); \
	   if [ -n "$$raw" ] && [ -n "$$stg" ]; then \
	     printf '  %-16s %-14s %-14s %s\n' "$$t" "$$raw" "$$stg" "$$((raw - stg))"; \
	   else \
	     printf '  %-16s %-14s %-14s %s\n' "$$t" "$${raw:-?}" "$${stg:-not built}" "-"; \
	   fi; \
	 done
	@echo ""
	@echo "  The gap is versions plus tombstones, not an error. It is what FINAL"
	@echo "  and the is_deleted filter remove."

models: ## which tables and views dbt has created
	@$(CH) --query "SELECT database, name, engine FROM system.tables WHERE database LIKE '$(DBT_SCHEMA)%' ORDER BY database, name FORMAT PrettyCompact" \
	  2>/dev/null || echo "  nothing built yet — run: make dbt-build-all"

# Iterate without rebuilding. The local project is mounted over the one in the
# image, so an edit to a model takes effect on the next command.
dbt-dev: ## run a dbt command against the local project (CMD="run --select x")
	@$(DBT_DEV) $${CMD:-build}

dbt-shell: ## a shell in the dbt image, project mounted
	@docker run --rm -it --network dataplatform $(DBT_ENV) \
	  -v $(PWD)/project:/dbt --entrypoint bash $(DBT_IMAGE)

# --- inspection -------------------------------------------------------------

ps: ## container status
	$(COMPOSE) ps

logs: ## follow every service
	$(COMPOSE) logs -f

# Half of this runs with no database at all, which is what CI uses. The rest
# needs ClickHouse and skips without it.
smoke: ## assert the project parses and, if the warehouse is up, that it builds
	@./scripts/smoke.sh

test: smoke ## the smoke test; see also `make config` for the compose files

config: check-env ## validate the compose file and the includes
	@$(COMPOSE) config -q && echo "compose file is valid, all variables resolved"
