# Static-analysis triage — FixedSaleV4

Analysis run on `src/FixedSaleV4.sol` with the repository's pinned toolchain
(forge 1.8.1 / solc 0.8.26 via-ir, slither 0.11.6, aderyn 0.6.8) against the
dependencies in `lib/` (v4-core 59d3ecf, v4-periphery ad04c9f, permit2 cc56ad0,
OpenZeppelin 21c8312).

Gate status after triage: **slither 0 findings at medium or above**, **aderyn 0
High**. Everything else is listed below rather than hidden.

## Active suppressions

Each suppression is either surgical (inline in the source) or justified at
config level. No logic was changed: the bytecode of `FixedSaleV4` compiled with
and without the added comment lines is **identical** (verified with
`forge inspect ... bytecode | sha256sum`).

| Finding | Tool | Severity | Where | Why it is a false positive | Suppressed in |
| --- | --- | --- | --- | --- | --- |
| `unchecked-transfer` (×3) | slither | High | `finalize`, `unlockCallback`, `claim` | `token` is `LaunchToken`, an OZ `ERC20` created by this contract: it reverts on failure and never returns `false` | inline `slither-disable-next-line` |
| `incorrect-equality` | slither | Medium | `sweepDust` (`dust == 0`) | strict equality on a balance used only to revert (`NoDust`), it drives no arithmetic | inline `slither-disable-next-line` |
| `unused-return` (×6) | slither | Medium | `initialize`, `getSlot0` (×3), `settle` (×2) | partial destructuring of `getSlot0` and return values of the v4 glue (`initialize` → tick, `settle` → amount paid). The deltas are checked by the PoolManager when the unlock closes anyway | `detectors_to_exclude` in `slither.config.json` |
| `unsafe-casting` (×2) | aderyn | High | `finalize`, `MINT_POSITION` parameters (`uint128(ethAvail)`, `uint128(tokenAvail)`) | `tokenAvail <= MAX_TOTAL_SUPPLY` (1e27) and `ethAvail <= ETH raised`: both orders of magnitude below 2^128 (~3.4e38) | inline `aderyn-fp-next-line` |
| `eth-send-unchecked-address` (×5) | aderyn | High | `buy`, `finalize`, `refund`, `withdrawFees`, `sweepDust` | recipients are `msg.sender` (pull payments) or `feeRecipient`, immutable and checked `!= address(0)` in the constructor | `[detectors] exclude` in `aderyn.toml` |
| `reentrancy-state-change` (×5) | aderyn | High | constructor, `finalize` | every external entrypoint is `nonReentrant` and `finalized` is written before the interactions (CEI) | `[detectors] exclude` in `aderyn.toml` |

The two global exclusions in `aderyn.toml` come at a cost: **they assume every
new external function stays `nonReentrant` and every new ETH recipient is
validated**. If the contract grows, they must be revisited (or converted into
inline suppressions).

## Open findings (non-blocking)

None of these fail the pipeline; they are listed because they stay visible on
every run.

| Finding | Tool | Severity | Verdict |
| --- | --- | --- | --- |
| `reentrancy-benign` in `finalize` (`bootstrapTokenId`/`bootstrapLiquidity` written after `modifyLiquidities`) | slither | Low | accepted: `finalized = true` is already written and the function is `nonReentrant` |
| `reentrancy-events` in `unlockCallback` (`Normalized` emitted after the calls) | slither | Low | accepted: the callback is only reachable from the PoolManager inside the unlock opened by `finalize` |
| `timestamp` (×3) in `buy`, `finalize`, `refund` | slither | Low | intrinsic to a timed sale; the windows (deadline, `FINALIZE_GRACE` = 3 days) are orders of magnitude above what a validator can shift |
| `low-level-calls` (×5) | slither | Info | necessary: ETH transfers via `call` with an explicit success check |
| `pragma` / `unspecific-solidity-pragma` | slither / aderyn | Info / Low | `^0.8.26` in the source against `solc = "0.8.26"` pinned in `foundry.toml`: the effective version is fixed by the project. A pinned pragma would still be preferable |
| `unchecked-return`, `unsafe-erc20-operation` | aderyn | Low | same cause as `unchecked-transfer` above: `LaunchToken` reverts |
| `push-zero-opcode` | aderyn | Low | the target is `evm_version = "cancun"`: PUSH0 is supported |
| `large-numeric-literal`, `literal-instead-of-constant`, `state-change-without-event` | aderyn | Low | style |

## forge lint

`forge lint` does not gate the build (`lint_on_build = false`): it runs as an
informational step in CI and through `make lint`. On the contract it produces 53
warnings and 25 notes, largely the same patterns already triaged above
(`unsafe-typecast` ×23 on the v4 delta casts, `reentrancy-*` ×19,
`block-timestamp` ×4, `erc20-unchecked-transfer` ×3, `unused-return` ×3) plus
style notes (`screaming-snake-case-immutable`, `low-level-calls`,
`multi-contract-file`).

One case is a linter false positive and worth knowing about:
`divide-before-multiply` on `uint256 fee = (spend * FEE_BPS) / BPS` — the
multiplication already precedes the division there.

Making the linter blocking is a one-line change in `foundry.toml`
(`lint_on_build = true`) once those warnings have been triaged with
`// forge-lint: disable-next-line(<rule>)`.

## Note on the source

Only two changes were made to the source as delivered, both non-semantic:

1. the comment lines carrying the triage markers (`slither-disable-next-line`,
   `aderyn-fp-next-line`) listed above;
2. `forge fmt` (the `forge fmt --check` gate in CI): import ordering inside the
   existing groups, spacing, `(bool ok,)`, some multi-line calls collapsed,
   `1_000` → `1000`.

The bytecode of `FixedSaleV4` is identical before and after both
(`d0bd17efe9b55de3950148518a2aaba8ea50b57a08fea29aac778f7f65fd7db8`). Keeping
the original formatting is a matter of dropping the `forge fmt --check` step
from CI.

## Limits of this analysis

- Static analysis does not verify the invariants I1–I13 declared in the contract
  header: those are economic and sequencing properties, outside what slither and
  aderyn can see. They are covered by the suite described in
  [testing.md](testing.md) (I1–I5, I9, I12 as handler-driven invariants; I7/I8,
  I10, I11 and I13 as path tests).
- The REV7 integration suite referenced in the contract header was never
  delivered into this repository: the tests here were written from scratch.
- Upstream code in `lib/` is deliberately out of scope (`filter_paths`,
  `exclude`): the analysis targets the glue code, not the dependencies.
