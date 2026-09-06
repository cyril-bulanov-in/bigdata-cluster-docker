# Short entry points for the orchestration stack.
#
# This stack includes 03-dbms, which includes 02-monitoring and 01-kafka, so
# `make up` here starts the whole platform. Run every command from this
# directory.
#
#   make          - list the available commands
#   make up       - start everything
#   make up-light - start without the ClickHouse cluster
#   make af-logs  - follow the Airflow components
#   make clean    - stop everything and wipe every volume in the project

COMPOSE_BASE := docker compose

# The clickhouse profile is defined in 03-dbms and enabled by default here
# too, so `make up` behaves the same from either directory.
PROFILES ?= --profile clickhouse
COMPOSE := $(COMPOSE_BASE) $(PROFILES)

ENV       := .env
DBMS_ENV  := ../03-dbms/.env
MON_ENV   := ../02-monitoring/.env
KAFKA_ENV := ../01-kafka/.env

getenv = $(shell grep -E '^$(1)=' $(2) 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

AF_PORT   := $(or $(call getenv,AIRFLOW_PORT,$(ENV)),8081)
JOB_VERSION := $(or $(call getenv,JOB_VERSION,$(ENV)),0.1.0)
PROM_PORT := $(or $(call getenv,PROMETHEUS_PORT,$(MON_ENV)),9090)

AIRFLOW := http://localhost:$(AF_PORT)
PROM    := http://localhost:$(PROM_PORT)

AF_COMPONENTS := airflow-apiserver airflow-scheduler airflow-dag-processor airflow-triggerer

.DEFAULT_GOAL := help
.PHONY: help check-env up up-light down restart clean ps logs config urls \
        af-logs af-status af-metrics af-password af-shell dags \
        jobs jobs-list dag-run dag-state dag-errors mart mart-run mart-job \
        smoke test

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

check-env:
	@for f in $(ENV) $(DBMS_ENV) $(MON_ENV) $(KAFKA_ENV); do \
	  test -f $$f || { echo ""; echo "ERROR: $$f is missing"; \
	    echo "       Create it from the .env.example next to it."; echo ""; exit 1; }; \
	 done
	@test -f statsd/mapping.yml || { echo "ERROR: statsd/mapping.yml is missing"; exit 1; }
	@test -x scripts/smoke.sh || { echo "ERROR: scripts/smoke.sh is missing or not executable"; \
	  echo "       chmod +x scripts/smoke.sh"; exit 1; }
	@test -d dags || { echo "ERROR: the dags/ directory is missing"; exit 1; }

up: check-env ## start the whole platform including Airflow
	@$(MAKE) --no-print-directory jobs
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
	@echo "  Airflow     $(AIRFLOW)   (no login — see docker-compose.yml)"
	@echo "  ClickHouse  http://localhost:8123/play"
	@echo "  Kafbat UI   http://localhost:8080"
	@echo "  Grafana     http://localhost:3000"
	@echo "  Prometheus  $(PROM)"
	@echo ""
	@echo "  Airflow takes a minute or two to become reachable. Check with:"
	@echo "      make af-status"
	@echo ""

# --- job images -------------------------------------------------------------

# Built here, not by docker-compose.
#
# A job image is an artifact, not a service: nothing starts it and leaves it
# running, and declaring it in compose would invite exactly that confusion.
# Airflow runs it and it exits. Keeping the build separate is the boundary
# this repository is built around, expressed in the file layout.
#
# DockerOperator never builds anything. If the image is absent the task fails
# with "No such image", which reads like an Airflow problem and is not.
jobs: ## build the job images
	@for d in jobs/*/; do \
	   name=$$(basename $$d); \
	   echo "building dataplatform/job-$$name:$(JOB_VERSION)"; \
	   docker build -q -t dataplatform/job-$$name:$(JOB_VERSION) $$d >/dev/null \
	     && echo "  ok" || { echo "  FAILED"; exit 1; }; \
	 done

jobs-list: ## which job images exist locally
	@docker images --filter 'reference=dataplatform/job-*' \
	  --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' || true

# --- DAGs ---------------------------------------------------------------------

dag-run: ## trigger the smoke DAG and follow it
	@$(COMPOSE) exec -T airflow-scheduler airflow dags unpause 00_docker_smoke >/dev/null 2>&1 || true
	@$(COMPOSE) exec -T airflow-scheduler airflow dags trigger 00_docker_smoke \
	  && echo "" && echo "  triggered. Watch it at $(AIRFLOW)/dags/00_docker_smoke" \
	  && echo "  or:  make dag-state"

# Airflow 3 renamed the arguments these commands take: `-d` is gone, the
# flag is `--dag-id`, and states-for-dag-run wants the run id positionally.
# The old spelling exits with a usage message rather than an error, so a
# broken target looks like a target that found nothing.
dag-state: ## the most recent runs of a DAG and their task states
	@dag=$${DAG:-10_daily_sales}; \
	 echo "recent runs of $$dag:"; \
	 $(COMPOSE) exec -T airflow-scheduler \
	   airflow dags list-runs --dag-id $$dag --output plain 2>/dev/null | head -6 \
	   || echo "  none"; \
	 echo ""; \
	 run=$$($(COMPOSE) exec -T airflow-scheduler \
	   airflow dags list-runs --dag-id $$dag --output plain 2>/dev/null | awk 'NR==2 {print $$2}'); \
	 if [ -n "$$run" ]; then \
	   echo "task states of $$run:"; \
	   $(COMPOSE) exec -T airflow-scheduler \
	     airflow tasks states-for-dag-run $$dag "$$run" --output plain 2>/dev/null || true; \
	 else echo "  no runs yet"; fi

dag-errors: ## DAG files that failed to import
	@$(COMPOSE) exec -T airflow-dag-processor airflow dags list-import-errors 2>/dev/null \
	  || echo "  dag-processor not ready"
	@echo "  (an empty list is what you want; a DAG with an import error simply"
	@echo "   never appears in the UI, with no other sign that it exists)"

mart-run: ## trigger the daily sales DAG for the most recent complete day
	@$(COMPOSE) exec -T airflow-scheduler airflow dags unpause 10_daily_sales >/dev/null 2>&1 || true
	@$(COMPOSE) exec -T airflow-scheduler airflow dags trigger 10_daily_sales >/dev/null \
	  && echo "triggered — watch it: make dag-state DAG=10_daily_sales"

# Runs the job image directly, with no Airflow in the way.
#
# Worth having as a separate command: when a mart is wrong, the first question
# is whether the job is wrong or the orchestration is. This answers it in one
# step, and it is also how you develop the SQL without waiting for a schedule.
mart-job: ## run the mart job by hand, outside Airflow (DAY=YYYY-MM-DD)
	@day=$${DAY:-$$(date -u -v-1d +%F 2>/dev/null || date -u -d yesterday +%F)}; \
	 echo "computing $$day"; \
	 docker run --rm --network dataplatform \
	   -e CLICKHOUSE_URL=http://clickhouse-01:8123 \
	   -e CLICKHOUSE_DB=analytics \
	   -e TARGET_DATE=$$day \
	   -e DRY_RUN=$${DRY_RUN:-0} \
	   dataplatform/job-daily-sales:$(JOB_VERSION)

mart: ## what is in the mart right now
	@docker compose exec -T clickhouse-01 clickhouse-client --database analytics --query \
	  "SELECT day, category, orders, items, revenue FROM daily_sales_by_category FINAL ORDER BY day DESC, revenue DESC LIMIT 20 FORMAT PrettyCompact" \
	  2>/dev/null || echo "  the mart does not exist yet — run: make mart-job"

# --- Airflow ----------------------------------------------------------------

af-status: ## are the four Airflow components up and is the API answering
	@$(COMPOSE) ps --format '  {{.Name}}\t{{.Status}}' 2>/dev/null | grep airflow || echo "  nothing running"
	@echo ""
	@printf 'health endpoint: '
	@curl -fsS --max-time 5 "$(AIRFLOW)/api/v2/monitor/health" 2>/dev/null \
	  || echo "not answering yet — give it a minute, then: make af-logs"
	@echo ""

# Kept for the case where all-admins mode is turned off again. SimpleAuthManager
# cannot take a password from configuration — `simple_auth_manager_users` sets
# only username and role — so it generates one into a file and prints it here.
# The value changes whenever the volume is recreated, which is exactly why the
# stand does not use it.
af-password: ## find the generated admin password (only needed without all-admins)
	@$(COMPOSE) logs airflow-apiserver 2>/dev/null | grep -i -m3 -E "password|simple_auth" \
	  || echo "  no login is configured — the UI should open without one"

af-logs: ## follow the Airflow components
	$(COMPOSE) logs -f $(AF_COMPONENTS)

af-shell: ## a shell inside the scheduler
	@$(COMPOSE) exec -it airflow-scheduler bash

dags: ## which DAGs Airflow has parsed
	@$(COMPOSE) exec -T airflow-scheduler airflow dags list 2>/dev/null \
	  || echo "  scheduler not ready"

af-metrics: ## is Prometheus scraping Airflow
	@printf 'airflow targets discovered (expect 1): '
	@curl -fsS "$(PROM)/api/v1/targets?state=active" 2>/dev/null \
	  | grep -o '"job": *"airflow"' | wc -l | tr -d ' '
	@printf 'airflow metric series in Prometheus: '
	@curl -fsS --get --data-urlencode 'query=count({__name__=~"airflow_.*"})' \
	  "$(PROM)/api/v1/query" 2>/dev/null \
	  | grep -o '"[0-9]*"]' | head -1 | tr -d '"]' | grep . || echo "none yet"
	@echo "  (Airflow pushes StatsD only when something happens; an idle"
	@echo "   scheduler still emits heartbeat metrics within a minute)"

# --- inspection -------------------------------------------------------------

ps: ## container status
	$(COMPOSE) ps

logs: ## follow every service
	$(COMPOSE) logs -f

smoke: ## assert the whole stack actually works
	@SKIP_CLICKHOUSE=$${SKIP_CLICKHOUSE:-0} ./scripts/smoke.sh

test: config smoke ## validate the configuration, then the running stack

config: check-env ## validate the compose file and the includes
	@$(COMPOSE) config -q && echo "compose file is valid, all variables resolved"
