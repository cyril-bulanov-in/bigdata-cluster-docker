# Short entry points for the object storage stack.
#
# This stack includes 04-etl and everything below it, so `make up` here starts
# the whole platform. Run every command from this directory.
#
#   make          - list the available commands
#   make up       - start everything
#   make up-light - start without the ClickHouse cluster
#   make mc       - a shell with the MinIO client, configured
#   make clean    - stop everything and wipe every volume in the project

PROFILES ?= --profile clickhouse
COMPOSE := docker compose $(PROFILES)

ENV       := .env
ETL_ENV   := ../04-etl/.env
DBMS_ENV  := ../03-dbms/.env
MON_ENV   := ../02-monitoring/.env
KAFKA_ENV := ../01-kafka/.env

getenv = $(shell grep -E '^$(1)=' $(2) 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

API_PORT     := $(or $(call getenv,MINIO_API_PORT,$(ENV)),9000)
CONSOLE_PORT := $(or $(call getenv,MINIO_CONSOLE_PORT,$(ENV)),9001)
MINIO_USER   := $(or $(call getenv,MINIO_ROOT_USER,$(ENV)),minioadmin)
MINIO_PASS   := $(or $(call getenv,MINIO_ROOT_PASSWORD,$(ENV)),minioadmin)
MC_VERSION   := $(or $(call getenv,MC_VERSION,$(ENV)),latest)
PROM_PORT    := $(or $(call getenv,PROMETHEUS_PORT,$(MON_ENV)),9090)

PROM := http://localhost:$(PROM_PORT)

# The client runs as a throwaway container on the platform network, so it
# reaches MinIO by service name exactly as a job would.
MC := docker run --rm --network dataplatform \
        -e MC_HOST_local=http://$(MINIO_USER):$(MINIO_PASS)@minio:9000 \
        minio/mc:$(MC_VERSION)

.DEFAULT_GOAL := help
.PHONY: help check-env up up-light down restart clean ps logs config urls \
        mc buckets buckets-init objects minio-status minio-metrics smoke test

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

check-env:
	@for f in $(ENV) $(ETL_ENV) $(DBMS_ENV) $(MON_ENV) $(KAFKA_ENV); do \
	  test -f $$f || { echo ""; echo "ERROR: $$f is missing"; \
	    echo "       Create it from the .env.example next to it."; echo ""; exit 1; }; \
	 done
	@test -f minio/init.sh || { echo "ERROR: minio/init.sh is missing"; exit 1; }
	@test -x scripts/smoke.sh || { echo "ERROR: scripts/smoke.sh is missing or not executable"; \
	  echo "       chmod +x scripts/smoke.sh"; exit 1; }

up: check-env ## start the whole platform including MinIO
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
	@echo "  MinIO console  http://localhost:$(CONSOLE_PORT)   ($(MINIO_USER))"
	@echo "  MinIO S3 API   http://localhost:$(API_PORT)"
	@echo "  Airflow        http://localhost:8081"
	@echo "  ClickHouse     http://localhost:8123/play"
	@echo "  Grafana        http://localhost:3000"
	@echo "  Prometheus     $(PROM)"
	@echo ""

# --- MinIO ------------------------------------------------------------------

minio-status: ## is MinIO up and answering
	@printf 'health: '
	@curl -fsS --max-time 5 "http://localhost:$(API_PORT)/minio/health/live" >/dev/null 2>&1 \
	  && echo "live" || echo "not answering"
	@echo "server info:"
	@$(MC) admin info local 2>/dev/null | head -12 || echo "  mc could not reach it"

buckets: ## the bucket layout, with versioning and lifecycle
	@echo "buckets:"
	@$(MC) ls local 2>/dev/null | sed 's/^/  /' || echo "  none — run: make buckets-init"
	@echo ""
	@echo "versioning (on for raw and staged, off for curated):"
	@for b in raw staged curated; do \
	   printf '  %-10s ' "$$b"; \
	   $(MC) version info local/$$b 2>/dev/null | tail -1 || echo "not found"; \
	 done
	@echo ""
	@echo "lifecycle rules:"
	@for b in raw staged; do \
	   echo "  $$b:"; \
	   $(MC) ilm rule ls local/$$b 2>/dev/null | sed 's/^/    /' || echo "    none"; \
	 done

buckets-init: ## re-run the layout script (idempotent)
	@$(COMPOSE) up --no-deps --force-recreate minio-init

# Objects live under a prefix, and the prefix is part of the name — there are
# no directories in S3. Listing recursively is the only way to see what is
# actually stored, as opposed to what the console groups for display.
objects: ## everything stored, recursively (BUCKET=raw to narrow)
	@$(MC) ls --recursive local/$${BUCKET:-} 2>/dev/null | sed 's/^/  /' || echo "  nothing"

mc: ## interactive shell with the MinIO client, already configured
	@docker run --rm -it --network dataplatform \
	  -e MC_HOST_local=http://$(MINIO_USER):$(MINIO_PASS)@minio:9000 \
	  --entrypoint sh minio/mc:$(MC_VERSION)

minio-metrics: ## is Prometheus scraping MinIO
	@printf 'minio targets discovered (expect 1): '
	@curl -fsS "$(PROM)/api/v1/targets?state=active" 2>/dev/null \
	  | grep -o '"job": *"minio"' | wc -l | tr -d ' '
	@printf 'minio metric series: '
	@curl -fsS --get --data-urlencode 'query=count({__name__=~"minio_.*"})' \
	  "$(PROM)/api/v1/query" 2>/dev/null \
	  | grep -o '"[0-9]*"\]' | head -1 | tr -d '"]' | grep . || echo "none yet"

# --- inspection -------------------------------------------------------------

ps: ## container status
	$(COMPOSE) ps

logs: ## follow every service
	$(COMPOSE) logs -f

smoke: ## assert the whole stack actually works
	@./scripts/smoke.sh

test: config smoke ## validate the configuration, then the running stack

config: check-env ## validate the compose file and the includes
	@$(COMPOSE) config -q && echo "compose file is valid, all variables resolved"
