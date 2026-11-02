SHELL := /usr/bin/env bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

COMPOSE := docker compose
# Every profile, so down/clean also remove clients and observability.
COMPOSE_ALL := $(COMPOSE) --profile '*'
SCRIPTS := $(wildcard scripts/*.sh) docker/ceph/entrypoint.sh

.PHONY: help preflight up up-observability down clean status shell logs \
        demo demo-object demo-block demo-file demo-failure demo-placement lint

help: ## Show this help
	@awk 'BEGIN {FS = ":.*## "} /^[a-z-]+:.*## / {printf "  \033[1m%-18s\033[0m %s\n", $$1, $$2}' $(MAKEFILE_LIST)

preflight: ## Check Docker memory/CPU/arch, disk, ports and subnet
	@scripts/preflight.sh

up: preflight ## Start the cluster (bootstrap on first run) and print endpoints
	$(COMPOSE) up -d --wait
	@scripts/status.sh --summary

up-observability: ## Start the cluster plus Prometheus + Grafana
	@CHECK_OBSERVABILITY=1 scripts/preflight.sh
	$(COMPOSE) --profile observability up -d --wait
	@scripts/status.sh --summary

down: ## Stop all containers (data is kept)
	$(COMPOSE_ALL) down

clean: ## Stop everything and DELETE all cluster data and generated secrets
	$(COMPOSE_ALL) down -v --remove-orphans

status: ## ceph -s, OSD tree, pools, containers, endpoints
	@scripts/status.sh

shell: ## Bash shell with the ceph CLI and admin keyring (inside mon-a)
	$(COMPOSE) exec mon-a bash

logs: ## Follow logs (all, or one service: make logs S=osd-0)
	$(COMPOSE_ALL) logs -f --tail=100 $(S)

demo: ## Run every demo in order
	@scripts/demo.sh

demo-object: ## RGW: S3 user, bucket, upload/download, checksum
	@scripts/demo-object.sh

demo-block: ## RBD: image, rbd-nbd filesystem, snapshot + rollback
	@scripts/demo-block.sh

demo-file: ## CephFS: create filesystem, two ceph-fuse clients share data
	@scripts/demo-file.sh

demo-failure: ## Stop an OSD, watch degraded I/O, recover to HEALTH_OK
	@scripts/demo-failure.sh

demo-placement: ## CRUSH: which PG and OSDs hold an object
	@scripts/demo-placement.sh

lint: ## shellcheck all scripts + validate compose
	shellcheck -x $(SCRIPTS)
	$(COMPOSE) config -q
	$(COMPOSE) --profile '*' config -q
