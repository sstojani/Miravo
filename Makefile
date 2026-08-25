SHELL := /bin/bash
.DEFAULT_GOAL := help

UV ?= uv
export UV_CACHE_DIR ?= $(CURDIR)/.uv-cache
export UV_LINK_MODE ?= copy
COMPOSE ?= docker compose
BACKEND_DIR := backend

.PHONY: help bootstrap format format-check lint typecheck test schema schema-check check run migrations makemigrations bootstrap-owner create-user dev-up dev-down docker-check

help:
	@awk 'BEGIN {FS = ":.*## "} /^[a-zA-Z_-]+:.*## / {printf "%-22s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

bootstrap: ## Create/update the locked Python environment
	$(UV) sync --all-groups --frozen

format: ## Format backend Python sources
	$(UV) run ruff format $(BACKEND_DIR)
	$(UV) run ruff check --fix $(BACKEND_DIR)

format-check: ## Check formatting without mutation
	$(UV) run ruff format --check $(BACKEND_DIR)

lint: ## Run Ruff and Django system checks
	$(UV) run ruff check $(BACKEND_DIR)
	cd $(BACKEND_DIR) && ../.venv/bin/python manage.py check

typecheck: ## Run practical static typing
	PROJECT_LEDGER_ENV=test PROJECT_LEDGER_DATABASE_URL=sqlite:///:memory: $(UV) run mypy $(BACKEND_DIR)/config $(BACKEND_DIR)/apps

test: ## Run backend tests with coverage
	PROJECT_LEDGER_ENV=test PROJECT_LEDGER_DATABASE_URL=sqlite:///:memory: $(UV) run pytest $(BACKEND_DIR) --cov=$(BACKEND_DIR)/apps --cov=$(BACKEND_DIR)/config --cov-report=term-missing

schema: ## Generate the committed OpenAPI schema
	cd $(BACKEND_DIR) && PROJECT_LEDGER_ENV=test PROJECT_LEDGER_DATABASE_URL=sqlite:///:memory: ../.venv/bin/python manage.py spectacular --file openapi-schema.yml --validate

schema-check: ## Fail if generated OpenAPI differs from the committed schema
	cd $(BACKEND_DIR) && PROJECT_LEDGER_ENV=test PROJECT_LEDGER_DATABASE_URL=sqlite:///:memory: ../.venv/bin/python manage.py spectacular --file /tmp/project-ledger-openapi.yml --validate
	diff -u $(BACKEND_DIR)/openapi-schema.yml /tmp/project-ledger-openapi.yml

check: format-check lint typecheck test schema-check ## Run all locally available backend checks

run: ## Run the local ASGI development server
	cd $(BACKEND_DIR) && ../.venv/bin/python manage.py runserver 127.0.0.1:8000

migrations: ## Apply database migrations
	cd $(BACKEND_DIR) && ../.venv/bin/python manage.py migrate

makemigrations: ## Generate migrations for changed models
	cd $(BACKEND_DIR) && ../.venv/bin/python manage.py makemigrations

bootstrap-owner: ## Create the first owner interactively or from one-time env values
	cd $(BACKEND_DIR) && ../.venv/bin/python manage.py bootstrap_owner

create-user: ## Create a normal non-admin app user interactively or from env values
	cd $(BACKEND_DIR) && ../.venv/bin/python manage.py create_app_user

dev-up: ## Start the development Compose stack
	$(COMPOSE) -f infra/compose.yml -f infra/compose.dev.yml up --build -d

dev-down: ## Stop the development Compose stack
	$(COMPOSE) -f infra/compose.yml -f infra/compose.dev.yml down

docker-check: ## Run backend checks inside the API image
	$(COMPOSE) -f infra/compose.yml -f infra/compose.dev.yml run --rm api make check
