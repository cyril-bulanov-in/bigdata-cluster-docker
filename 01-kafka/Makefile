# Shortcuts so you do not type -f docker-compose-platform.yml every time.
#   make        - list the available commands
#   make up     - start the cluster
#   make down   - stop it, keep the data
#   make clean  - stop it and wipe the data

COMPOSE := docker compose -f docker-compose-platform.yml
BOOTSTRAP := kafka-1:9092,kafka-2:9092,kafka-3:9092,kafka-4:9092

.DEFAULT_GOAL := help
.PHONY: help up down restart clean ps logs health topics describe produce consume

help: ## show this list
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

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

produce: ## write to demo.events interactively (Ctrl+C to exit)
	$(COMPOSE) exec -it kafka-1 /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server $(BOOTSTRAP) --topic demo.events

consume: ## read demo.events from the beginning (Ctrl+C to exit)
	$(COMPOSE) exec -it kafka-1 /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server $(BOOTSTRAP) --topic demo.events --from-beginning
