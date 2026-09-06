# Pinned toolchain: keep in sync with .github/workflows/ci.yml and docs/static-analysis.md
FOUNDRY_VERSION ?= 1.8.1
SLITHER_VERSION ?= 0.11.6
ADERYN_VERSION  ?= 0.6.8

REPORTS_DIR ?= reports

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show the available targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install: ## Fetch the pinned dependencies in lib/ (+ solmate inside v4-core)
	git submodule update --init lib/forge-std lib/v4-core lib/v4-periphery lib/permit2 lib/openzeppelin-contracts
	git -C lib/v4-core submodule update --init lib/solmate

.PHONY: deps-check
deps-check: ## Assert every dependency sits at its pinned commit
	./tools/check-deps.sh

.PHONY: build
build: ## Compile the contracts (solc pinned in foundry.toml)
	forge build --sizes

.PHONY: test
test: ## Run the test suite
	forge test -vvv

.PHONY: test-nightly
test-nightly: ## Nightly campaign: ci profile, 20k fuzz runs
	FOUNDRY_PROFILE=ci forge test -vvv

.PHONY: invariant
invariant: ## Run the invariants only
	forge test --match-contract Invariants -vv

.PHONY: coverage
coverage: ## Coverage summary
	forge coverage --report summary

.PHONY: snapshot
snapshot: ## Refresh the gas snapshot
	forge snapshot

.PHONY: fmt
fmt: ## Format the Solidity sources
	forge fmt

.PHONY: fmt-check
fmt-check: ## Check formatting without touching files
	forge fmt --check

.PHONY: lint
lint: ## Run forge lint (informational)
	forge lint

.PHONY: slither
slither: $(REPORTS_DIR) ## Static analysis with Slither (config: slither.config.json)
	slither . --checklist --markdown-root . > $(REPORTS_DIR)/slither-report.md || true
	slither .

.PHONY: aderyn
aderyn: $(REPORTS_DIR) ## Static analysis with Aderyn (config: aderyn.toml)
	aderyn --output $(REPORTS_DIR)/aderyn-report.md
	aderyn --output $(REPORTS_DIR)/aderyn-report.json
	./tools/aderyn-gate.sh $(REPORTS_DIR)/aderyn-report.json

.PHONY: analyze
analyze: build slither aderyn ## Run the whole static-analysis pass

.PHONY: ci
ci: fmt-check build test analyze ## Reproduce the CI pipeline locally

.PHONY: versions
versions: ## Print the installed tool versions
	@forge --version
	@slither --version
	@aderyn --version

.PHONY: clean
clean: ## Remove build artifacts and reports
	forge clean
	rm -rf $(REPORTS_DIR) crytic-export

$(REPORTS_DIR):
	@mkdir -p $(REPORTS_DIR)
