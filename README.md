# nuovo-token-

`FixedSaleV4`: vendita a prezzo fisso di un ERC-20 con migrazione permissionless
della liquidita' su Uniswap v4 (posizione bounded mintata via PositionManager,
raccolta perpetua delle swap fee). Nessun owner, nessun admin, nessun upgrade.

Progetto Foundry con analisi statica (Slither + Aderyn) integrata in CI.

## Requisiti

- [Foundry](https://getfoundry.sh) 1.8.1 (solc 0.8.26, scaricata da `forge`)
- Python 3 con [Slither](https://github.com/crytic/slither) 0.11.6 e crytic-compile
- [Aderyn](https://github.com/Cyfrin/aderyn) 0.6.8

Comandi di installazione in [docs/static-analysis.md](docs/static-analysis.md).

## Dipendenze

Uniswap v4 (core + periphery), Permit2, OpenZeppelin, forge-std e solmate sono
submodule in `lib/`, pinnati a commit esatti: vedi
[docs/dependencies.md](docs/dependencies.md).

```bash
make install     # inizializza i submodule ai commit pinnati
make deps-check  # verifica i pin
```

## Uso

```bash
make install     # dipendenze pinnate in lib/
make build       # forge build --sizes
make test        # forge test -vvv
make analyze     # build + slither + aderyn
make test-nightly # fuzzing esteso (profilo ci, 20k run)
make ci          # riproduce in locale la pipeline di CI
make help        # elenco completo dei target
```

## Struttura

```
src/            contratti (FixedSaleV4.sol)
test/           test Foundry
lib/            dipendenze (submodule pinnati)
tools/          script per la CI (aderyn-gate.sh, check-deps.sh)
docs/           documentazione (dipendenze, static analysis, findings)
foundry.toml    profili di compilazione (default / ci / lite)
remappings.txt  remapping degli import verso lib/
slither.config.json, aderyn.toml   configurazione dell'analisi statica
```

## Contratti

- `src/FixedSaleV4.sol` — `LaunchToken` (ERC-20 + burn, nessuna tax, nessun mint
  post-deploy) e `FixedSaleV4` (vendita, migrazione, claim/refund, fee).

Il triage completo dei finding di analisi statica, con le soppressioni attive e
i loro motivi, e' in [docs/findings.md](docs/findings.md).

Il contratto viene compilato **con via-ir** (`foundry.toml`), per parita' con il
bytecode verificato; il profilo `lite` disattiva via-ir per le iterazioni veloci.

## CI

`.github/workflows/ci.yml` esegue tre job su ogni push e pull request:

- **Build & test** — `forge fmt --check`, `forge build --sizes`, `forge test` (profilo default: 2k run di fuzzing, invarianti 1000 x depth 150)
- **Slither** — fallisce dai finding di impatto medium in su
- **Aderyn** — fallisce sui finding High, report pubblicato come artifact

`.github/workflows/nightly.yml` gira ogni notte alle 03:00 UTC (o a mano da
Actions) con il profilo `ci`: 20.000 run di fuzzing. In locale: `make test-nightly`.
