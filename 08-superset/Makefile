# Short entry points for the dashboard stack.
#
# This stack includes 07-dbt and everything below it, so `make up` here starts
# the whole platform.
#
#   make              - list the available commands
#   make up           - start everything, Superset included
#   make up-light     - start without the ClickHouse cluster
#   make test         - assert Superset is usable, not merely running
#   make clean        - stop everything and wipe every volume in the project

PROFILES ?= --profile clickhouse
COMPOSE := docker compose $(PROFILES)

ENV        := .env
DBT_ENV    := ../07-dbt/.env
SPARK_ENV  := ../06-spark/.env
MINIO_ENV  := ../05-minio/.env
ETL_ENV    := ../04-etl/.env
DBMS_ENV   := ../03-dbms/.env
MON_ENV    := ../02-monitoring/.env
KAFKA_ENV  := ../01-kafka/.env

getenv = $(shell grep -E '^$(1)=' $(2) 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

SUPERSET_VERSION := $(or $(call getenv,SUPERSET_VERSION,$(ENV)),6.1.0)
SUPERSET_PORT    := $(or $(call getenv,SUPERSET_PORT,$(ENV)),8089)
ADMIN_USER       := $(or $(call getenv,SUPERSET_ADMIN_USER,$(ENV)),admin)
ADMIN_PASSWORD   := $(or $(call getenv,SUPERSET_ADMIN_PASSWORD,$(ENV)),admin)

SUPERSET := http://localhost:$(SUPERSET_PORT)

# The virtualenv Superset runs from. Not a detail: a package installed with
# the system pip lands outside it and is invisible to the application.
VENV_PY := /app/.venv/bin/python

.DEFAULT_GOAL := help
.PHONY: help check-env up up-light down restart clean ps logs config urls \
        superset-log superset-shell superset-status superset-version \
        superset-reset-admin drivers smoke test

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

check-env:
	@for f in $(ENV) $(DBT_ENV) $(SPARK_ENV) $(MINIO_ENV) $(ETL_ENV) $(DBMS_ENV) $(MON_ENV) $(KAFKA_ENV); do \
	  test -f $$f || { echo ""; echo "ERROR: $$f is missing"; \
	    echo "       Create it from the .env.example next to it."; echo ""; exit 1; }; \
	 done
	@test -f superset/superset_config.py || { echo "ERROR: superset/superset_config.py is missing"; exit 1; }
	@test -x scripts/smoke.sh || { echo "ERROR: scripts/smoke.sh is missing or not executable"; \
	  echo "       chmod +x scripts/smoke.sh"; exit 1; }

# ----------------------------------------------------------------------------
#  Build before starting, not as part of starting
# ----------------------------------------------------------------------------
#  `up --build` builds and pulls concurrently, and the superset service names
#  dataplatform/superset without a build section of its own — only
#  superset-init has one. From Compose's point of view that is an image to
#  fetch from a registry where it has never existed:
#
#      pull access denied for dataplatform/superset,
#      repository does not exist or may require 'docker login'
#
#  which reads as an authentication problem and is not. The same thing
#  happened in step 6 with dataplatform/jmx-exporter.
# ----------------------------------------------------------------------------
up: check-env ## start the whole platform including Superset
	$(COMPOSE) build superset-init
	$(COMPOSE) up -d --build
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
	@echo "  Superset       $(SUPERSET)   ($(ADMIN_USER) / $(ADMIN_PASSWORD))"
	@echo "  dbt docs       http://localhost:8088"
	@echo "  Airflow        http://localhost:8081"
	@echo "  Spark master   http://localhost:8090"
	@echo "  MinIO console  http://localhost:9001"
	@echo "  ClickHouse     http://localhost:8123/play"
	@echo "  Grafana        http://localhost:3000"
	@echo ""
	@echo "  Superset takes a minute or two on a cold start:  make superset-status"
	@echo ""

# --- checks -----------------------------------------------------------------

smoke: ## assert Superset is usable, not merely running
	@./scripts/smoke.sh

test: config smoke ## validate the configuration, then the running stack

config: check-env ## validate the compose file and the includes
	@$(COMPOSE) config -q && echo "compose file is valid, all variables resolved"

# --- Superset ---------------------------------------------------------------

superset-status: ## is it up and answering
	@printf 'container: '
	@$(COMPOSE) ps --format '{{.Status}}' superset 2>/dev/null | head -1 || echo "not running"
	@printf 'health:    '
	@curl -fsS --max-time 5 "$(SUPERSET)/health" 2>/dev/null || echo "not answering"
	@echo ""
	@printf 'login page: '
	@curl -fsS -o /dev/null -w '%{http_code}' --max-time 10 "$(SUPERSET)/login/" 2>/dev/null \
	  || echo "no answer"
	@echo ""

superset-version: ## which Superset is running
	@$(COMPOSE) exec -T superset superset version 2>/dev/null | tail -3 || echo "  not running"

# ----------------------------------------------------------------------------
#  The one thing this image adds over the official one
# ----------------------------------------------------------------------------
#  Checked through the venv's interpreter explicitly. Superset 6 runs from a
#  virtualenv at /app/.venv built by uv, and a package installed with the
#  system pip lands where the application never looks — present on disk,
#  absent from Superset, discovered only when a query runs.
# ----------------------------------------------------------------------------
drivers: ## are the drivers installed where Superset looks
	@$(COMPOSE) exec -T superset $(VENV_PY) -c \
	  "import clickhouse_connect, psycopg2; \
print('  clickhouse-connect', clickhouse_connect.__version__); \
print('  psycopg2          ', psycopg2.__version__)" \
	  2>/dev/null || echo "  drivers are NOT importable from $(VENV_PY)"
	@$(COMPOSE) exec -T superset $(VENV_PY) -c \
	  "import clickhouse_connect.cc_sqlalchemy; print('  clickhousedb:// dialect registers')" \
	  2>/dev/null || echo "  the clickhousedb:// dialect does NOT register"

superset-log: ## follow Superset and its init container
	$(COMPOSE) logs -f superset superset-init

superset-shell: ## a shell inside Superset
	@$(COMPOSE) exec -it superset bash

# The admin password is set once, when the metadata volume is created.
# Editing .env afterwards changes nothing, because the account then lives in
# Superset's own database.
superset-reset-admin: ## reset the admin password to what .env says
	@$(COMPOSE) exec -T superset superset fab reset-password \
	  --username $(ADMIN_USER) --password $(ADMIN_PASSWORD) \
	  && echo "  password reset for $(ADMIN_USER)"

# --- inspection -------------------------------------------------------------

ps: ## container status
	$(COMPOSE) ps

logs: ## follow every service
	$(COMPOSE) logs -f
