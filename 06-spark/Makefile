# Short entry points for the Spark stack.
#
# This stack includes 05-minio and everything below it, so `make up` here
# starts the whole platform. Run every command from this directory.
#
#   make            - list the available commands
#   make up         - start everything
#   make up-light   - start without the ClickHouse cluster
#   make cluster    - what the master sees: workers, cores, memory
#   make spark-shell - an interactive PySpark session on the cluster
#   make clean      - stop everything and wipe every volume in the project

PROFILES ?= --profile clickhouse
COMPOSE := docker compose $(PROFILES)

ENV       := .env
MINIO_ENV := ../05-minio/.env
ETL_ENV   := ../04-etl/.env
DBMS_ENV  := ../03-dbms/.env
MON_ENV   := ../02-monitoring/.env
KAFKA_ENV := ../01-kafka/.env

getenv = $(shell grep -E '^$(1)=' $(2) 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

SPARK_VERSION := $(or $(call getenv,SPARK_VERSION,$(ENV)),3.5.9)
UI_PORT       := $(or $(call getenv,SPARK_MASTER_UI_PORT,$(ENV)),8090)
PROM_PORT     := $(or $(call getenv,PROMETHEUS_PORT,$(MON_ENV)),9090)

JOB_VERSION   := $(or $(call getenv,JOB_VERSION,$(ENV)),0.1.0)
EXEC_MEMORY   := $(or $(call getenv,SPARK_EXECUTOR_MEMORY,$(ENV)),1g)
EXEC_CORES    := $(or $(call getenv,SPARK_EXECUTOR_CORES,$(ENV)),1)
CORES_MAX     := $(or $(call getenv,SPARK_CORES_MAX,$(ENV)),4)
DRIVER_MEMORY := $(or $(call getenv,SPARK_DRIVER_MEMORY,$(ENV)),1g)
S3_ENDPOINT   := $(or $(call getenv,S3_ENDPOINT,$(ENV)),http://minio:9000)
MINIO_USER    := $(or $(call getenv,MINIO_ROOT_USER,$(ENV)),minioadmin)
MINIO_PASS    := $(or $(call getenv,MINIO_ROOT_PASSWORD,$(ENV)),minioadmin)
MC_VERSION    := $(or $(call getenv,MC_VERSION,$(MINIO_ENV)),latest)

PROM  := http://localhost:$(PROM_PORT)
SPARK := http://localhost:$(UI_PORT)

WORKERS := spark-worker-1 spark-worker-2 spark-worker-3 spark-worker-4

.DEFAULT_GOAL := help
.PHONY: help check-env up up-light down restart clean ps logs config urls \
        cluster spark-shell spark-logs spark-metrics jars smoke test jobs spark-job staged staged-ls

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

check-env:
	@for f in $(ENV) $(MINIO_ENV) $(ETL_ENV) $(DBMS_ENV) $(MON_ENV) $(KAFKA_ENV); do \
	  test -f $$f || { echo ""; echo "ERROR: $$f is missing"; \
	    echo "       Create it from the .env.example next to it."; echo ""; exit 1; }; \
	 done
	@test -f spark/Dockerfile || { echo "ERROR: spark/Dockerfile is missing"; exit 1; }
	@test -f spark/spark-defaults.conf || { echo "ERROR: spark/spark-defaults.conf is missing"; exit 1; }
	@test -f spark/metrics.properties || { echo "ERROR: spark/metrics.properties is missing"; exit 1; }
	@test -x scripts/smoke.sh || { echo "ERROR: scripts/smoke.sh is missing or not executable"; \
	  echo "       chmod +x scripts/smoke.sh"; exit 1; }

up: check-env ## start the whole platform including Spark
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory jobs
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
	@echo "  Spark master   $(SPARK)"
	@echo "  MinIO console  http://localhost:9001"
	@echo "  Airflow        http://localhost:8081"
	@echo "  ClickHouse     http://localhost:8123/play"
	@echo "  Grafana        http://localhost:3000"
	@echo "  Prometheus     $(PROM)"
	@echo ""

# --- job images -------------------------------------------------------------

# Built FROM the cluster image, so driver and executors run the same Spark
# build and the same jars. Two images that drifted apart produce serialisation
# errors naming a class and not the reason.
jobs: ## build the Spark job images
	@for d in jobs/*/; do \
	   name=$$(basename $$d); \
	   printf 'building dataplatform/spark-job-%s:%s ... ' "$$name" "$(JOB_VERSION)"; \
	   docker build -q \
	     --build-arg SPARK_IMAGE_LOCAL=dataplatform/spark:$(SPARK_VERSION) \
	     -t dataplatform/spark-job-$$name:$(JOB_VERSION) $$d >/dev/null \
	     && echo "ok" || { echo "FAILED"; exit 1; }; \
	 done

# ---------------------------------------------------------------------------
#  Note --name and --hostname, and why both are needed
# ---------------------------------------------------------------------------
#  This runs in client mode: the driver is inside this container, the
#  executors are on the workers, and the executors connect BACK to the driver.
#  They need a name that resolves to it.
#
#  Left alone, Spark advertises whatever the container thinks its hostname is
#  — a random hex id no other container can resolve. The job then starts, gets
#  executors, and hangs: the driver waits for executors that are failing to
#  reach it, and nothing in the driver log says so.
#
#  --name gives Docker's DNS something to resolve on the platform network,
#  --hostname makes the container agree, and SPARK_DRIVER_HOST tells Spark to
#  advertise that name rather than guess.
# ---------------------------------------------------------------------------
# The transformation. TARGET_DATE restricts it to one day; empty processes
# every partition present in the source.
staged: ## run raw -> staged (DATE=YYYY-MM-DD, DRY_RUN=1)
	@docker run --rm --network dataplatform \
	   --name spark-driver --hostname spark-driver \
	   -e SPARK_MASTER_URL=spark://spark-master:7077 \
	   -e SPARK_DRIVER_HOST=spark-driver \
	   -e SPARK_DRIVER_MEMORY=$(DRIVER_MEMORY) \
	   -e SPARK_EXECUTOR_MEMORY=$(EXEC_MEMORY) \
	   -e SPARK_EXECUTOR_CORES=$(EXEC_CORES) \
	   -e SPARK_CORES_MAX=$(CORES_MAX) \
	   -e S3_ENDPOINT=$(S3_ENDPOINT) \
	   -e AWS_ACCESS_KEY_ID=$(MINIO_USER) \
	   -e AWS_SECRET_ACCESS_KEY=$(MINIO_PASS) \
	   -e SRC_BUCKET=$${SRC_BUCKET:-raw} \
	   -e DST_BUCKET=$${DST_BUCKET:-staged} \
	   -e TARGET_DATE=$${DATE:-} \
	   -e DRY_RUN=$${DRY_RUN:-0} \
	   dataplatform/spark-job-orders-staged:$(JOB_VERSION)

staged-ls: ## what is in the staged bucket
	@docker run --rm --network dataplatform \
	   -e "MC_HOST_local=http://$(MINIO_USER):$(MINIO_PASS)@minio:9000" \
	   minio/mc:$(MC_VERSION) ls --recursive local/staged 2>/dev/null \
	   | sed 's/^/  /' || echo "  nothing in staged yet — run: make staged"

spark-job: ## run the smoke job on the cluster (JOB=spark-smoke)
	@job=$${JOB:-spark-smoke}; \
	 docker run --rm --network dataplatform \
	   --name spark-driver --hostname spark-driver \
	   -e SPARK_MASTER_URL=spark://spark-master:7077 \
	   -e SPARK_DRIVER_HOST=spark-driver \
	   -e SPARK_DRIVER_MEMORY=$(DRIVER_MEMORY) \
	   -e SPARK_EXECUTOR_MEMORY=$(EXEC_MEMORY) \
	   -e SPARK_EXECUTOR_CORES=$(EXEC_CORES) \
	   -e SPARK_CORES_MAX=$(CORES_MAX) \
	   -e S3_ENDPOINT=$(S3_ENDPOINT) \
	   -e AWS_ACCESS_KEY_ID=$(MINIO_USER) \
	   -e AWS_SECRET_ACCESS_KEY=$(MINIO_PASS) \
	   -e S3_BUCKET=$${S3_BUCKET:-raw} \
	   -e S3_PREFIX=$${S3_PREFIX:-orders} \
	   dataplatform/spark-job-$$job:$(JOB_VERSION)

# --- the cluster ------------------------------------------------------------

cluster: ## what the master sees — workers, cores, memory
	@printf 'master: '
	@curl -fsS --max-time 5 "$(SPARK)/json/" 2>/dev/null \
	  | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['status'], d['url'])" \
	  || { echo "not answering on $(SPARK)"; exit 0; }
	@echo ""
	@curl -fsS --max-time 5 "$(SPARK)/json/" 2>/dev/null | python3 -c "\
import json, sys; \
d = json.load(sys.stdin); \
w = [x for x in d.get('workers', []) if x.get('state') == 'ALIVE']; \
print(f'  alive workers : {len(w)}'); \
print(f'  total cores   : {sum(x[\"cores\"] for x in w)}'); \
print(f'  total memory  : {sum(x[\"memory\"] for x in w)} MiB'); \
[print(f'    {x[\"host\"]:18} {x[\"cores\"]} cores  {x[\"memory\"]} MiB  {x[\"state\"]}') for x in w]" \
	  || echo "  could not read the master's json"

# The jars are what makes s3a:// work at all, and the most common reason it
# does not. Checking them on a worker rather than the master: workers run the
# tasks that actually read S3.
jars: ## are the S3 jars present on a worker
	@$(COMPOSE) exec -T spark-worker-1 ls /opt/spark/jars 2>/dev/null \
	  | grep -E 'hadoop-aws|aws-java-sdk' | sed 's/^/  /' \
	  || echo "  worker not running"
	@echo ""
	@echo "  hadoop-aws must equal the Hadoop version compiled into Spark."
	@printf '  Hadoop in this build: '
	@$(COMPOSE) exec -T spark-worker-1 sh -c \
	  'ls /opt/spark/jars | grep -oE "^hadoop-client-api-[0-9]+\.[0-9]+\.[0-9]+" | head -1 | sed "s/hadoop-client-api-//"' \
	  2>/dev/null | grep . || echo "could not read it from the jar names"
	@echo "  (a mismatch surfaces as NoSuchMethodError from deep in the stack,"
	@echo "   naming neither S3 nor versions)"

spark-shell: ## interactive PySpark on the cluster
	@$(COMPOSE) exec -it spark-master /opt/spark/bin/pyspark \
	  --master spark://spark-master:7077

spark-logs: ## follow the master and the workers
	$(COMPOSE) logs -f spark-master $(WORKERS)

spark-metrics: ## is Prometheus scraping Spark
	@printf 'spark-master targets (expect 1): '
	@curl -fsS "$(PROM)/api/v1/targets?state=active" 2>/dev/null \
	  | grep -o '"job": *"spark-master"' | wc -l | tr -d ' '
	@printf 'spark-worker targets (expect 4): '
	@curl -fsS "$(PROM)/api/v1/targets?state=active" 2>/dev/null \
	  | grep -o '"job": *"spark-worker"' | wc -l | tr -d ' '
	@printf 'spark metric series:            '
	@curl -fsS --get --data-urlencode 'query=count({__name__=~"metrics_.*"})' \
	  "$(PROM)/api/v1/query" 2>/dev/null \
	  | grep -o '"[0-9]*"\]' | head -1 | tr -d '"]' | grep . || echo "none yet"

# --- inspection -------------------------------------------------------------

ps: ## container status
	$(COMPOSE) ps

logs: ## follow every service
	$(COMPOSE) logs -f

smoke: ## assert the cluster is usable, not merely running
	@./scripts/smoke.sh

test: config smoke ## validate the configuration, then the running stack

config: check-env ## validate the compose file and the includes
	@$(COMPOSE) config -q && echo "compose file is valid, all variables resolved"
