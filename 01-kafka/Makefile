# Short entry points for the stack in this directory.
#   make        - list the available commands
#   make up     - start the cluster
#   make test   - lint the compose file and run the smoke test against it
#   make down   - stop it, keep the data
#   make clean  - stop it and wipe the data

# The compose file has the default name, so docker finds it on its own —
# no -f flag anywhere.
COMPOSE := docker compose
BOOTSTRAP := kafka-1:9092,kafka-2:9092,kafka-3:9092,kafka-4:9092

.DEFAULT_GOAL := help
.PHONY: help up down restart clean ps logs health topics describe quorum produce consume lint smoke test

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

# --- lifecycle --------------------------------------------------------------

up: ## start the cluster in the background
	$(COMPOSE) up -d
	@echo ""
	@echo "Kafbat UI: http://localhost:$${KAFBAT_PORT:-8080}"

down: ## stop the containers, keep the data
	$(COMPOSE) down

restart: ## restart the containers
	$(COMPOSE) restart

clean: ## stop the containers and delete the broker volumes
	$(COMPOSE) down -v

# --- checks -----------------------------------------------------------------

lint: ## validate the compose file and resolve every ${VAR}
	@test -f .env || { echo "ERROR: .env is missing. Run: cp .env.example .env"; exit 1; }
	@$(COMPOSE) config -q && echo "compose file is valid, all variables resolved"

smoke: ## assert the running cluster is actually correct (see scripts/smoke.sh)
	@./scripts/smoke.sh

test: lint smoke ## lint, then smoke-test the running cluster

# --- inspection -------------------------------------------------------------

ps: ## container status
	$(COMPOSE) ps

logs: ## follow the logs of every service (Ctrl+C to exit)
	$(COMPOSE) logs -f

health: ## cluster membership as Kafka itself sees it
	$(COMPOSE) exec kafka-1 /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server $(BOOTSTRAP) | head -20

topics: ## list topics
	$(COMPOSE) exec kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server $(BOOTSTRAP) --list

describe: ## demo topic detail: leaders, replicas, ISR
	$(COMPOSE) exec kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server $(BOOTSTRAP) --describe --topic demo.events

quorum: ## controller quorum: who votes, who only observes
	$(COMPOSE) exec kafka-1 /opt/kafka/bin/kafka-metadata-quorum.sh --bootstrap-server $(BOOTSTRAP) describe --replication

# --- hands on ---------------------------------------------------------------

produce: ## write to demo.events interactively (Ctrl+C to exit)
	$(COMPOSE) exec -it kafka-1 /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $(BOOTSTRAP) --topic demo.events

consume: ## read demo.events from the beginning (Ctrl+C to exit)
	$(COMPOSE) exec -it kafka-1 /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $(BOOTSTRAP) --topic demo.events --from-beginning
