# Short entry points for the orchestration stack.
#
# This stack includes 03-dbms, which includes 02-monitoring and 01-kafka, so
# `make up` here starts the whole platform. Run every command from this
# directory.
#
#   make              - list the available commands
#   make up           - start everything
#   make up-light     - start without the ClickHouse cluster
#   make jobs         - build the job images
#   make test         - validate configs, then the running stack
#   make clean        - stop everything and wipe every volume in the project

COMPOSE_BASE := docker compose

# ----------------------------------------------------------------------------
#  The clickhouse profile
# ----------------------------------------------------------------------------
#  Defined in 03-dbms and enabled by default here too, so `make up` behaves the
#  same from either directory. `make up-light` overrides it to nothing, which
#  is what continuous integration runs: eight ClickHouse nodes at 2 GiB do not
#  fit on a GitHub runner.
#
#  The override has to reach down, ps and clean as well — a profiled container
#  that was never started is also not stopped by a command that does not know
#  about its profile.
# ----------------------------------------------------------------------------
PROFILES ?= --profile clickhouse
COMPOSE := $(COMPOSE_BASE) $(PROFILES)

ENV       := .env
DBMS_ENV  := ../03-dbms/.env
MON_ENV   := ../02-monitoring/.env
KAFKA_ENV := ../01-kafka/.env

