# Static analysis

The project uses three tools, all runnable locally with the same commands CI
uses (`.github/workflows/ci.yml`):

| Tool | Version | Config | Command |
| --- | --- | --- | --- |
| Foundry (forge/cast/anvil) | 1.8.1 (solc 0.8.26) | `foundry.toml` | `make build`, `make test` |
| Slither | 0.11.6 | `slither.config.json` | `make slither` |
| Aderyn | 0.6.8 | `aderyn.toml` | `make aderyn` |

`make analyze` runs build + Slither + Aderyn; `make ci` reproduces the whole
pull-request pipeline (formatting, build, tests, analysis); the extended fuzzing
campaign runs nightly through `make test-nightly`.

## Installation

```bash
# Foundry (forge/cast/anvil) — pinned to 1.8.1, solc 0.8.26 fetched by forge
curl -L https://foundry.paradigm.xyz | bash
foundryup --install 1.8.1

# Python tooling
pipx install slither-analyzer          # or pip install
pipx install crytic-compile

# Aderyn: the crates.io crate is stuck at 0.1.9, so use the release binary
# (or `cargo install --git https://github.com/Cyfrin/aderyn --tag aderyn-v0.6.8`)
curl -fsSL https://github.com/Cyfrin/aderyn/releases/download/aderyn-v0.6.8/aderyn-x86_64-unknown-linux-gnu.tar.xz -o /tmp/aderyn.tar.xz
tar -xJf /tmp/aderyn.tar.xz -C /tmp
sudo install -m 0755 /tmp/aderyn-x86_64-unknown-linux-gnu/aderyn /usr/local/bin/aderyn
```

Check with `make versions`.

## How the tools are configured

### Foundry (`foundry.toml`)

- `solc = "0.8.26"` and `evm_version = "cancun"`: the version is pinned, so no
  developer compiles against a different solc than CI does.
- `via_ir = true`: parity with the bytecode the contract was verified against.
- `ast = true`, `build_info = true`: Slither and Aderyn read the artifacts
  produced by `forge build`; without AST and build-info they cannot map findings
  back to source.
- `deny = "warnings"`: compiler warnings fail the build. `forge lint` does not
  gate it (`lint_on_build = false`): it runs as an informational step in CI and
  through `make lint` — reasoning in [findings.md](findings.md). The `lite`
  profile (`FOUNDRY_PROFILE=lite forge build`) tolerates warnings for fast local
  iteration, but must not be used for analysis.
- `bytecode_hash = "none"` and `cbor_metadata = false`: reproducible bytecode.
- Default profile: 2,000 fuzz runs, invariants at 1,000 runs / depth 150.
- `ci` profile: 20,000 fuzz runs for the nightly campaign
  (`.github/workflows/nightly.yml`, `make test-nightly`); invariants inherit the
  default profile's values.

### Slither (`slither.config.json`)

- `filter_paths: "^(lib|test|script)/"` and `exclude_dependencies: true`: only
  the contracts in `src/` are analysed, not forge-std and not the tests.
- `fail_on: "medium"`: a non-zero exit code from medium-impact findings upwards;
  informational and low findings are printed but do not gate CI.
- `compile_force_framework: "foundry"`: crytic-compile invokes `forge build`
  instead of trying to auto-detect another framework.

### Aderyn (`aderyn.toml`)

- `src = "src/"`, `exclude = ["lib/", "test/", "script/"]`: same scope as
  Slither.
- Aderyn **always** exits 0, findings or not. The gate is
  `tools/aderyn-gate.sh`, which reads the JSON report and fails if a single High
  finding exists.

## Triaging a finding

1. Reproduce locally with `make analyze`. Reports land in `reports/`
   (git-ignored): `slither-report.md`, `aderyn-report.md`, `aderyn-report.json`.
2. If the finding is real, fix the contract and add a regression test in
   `test/`.
3. If it is a false positive, document it before silencing it:
   - Slither: a `// slither-disable-next-line <detector>` comment on the line in
     question, with a reason; the global switch (`detectors_to_exclude` in
     `slither.config.json`) is for detectors that are noisy across the whole
     codebase.
   - Aderyn: `// aderyn-fp-next-line(<detector>)` inline, or `exclude` under
     `[detectors]` in `aderyn.toml`.
   Either way the reason goes next to the exclusion.
4. Suppressions are security decisions: they are reviewed like the rest of the
   diff, and recorded in [findings.md](findings.md) with their reasoning.

## Limits

Slither and Aderyn find known patterns, not wrong business logic. They do not
replace tests, invariants and human review.
