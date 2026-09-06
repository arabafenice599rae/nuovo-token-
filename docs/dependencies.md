# Dependencies

Every dependency lives in `lib/` as a git submodule pinned to an exact commit —
no floating tags, no "latest".

| Path | Repo | Commit |
| --- | --- | --- |
| `lib/v4-core` | Uniswap/v4-core | `59d3ecf53afa9264a16bba0e38f4c5d2231f80bc` (v1.0.2) |
| `lib/v4-periphery` | Uniswap/v4-periphery | `ad04c9f24a170accf5ea1b2836bbafd514537ca6` (v1.0.2) |
| `lib/permit2` | Uniswap/permit2 | `cc56ad0f3439c502c246fc5cfcc3db92bb8b7219` |
| `lib/openzeppelin-contracts` | OpenZeppelin/openzeppelin-contracts | `21c8312b022f495ebe3621d5daeed20552b43ff9` |
| `lib/forge-std` | foundry-rs/forge-std | `3b20d60d14b343ee4f908cb8079495c07f5e8981` (1.9.6) |
| `lib/v4-core/lib/solmate` | transmissions11/solmate | `4b47a19038b798b4a33d9749d25e570443520647` |

`solmate` sits **inside** `lib/v4-core/lib/` because that is where v4-core's own
imports look for it (`solmate/=lib/solmate/` in its `remappings.txt`). It is
v4-core's submodule, not the project's: v4-core pins it at exactly `4b47a19`,
the same commit used here.

## Install and verify

```bash
make install      # top-level submodules + solmate inside v4-core
make deps-check   # asserts every dependency sits at its pinned commit
```

`make install` does not use `--recursive`: a recursive checkout would also pull
nested dependencies that are never used (forge-std and openzeppelin inside
v4-core, permit2's own submodules, a second copy of v4-core inside
v4-periphery).

## Remappings

`remappings.txt` maps the prefixes used by the project's contracts and by the
dependencies themselves:

```
forge-std/=lib/forge-std/src/
@openzeppelin/=lib/openzeppelin-contracts/
@openzeppelin/contracts/=lib/openzeppelin-contracts/contracts/
openzeppelin-contracts/contracts/=lib/openzeppelin-contracts/contracts/
solmate/=lib/v4-core/lib/solmate/
permit2/=lib/permit2/
@uniswap/v4-core/=lib/v4-core/
@uniswap/v4-periphery/=lib/v4-periphery/
v4-core/=lib/v4-core/src/
v4-periphery/=lib/v4-periphery/src/
```

Two notes:

- v4-periphery imports both `@openzeppelin/contracts/...` and
  `openzeppelin-contracts/contracts/...`: both prefixes point at the same clone
  in `lib/openzeppelin-contracts`.
- `@openzeppelin/=lib/openzeppelin-contracts/` overrides the remapping forge
  auto-detects from v4-core's own `remappings.txt`
  (`@openzeppelin/=lib/v4-core/lib/openzeppelin-contracts/`), which would point
  at a directory that is never initialised. Check the result with
  `forge remappings`.

`test/Dependencies.t.sol` is the smoke test that keeps the remappings honest: it
imports v4-core, v4-periphery, permit2 and OpenZeppelin, and deploys
`PoolManager` under the project's compiler profile.

## Updating a dependency

```bash
git -C lib/<dep> fetch origin
git -C lib/<dep> checkout <new-commit>
git add lib/<dep>
# update the table above and, for solmate, tools/check-deps.sh as well
make build test analyze
```

Dependencies are deliberately excluded from static analysis (`filter_paths` in
`slither.config.json`, `exclude` in `aderyn.toml`): the analysis targets this
project's code, not third-party code. Compiler warnings coming from `lib/` do
not fail the build (`ignored_warnings_from` in `foundry.toml`); warnings from
the project's own code do.
