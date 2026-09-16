# Short entry points for the dbt stack.
#
# This stack includes 06-spark and everything below it, so `make up` here
# starts the whole platform. dbt itself is not a service — it is an image that
# runs and exits.
#
#   make             - list the available commands
#   make up          - start the platform
#   make dbt-build   - build the image
#   make dbt-debug   - can dbt reach ClickHouse
#   make dbt-run     - run the models
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
  -e DBT_SCHEMA=$(or $(call getenv,DBT_SCHEMA,$(ENV)),marts) \
  -e DBT_TARGET=$(or $(call getenv,DBT_TARGET,$(ENV)),dev) \
  -e SOURCE_DATABASE=$(or $(call getenv,SOURCE_DATABASE,$(ENV)),analytics) \
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
        dbt-dev dbt-shell

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

check-env:
	@for f in $(ENV) $(SPARK_ENV) $(MINIO_ENV) $(ETL_ENV) $(DBMS_ENV) $(MON_ENV) $(KAFKA_ENV); do \
	  test -f $$f || { echo ""; echo "ERROR: $$f is missing"; \
	    echo "       Create it from the .env.example next to it."; echo ""; exit 1; }; \
	 done
	@test -f project/dbt_project.yml || { echo "ERROR: project/dbt_project.yml is missing"; exit 1; }
	@test -f project/profiles.yml || { echo "ERROR: project/profiles.yml is missing"; exit 1; }

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

dbt-build: check-env ## build the dbt image
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

dbt-run: ## run the models
	@$(DBT) run $(ARGS)

dbt-test: ## run the tests
	@$(DBT) test $(ARGS)

dbt-build-all: ## run and test in dependency order
	@$(DBT) build $(ARGS)

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

config: check-env ## validate the compose file and the includes
	@$(COMPOSE) config -q && echo "compose file is valid, all variables resolved"
