# Static analysis

Questo progetto usa tre tool, tutti eseguibili in locale con gli stessi comandi
usati in CI (`.github/workflows/ci.yml`):

| Tool | Versione | Config | Comando |
| --- | --- | --- | --- |
| Foundry (forge/cast/anvil) | 1.8.1 (solc 0.8.26) | `foundry.toml` | `make build`, `make test` |
| Slither | 0.11.6 | `slither.config.json` | `make slither` |
| Aderyn | 0.6.8 | `aderyn.toml` | `make aderyn` |

`make analyze` esegue build + Slither + Aderyn; `make ci` riproduce l'intera
pipeline di CI (formattazione, build, test con profilo `ci`, analisi).

## Installazione

```bash
# Foundry (forge/cast/anvil) — usato: 1.8.1, solc 0.8.26 scaricato da forge
curl -L https://foundry.paradigm.xyz | bash
foundryup --install 1.8.1

# Python per analisi statica
pipx install slither-analyzer          # o pip install
pipx install crytic-compile

# Aderyn: il crate su crates.io e' fermo alla 0.1.9, quindi si usa il binario
# di release (oppure `cargo install --git https://github.com/Cyfrin/aderyn --tag aderyn-v0.6.8`)
curl -fsSL https://github.com/Cyfrin/aderyn/releases/download/aderyn-v0.6.8/aderyn-x86_64-unknown-linux-gnu.tar.xz -o /tmp/aderyn.tar.xz
tar -xJf /tmp/aderyn.tar.xz -C /tmp
sudo install -m 0755 /tmp/aderyn-x86_64-unknown-linux-gnu/aderyn /usr/local/bin/aderyn
```

Verifica: `make versions`.

## Come sono configurati i tool

### Foundry (`foundry.toml`)

- `solc = "0.8.26"` ed `evm_version = "cancun"`: versione fissata, niente
  compilazione con una solc diversa tra sviluppatore e CI.
- `ast = true`, `build_info = true`: Slither e Aderyn leggono gli artefatti
  prodotti da `forge build`; senza AST e build-info non riescono a mappare i
  finding sul sorgente.
- `deny = "warnings"`: i warning di compilatore e linter fanno fallire la build.
  Il profilo `lite` (`FOUNDRY_PROFILE=lite forge build`) li tollera per le
  iterazioni veloci in locale, ma non va usato per l'analisi.
- `bytecode_hash = "none"` e `cbor_metadata = false`: bytecode riproducibile.
- Profilo `ci`: fuzzing a 10.000 run e invarianti a 1.000 run / depth 64.

### Slither (`slither.config.json`)

- `filter_paths: "^(lib|test|script)/"` e `exclude_dependencies: true`: si
  analizzano solo i contratti di `src/`, non forge-std ne' i test.
- `fail_on: "medium"`: l'exit code e' diverso da zero a partire dai finding di
  impatto medium; informational e low vengono stampati ma non bloccano la CI.
- `compile_force_framework: "foundry"`: crytic-compile invoca `forge build`
  e non tenta l'autodetect di altri framework.

### Aderyn (`aderyn.toml`)

- `src = "src/"`, `exclude = ["lib/", "test/", "script/"]`: stesso scope di
  Slither.
- Aderyn esce **sempre** con codice 0, anche in presenza di finding. Il gate e'
  `tools/aderyn-gate.sh`, che legge il report JSON e fallisce se esiste almeno
  un finding di severita' High.

## Triage dei finding

1. Riprodurre in locale: `make analyze`. I report finiscono in `reports/`
   (ignorata da git): `slither-report.md`, `aderyn-report.md`,
   `aderyn-report.json`.
2. Se il finding e' reale, si corregge il contratto e si aggiunge un test di
   regressione in `test/`.
3. Se e' un falso positivo, si documenta prima di silenziarlo:
   - Slither: commento `// slither-disable-next-line <detector>` sulla riga
     interessata, con una motivazione; la disattivazione globale
     (`detectors_to_exclude` in `slither.config.json`) va usata solo per
     detector rumorosi su tutto il codebase.
   - Aderyn: `exclude` sotto `[detectors]` in `aderyn.toml`.
   In entrambi i casi la motivazione va scritta accanto all'esclusione.
4. Le esclusioni sono decisioni di sicurezza: vanno riviste in code review come
   il resto del diff.

## Limiti

Slither e Aderyn trovano pattern noti, non logica di business sbagliata. Non
sostituiscono test, invarianti (`forge test` con profilo `ci`) e review manuale.
