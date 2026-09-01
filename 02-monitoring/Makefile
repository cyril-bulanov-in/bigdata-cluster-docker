# Short entry points for the monitoring stack.
#
# This stack includes 01-kafka, so `make up` here starts Kafka as well.
# You do not need to start 01-kafka separately.
#
#   make        - list the available commands
#   make up     - start Kafka, the exporters, Prometheus and Grafana
#   make test   - lint the configs and check that metrics are really collected
#   make down   - stop everything, keep the data
#   make clean  - stop everything and wipe the volumes

COMPOSE := docker compose

# ----------------------------------------------------------------------------
#  Reading .env from inside make
# ----------------------------------------------------------------------------
#  Compose reads .env by itself, but make does not: a recipe runs in a plain
#  shell where none of those variables exist. Writing $${GRAFANA_ADMIN_PASSWORD}
#  in a recipe therefore always expands to nothing, and any :- default silently
#  wins — which is how `make dashboards` once sent admin:admin to a Grafana with
#  a different password and got a 401.
#
#  So the values are pulled out of the files here, at parse time.
#  `cut -d= -f2-` keeps everything after the first = , so a password
#  containing = survives.
# ----------------------------------------------------------------------------
ENV       := .env
KAFKA_ENV := ../01-kafka/.env

# $(call getenv,VARNAME,FILE)
getenv = $(shell grep -E '^$(1)=' $(2) 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"')

PROM_PORT   := $(or $(call getenv,PROMETHEUS_PORT,$(ENV)),9090)
GRAF_PORT   := $(or $(call getenv,GRAFANA_PORT,$(ENV)),3000)
CADV_PORT   := $(or $(call getenv,CADVISOR_PORT,$(ENV)),8082)
KAFBAT_PORT := $(or $(call getenv,KAFBAT_PORT,$(KAFKA_ENV)),8080)
GRAF_USER   := $(or $(call getenv,GRAFANA_ADMIN_USER,$(ENV)),admin)
GRAF_PASS   := $(or $(call getenv,GRAFANA_ADMIN_PASSWORD,$(ENV)),admin)

PROM := http://localhost:$(PROM_PORT)
GRAF := http://localhost:$(GRAF_PORT)
GRAF_AUTH := -u "$(GRAF_USER):$(GRAF_PASS)"

.DEFAULT_GOAL := help
.PHONY: help check-env up down restart clean ps logs config smoke test targets \
        kafka-metrics host-metrics container-metrics lag rules alerts \
        datasource dashboards reload urls drill-down drill-up

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# --- guard ------------------------------------------------------------------

# These files must exist before anything starts. Without the check, Compose
# substitutes empty strings for every variable and fails later with a message
# that points at Docker rather than at the missing file.
check-env:
	@test -f $(ENV) || { \
	  echo ""; \
	  echo "ERROR: .env is missing in $$(pwd)"; \
	  ls -a | grep -qx 'env' && echo "       There is a file called 'env' here. Compose needs '.env' — rename it:  mv env .env"; \
	  echo "       Otherwise create it:  cp .env.example .env"; \
	  echo ""; \
	  exit 1; }
	@test -f $(KAFKA_ENV) || { \
	  echo ""; \
	  echo "ERROR: ../01-kafka/.env is missing"; \
	  echo "       This stack includes 01-kafka, which reads its own .env."; \
	  echo "       Create it:  cp ../01-kafka/.env.example ../01-kafka/.env"; \
	  echo ""; \
	  exit 1; }
	@test -f prometheus/prometheus.yml || { \
	  echo ""; \
	  echo "ERROR: prometheus/prometheus.yml is missing"; \
	  echo "       Compose mounts that path as a file. If it does not exist,"; \
	  echo "       Docker creates a directory with the same name and Prometheus"; \
	  echo "       fails with 'is a directory'."; \
	  echo ""; \
	  exit 1; }
	@test -f prometheus/rules/alerts.yml || { \
	  echo ""; \
	  echo "ERROR: prometheus/rules/alerts.yml is missing"; \
	  echo "       Prometheus would start with no alerting rules at all, which"; \
	  echo "       looks like everything is fine."; \
	  echo ""; \
	  exit 1; }
	@test -f grafana/provisioning/dashboards/platform-overview.json || { \
	  echo ""; \
	  echo "ERROR: grafana/provisioning/dashboards/platform-overview.json is missing"; \
	  echo "       Grafana would start with an empty Platform folder."; \
	  echo ""; \
	  exit 1; }

# --- lifecycle --------------------------------------------------------------

up: check-env ## start Kafka, the exporters, Prometheus and Grafana
	$(COMPOSE) up -d --build
	@$(MAKE) --no-print-directory urls

down: ## stop the containers, keep the data
	$(COMPOSE) down

restart: ## restart the containers
	$(COMPOSE) restart

clean: ## stop the containers and delete all volumes, Kafka data included
	$(COMPOSE) down -v

urls: ## print the web interfaces
	@echo ""
	@echo "  Grafana     $(GRAF)   (login: $(GRAF_USER))"
	@echo "  Dashboard   $(GRAF)/d/platform-overview"
	@echo "  Prometheus  $(PROM)"
	@echo "  Alerts      $(PROM)/alerts"
	@echo "  cAdvisor    http://localhost:$(CADV_PORT)"
	@echo "  Kafbat UI   http://localhost:$(KAFBAT_PORT)"
	@echo ""

# --- checks -----------------------------------------------------------------

config: check-env ## validate the compose file, prometheus.yml, rules and the dashboard
	@$(COMPOSE) config -q && echo "compose file is valid, all variables resolved"
	@$(COMPOSE) run --rm --no-deps --entrypoint promtool prometheus check config /etc/prometheus/prometheus.yml
	@python3 -c "import json; json.load(open('grafana/provisioning/dashboards/platform-overview.json')); print('dashboard JSON is valid')" \
	  || echo "dashboard JSON is NOT valid — Grafana will silently skip it"

smoke: ## assert the running stack is really collecting metrics
	@./scripts/smoke.sh

test: config smoke ## validate the configs, then check the running stack

# --- inspection -------------------------------------------------------------

ps: ## container status
	$(COMPOSE) ps

logs: ## follow the logs of every service (Ctrl+C to exit)
	$(COMPOSE) logs -f

targets: ## which scrape targets Prometheus considers healthy
	@curl -fsS "$(PROM)/api/v1/targets?state=active" \
	  | tr ',' '\n' | grep -E '"(job|health)"' | paste - - | sed 's/"//g'

rules: ## every alerting rule Prometheus has loaded, with its state
	@curl -fsS "$(PROM)/api/v1/rules" | tr ',' '\n' | grep -E '"(name|state)"' | sed 's/"//g'

alerts: ## alerts currently pending or firing
	@curl -fsS "$(PROM)/api/v1/alerts" \
	  | tr ',' '\n' | grep -E '"(alertname|state|severity)"' | sed 's/[]["]//g'
	@echo "(nothing above means no alert is pending or firing)"

kafka-metrics: ## how many brokers are reporting, and their controller count
	@echo "brokers exporting JMX metrics (expect 4):"
	@curl -fsS --get --data-urlencode 'query=count(kafka_server_brokerstate)' \
	  "$(PROM)/api/v1/query" | grep -o '"[0-9]*"]' | tr -d '"]'
	@echo "active controllers (expect 1):"
	@curl -fsS --get --data-urlencode 'query=sum(kafka_controller_kafkacontroller_activecontrollercount)' \
	  "$(PROM)/api/v1/query" | grep -o '"[0-9]*"]' | tr -d '"]'

host-metrics: ## CPU cores, memory and load as node-exporter sees the machine
	@echo "CPU cores visible to the host:"
	@curl -fsS --get --data-urlencode 'query=count(count by (cpu) (node_cpu_seconds_total))' \
	  "$(PROM)/api/v1/query" | grep -o '"[0-9.]*"]' | tr -d '"]'
	@echo "total memory, GiB:"
	@curl -fsS --get --data-urlencode 'query=node_memory_MemTotal_bytes/1024/1024/1024' \
	  "$(PROM)/api/v1/query" | grep -o '"[0-9.]*"]' | tr -d '"]'
	@echo "load average, 1 min:"
	@curl -fsS --get --data-urlencode 'query=node_load1' \
	  "$(PROM)/api/v1/query" | grep -o '"[0-9.]*"]' | tr -d '"]'

container-metrics: ## how many containers cAdvisor sees
	@echo "containers reporting to cAdvisor:"
	@curl -fsS --get --data-urlencode 'query=count(container_last_seen{name!=""})' \
	  "$(PROM)/api/v1/query" | grep -o '"[0-9]*"]' | tr -d '"]'

lag: ## topics seen by the lag exporter, and lag per consumer group
	@echo "topics known to the exporter:"
	@curl -fsS --get --data-urlencode 'query=count(kafka_topic_partitions)' \
	  "$(PROM)/api/v1/query" | grep -o '"[0-9]*"]' | tr -d '"]'
	@echo "consumer groups with lag (empty until a consumer runs):"
	@curl -fsS --get --data-urlencode 'query=sum by (consumergroup) (kafka_consumergroup_lag)' \
	  "$(PROM)/api/v1/query" | tr ',' '\n' | grep -E 'consumergroup' | sed 's/[{}"]//g' || true

datasource: ## did Grafana pick up the provisioned Prometheus connection
	@curl -fsS $(GRAF_AUTH) "$(GRAF)/api/datasources" \
	  | tr ',' '\n' | grep -E '"(name|type|url)"' | sed 's/"//g' \
	  || echo "request failed — check GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD in .env"

dashboards: ## which dashboards Grafana has loaded from files
	@curl -fsS $(GRAF_AUTH) "$(GRAF)/api/search?type=dash-db" \
	  | tr ',' '\n' | grep -E '"(title|uid|folderTitle)"' | sed 's/"//g' \
	  || echo "request failed — check GRAFANA_ADMIN_USER / GRAFANA_ADMIN_PASSWORD in .env"
	@echo "(open it at $(GRAF)/d/platform-overview)"

reload: ## re-read prometheus.yml and the rules without restarting
	@curl -fsS -X POST "$(PROM)/-/reload" && echo "prometheus config and rules reloaded"

# --- failure drill ----------------------------------------------------------

drill-down: ## stop a broker and watch the alerts arrive
	docker stop kafka-2
	@echo ""
	@echo "What to expect, in order:"
	@echo "  ~30s   make targets   kafka-jmx / jmx-kafka-2 turns down"
	@echo "  ~1m    make alerts    TargetDown is firing"
	@echo "  ~2m    make alerts    KafkaUnderReplicatedPartitions joins it"
	@echo "         KafkaControllerCountWrong stays quiet: the quorum re-elected"
	@echo "  Grafana: 'Brokers up' drops to 3, 'Under-replicated' turns red"
	@echo ""
	@echo "Undo with: make drill-up"

drill-up: ## start the broker again
	docker start kafka-2
	@echo "kafka-2 is back. Alerts clear once the replicas catch up."
