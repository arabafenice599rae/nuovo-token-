# Toolchain pinnata: allineare a .github/workflows/ci.yml e docs/static-analysis.md
FOUNDRY_VERSION ?= 1.8.1
SLITHER_VERSION ?= 0.11.6
ADERYN_VERSION  ?= 0.6.8

REPORTS_DIR ?= reports

.DEFAULT_GOAL := help

.PHONY: help
help: ## Mostra i target disponibili
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-16s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install: ## Scarica le dipendenze pinnate in lib/ (+ solmate dentro v4-core)
	git submodule update --init lib/forge-std lib/v4-core lib/v4-periphery lib/permit2 lib/openzeppelin-contracts
	git -C lib/v4-core submodule update --init lib/solmate

.PHONY: deps-check
deps-check: ## Verifica che le dipendenze siano ai commit pinnati
	./tools/check-deps.sh

.PHONY: build
build: ## Compila i contratti (solc pinnato in foundry.toml)
	forge build --sizes

.PHONY: test
test: ## Esegue i test
	forge test -vvv

.PHONY: test-ci
test-ci: ## Esegue i test con il profilo CI (fuzzing esteso)
	FOUNDRY_PROFILE=ci forge test -vvv

.PHONY: snapshot
snapshot: ## Aggiorna lo snapshot del gas
	forge snapshot

.PHONY: fmt
fmt: ## Formatta il codice Solidity
	forge fmt

.PHONY: fmt-check
fmt-check: ## Verifica la formattazione senza modificare i file
	forge fmt --check

.PHONY: lint
lint: ## Esegue il linter di forge
	forge lint

.PHONY: slither
slither: $(REPORTS_DIR) ## Analisi statica con Slither (config: slither.config.json)
	slither . --checklist --markdown-root . > $(REPORTS_DIR)/slither-report.md || true
	slither .

.PHONY: aderyn
aderyn: $(REPORTS_DIR) ## Analisi statica con Aderyn (config: aderyn.toml)
	aderyn --output $(REPORTS_DIR)/aderyn-report.md
	aderyn --output $(REPORTS_DIR)/aderyn-report.json
	./tools/aderyn-gate.sh $(REPORTS_DIR)/aderyn-report.json

.PHONY: analyze
analyze: build slither aderyn ## Esegue tutta la static analysis

.PHONY: ci
ci: fmt-check build test-ci analyze ## Riproduce in locale la pipeline di CI

.PHONY: versions
versions: ## Stampa le versioni dei tool installati
	@forge --version
	@slither --version
	@aderyn --version

.PHONY: clean
clean: ## Rimuove artefatti di build e report
	forge clean
	rm -rf $(REPORTS_DIR) crytic-export

$(REPORTS_DIR):
	@mkdir -p $(REPORTS_DIR)
