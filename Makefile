# Developer shortcuts. Everything here also runs in CI (.github/workflows/ci.yml).
.PHONY: help venv lint test up down smoke tf-fmt tf-validate tf-test tf-scan diagram

PY ?= python3
VENV := .venv
BIN := $(VENV)/bin

help:  ## List targets
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | awk -F':.*## ' '{printf "  %-12s %s\n", $$1, $$2}'

venv:  ## Create .venv with runtime (hash-checked) and dev dependencies
	$(PY) -m venv $(VENV)
	$(BIN)/pip install --require-hashes -r app/requirements.txt
	$(BIN)/pip install -r app/requirements-dev.txt

lint:  ## Ruff lint + format check
	cd app && ../$(BIN)/ruff check . && ../$(BIN)/ruff format --check .

test:  ## Unit/integration tests (SQLite by default; set TEST_DATABASE_URL for PostgreSQL)
	cd app && ../$(BIN)/pytest --cov

up:  ## Build and start PostgreSQL + migrations + API on http://localhost:8000
	docker compose up --build -d --wait

down:  ## Stop the local stack and delete its volume
	docker compose down -v

smoke:  ## Smoke test the local stack
	./scripts/smoke-test.sh http://localhost:8000

tf-fmt:  ## Terraform format check
	terraform -chdir=terraform fmt -check -recursive

tf-validate:  ## Terraform validate (no backend, no credentials)
	terraform -chdir=terraform init -backend=false -input=false >/dev/null
	terraform -chdir=terraform validate
	terraform -chdir=terraform/bootstrap init -backend=false -input=false >/dev/null
	terraform -chdir=terraform/bootstrap validate

tf-test: tf-validate  ## Terraform tests with a mocked AWS provider
	terraform -chdir=terraform test

tf-scan:  ## Checkov IaC security scan
	checkov -d terraform --framework terraform --quiet --compact

diagram:  ## Regenerate the architecture SVG
	$(PY) architecture/generate_diagram.py > architecture/architecture-diagram.svg