getenv = $(shell grep -E '^$(1)=' $(2) 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

AF_PORT     := $(or $(call getenv,AIRFLOW_PORT,$(ENV)),8081)
JOB_VERSION := $(or $(call getenv,JOB_VERSION,$(ENV)),0.1.0)
PROM_PORT   := $(or $(call getenv,PROMETHEUS_PORT,$(MON_ENV)),9090)
GRAF_PORT   := $(or $(call getenv,GRAFANA_PORT,$(MON_ENV)),3000)

AIRFLOW := http://localhost:$(AF_PORT)
PROM    := http://localhost:$(PROM_PORT)

AF_COMPONENTS := airflow-apiserver airflow-scheduler airflow-dag-processor airflow-triggerer

# Yesterday, in UTC. BSD date on macOS and GNU date on Linux disagree about
# the flag, so both spellings are tried.
YESTERDAY = $$(date -u -v-1d +%F 2>/dev/null || date -u -d yesterday +%F)

.DEFAULT_GOAL := help
.PHONY: help check-env up up-core up-light down restart clean ps logs config \
        smoke test urls af-logs af-status af-metrics af-password af-shell dags \
        jobs jobs-list dag-run dag-state dag-errors \
        mart mart-run mart-job export-job

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

check-env:
	@for f in $(ENV) $(DBMS_ENV) $(MON_ENV) $(KAFKA_ENV); do \
	  test -f $$f || { echo ""; echo "ERROR: $$f is missing"; \
	    echo "       Create it from the .env.example next to it."; echo ""; exit 1; }; \
	 done
	@test -f statsd/mapping.yml || { echo "ERROR: statsd/mapping.yml is missing"; exit 1; }
	@test -d dags || { echo "ERROR: the dags/ directory is missing"; exit 1; }
	@test -x scripts/smoke.sh || { echo "ERROR: scripts/smoke.sh is missing or not executable"; \
	  echo "       chmod +x scripts/smoke.sh"; exit 1; }

# --- lifecycle --------------------------------------------------------------

up-core: check-env ## start the containers without building job images
	$(COMPOSE) up -d --build

up: check-env ## build the job images and start the whole platform
	@$(MAKE) --no-print-directory jobs
	@$(MAKE) --no-print-directory up-core
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
	@echo "  Grafana     http://localhost:$(GRAF_PORT)"
	@echo "  Prometheus  $(PROM)"
	@echo ""
	@echo "  Airflow takes a minute or two to become reachable:  make af-status"
	@echo ""

# --- checks -----------------------------------------------------------------

config: check-env ## validate the compose file and the includes
	@$(COMPOSE) config -q && echo "compose file is valid, all variables resolved"

# SKIP_CLICKHOUSE=1 runs only the checks that do not need the warehouse, and
# prints the rest as SKIP rather than omitting them — a summary that says
# "14 passed" should not look like full coverage of a half-tested stack.
smoke: ## assert the whole stack actually works
	@SKIP_CLICKHOUSE=$${SKIP_CLICKHOUSE:-0} ./scripts/smoke.sh

test: config smoke ## validate the configuration, then the running stack

# --- job images -------------------------------------------------------------

# Built here, not by docker-compose.
#
# A job image is an artifact, not a service: nothing starts it and leaves it
# running, and declaring it in compose would invite exactly that confusion.
# Airflow runs it and it exits. Keeping the build separate is the boundary this
# repository is built around, expressed in the file layout.
#
# DockerOperator never builds anything. If an image is absent the task fails
# with "No such image", which reads like an Airflow problem and is not.
jobs: ## build the job images
	@for d in jobs/*/; do \
	   name=$$(basename $$d); \
	   printf 'building dataplatform/job-%s:%s ... ' "$$name" "$(JOB_VERSION)"; \
	   docker build -q -t dataplatform/job-$$name:$(JOB_VERSION) $$d >/dev/null \
	     && echo "ok" || { echo "FAILED"; exit 1; }; \
	 done

jobs-list: ## which job images exist locally
	@docker images --filter 'reference=dataplatform/job-*' \
	  --format '  {{.Repository}}:{{.Tag}}\t{{.Size}}' || true

# --- DAGs -------------------------------------------------------------------

dag-run: ## trigger a DAG (DAG=... , default the smoke one)
	@dag=$${DAG:-00_docker_smoke}; \
	 $(COMPOSE) exec -T airflow-scheduler airflow dags unpause $$dag >/dev/null 2>&1 || true; \
	 $(COMPOSE) exec -T airflow-scheduler airflow dags trigger $$dag >/dev/null \
	   && echo "triggered $$dag — watch it: make dag-state DAG=$$dag"

# `airflow dags list-runs` takes the dag id positionally — not `-d`, which was
# the Airflow 2 spelling, and not `--dag-id` either. The wrong form exits with
# a usage message rather than an error, so a broken target looks like a target
# that found no runs.
dag-state: ## the most recent runs of a DAG and their task states
	@dag=$${DAG:-10_daily_sales}; \
	 echo "recent runs of $$dag:"; \
	 $(COMPOSE) exec -T airflow-scheduler \
	   airflow dags list-runs $$dag -o plain 2>/dev/null | head -6 || echo "  none"; \
	 echo ""; \
	 run=$$($(COMPOSE) exec -T airflow-scheduler \
	   airflow dags list-runs $$dag -o plain 2>/dev/null | awk 'NR==2 {print $$2}'); \
	 if [ -n "$$run" ]; then \
	   echo "task states of $$run:"; \
	   $(COMPOSE) exec -T airflow-scheduler \
	     airflow tasks states-for-dag-run $$dag "$$run" -o plain 2>/dev/null || true; \
	 else echo "  no runs yet"; fi

dag-errors: ## DAG files that failed to import
	@$(COMPOSE) exec -T airflow-dag-processor airflow dags list-import-errors 2>/dev/null \
	  || echo "  dag-processor not ready"
	@echo "  (an empty list is what you want; a DAG with an import error simply"
	@echo "   never appears in the UI, with no other sign that it exists)"

dags: ## which DAGs Airflow has parsed
	@$(COMPOSE) exec -T airflow-scheduler airflow dags list 2>/dev/null \
	  || echo "  scheduler not ready"

# --- jobs, run directly -----------------------------------------------------

# Running a job outside Airflow is worth its own command. When output is wrong
# the first question is whether the job is wrong or the orchestration is, and
# this answers it in one step. It is also how the SQL gets developed, without
# waiting for a schedule.

mart-job: ## run the mart job by hand (DAY=YYYY-MM-DD, DRY_RUN=1)
	@day=$${DAY:-$(YESTERDAY)}; \
	 echo "computing $$day"; \
	 docker run --rm --network dataplatform \
	   -e CLICKHOUSE_URL=http://clickhouse-01:8123 \
	   -e CLICKHOUSE_DB=analytics \
	   -e TARGET_DATE=$$day \
	   -e DRY_RUN=$${DRY_RUN:-0} \
	   dataplatform/job-daily-sales:$(JOB_VERSION)

export-job: ## run the S3 export by hand (DAY=YYYY-MM-DD, DRY_RUN=1)
	@day=$${DAY:-$(YESTERDAY)}; \
	 echo "exporting $$day"; \
	 docker run --rm --network dataplatform \
	   -e CLICKHOUSE_URL=http://clickhouse-01:8123 \
	   -e CLICKHOUSE_DB=analytics \
	   -e S3_ENDPOINT=http://minio:9000 \
	   -e S3_ACCESS_KEY=$${S3_ACCESS_KEY:-minioadmin} \
	   -e S3_SECRET_KEY=$${S3_SECRET_KEY:-minioadmin} \
	   -e S3_BUCKET=$${S3_BUCKET:-raw} \
	   -e TARGET_DATE=$$day \
	   -e DRY_RUN=$${DRY_RUN:-0} \
	   dataplatform/job-export-orders:$(JOB_VERSION)

mart-run: ## trigger the mart DAG through Airflow
	@$(MAKE) --no-print-directory dag-run DAG=10_daily_sales

mart: ## what is in the mart right now
	@$(COMPOSE_BASE) exec -T clickhouse-01 clickhouse-client --database analytics --query \
	  "SELECT day, category, orders, items, revenue FROM daily_sales_by_category FINAL ORDER BY day DESC, revenue DESC LIMIT 20 FORMAT PrettyCompact" \
	  2>/dev/null || echo "  the mart does not exist yet — run: make mart-job"

# --- Airflow ----------------------------------------------------------------

af-status: ## are the four components up and is the API answering
	@$(COMPOSE) ps --format '  {{.Name}}\t{{.Status}}' 2>/dev/null | grep airflow || echo "  nothing running"
	@echo ""
	@printf 'health endpoint: '
	@curl -fsS --max-time 5 "$(AIRFLOW)/api/v2/monitor/health" 2>/dev/null \
	  || echo "not answering yet — give it a minute, then: make af-logs"
	@echo ""

# SimpleAuthManager cannot take a password from configuration —
# simple_auth_manager_users sets only username and role — so it generates one
# into a file and prints it here. The value changes whenever the volume does,
# which is exactly why this stand disables login instead.
af-password: ## find the generated admin password (only needed without all-admins)
	@$(COMPOSE) logs airflow-apiserver 2>/dev/null | grep -i -m3 -E "password|simple_auth" \
	  || echo "  no login is configured — the UI should open without one"

af-logs: ## follow the Airflow components
	$(COMPOSE) logs -f $(AF_COMPONENTS)

af-shell: ## a shell inside the scheduler
	@$(COMPOSE) exec -it airflow-scheduler bash

af-metrics: ## is Prometheus scraping Airflow
	@printf 'airflow targets discovered (expect 1): '
	@curl -fsS "$(PROM)/api/v1/targets?state=active" 2>/dev/null \
	  | grep -o '"job": *"airflow"' | wc -l | tr -d ' '
	@printf 'airflow metric series in Prometheus:   '
	@curl -fsS --get --data-urlencode 'query=count({__name__=~"airflow_.*"})' \
	  "$(PROM)/api/v1/query" 2>/dev/null \
	  | grep -o '"[0-9]*"\]' | head -1 | tr -d '"]' | grep . || echo "none yet"
	@echo "  (Prometheus discovers new containers on a 30s cycle, and Airflow"
	@echo "   pushes StatsD as events happen — give it a minute after a start)"

# --- inspection -------------------------------------------------------------

ps: ## container status
	$(COMPOSE) ps

logs: ## follow every service
	$(COMPOSE) logs -f
