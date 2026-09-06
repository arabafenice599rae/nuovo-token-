# nuovo-token-

Progetto Foundry con analisi statica (Slither + Aderyn) configurata e integrata
in CI.

## Requisiti

- [Foundry](https://getfoundry.sh) 1.8.1 (solc 0.8.26, scaricata da `forge`)
- Python 3 con [Slither](https://github.com/crytic/slither) 0.11.6 e crytic-compile
- [Aderyn](https://github.com/Cyfrin/aderyn) 0.6.8

Comandi di installazione in [docs/static-analysis.md](docs/static-analysis.md).

## Uso

```bash
make install     # git submodules (lib/forge-std)
make build       # forge build --sizes
make test        # forge test -vvv
make analyze     # build + slither + aderyn
make ci          # riproduce in locale la pipeline di CI
make help        # elenco completo dei target
```

## Struttura

```
src/            contratti
test/           test Foundry
script/         script di deploy
tools/          gate per la CI (aderyn-gate.sh)
docs/           documentazione (setup e triage della static analysis)
foundry.toml    profili di compilazione (default / ci / lite)
slither.config.json, aderyn.toml   configurazione dell'analisi statica
```

`src/Counter.sol` e' lo scaffold generato da `forge init`: e' un segnaposto che
serve solo a tenere verde la pipeline finche' non arriva il contratto del token.

## CI

`.github/workflows/ci.yml` esegue tre job su ogni push e pull request:

- **Build & test** — `forge fmt --check`, `forge build --sizes`, test con profilo `ci`
- **Slither** — fallisce dai finding di impatto medium in su
- **Aderyn** — fallisce sui finding High, report pubblicato come artifact
