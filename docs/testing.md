# Tests

```bash
make test            # the whole suite (default profile)
make invariant       # invariants only
make coverage        # forge coverage --report summary
make snapshot        # refresh .gas-snapshot
make test-nightly    # ci profile: 20k fuzz runs
```

## What is in the repository

| File | Contents |
| --- | --- |
| `test/utils/SaleFixture.sol` | shared fixture: **real** PoolManager and PositionManager (no mocks), permit2 etched from its precompiled bytecode, solmate WETH |
| `test/FixedSaleV4.t.sol` | 14 path tests: sold-out lifecycle, refund below soft cap, refund after grace (I11), buy surplus, normalisation after a free move (H-1), crossing hostile liquidity (T3), fee collection leaving the principal untouched (I9/T6), soft-cap close burning reserve and unsold supply, tick saturation cost (I13), constructor and entry guards, `testFuzz_buyAccounting` |
| `test/Invariants.t.sol` | state-machine handler (buy / refund / claim / finalize / withdrawFees / sweepDust / warp) plus invariants I1–I5, I9, I12 |
| `test/Dependencies.t.sol` | smoke test for the remappings into `lib/` |

Invariants run by default at **1,000 runs × depth 150** (150,000 calls, ~50 s).

## Coverage of the declared invariants

| Invariant | How it is checked |
| --- | --- |
| I1 ETH solvency | `invariant_I1_ethSolvency` |
| I2 token escrow | `invariant_I2_tokenEscrow` (with a ghost over the sum of `purchased`) |
| I3 `totalSold <= saleSupply` | `invariant_I3_soldWithinSupply` |
| I4 soft cap at finalize | `invariant_I4_softCapAtFinalize` (ghost of `totalSold` at finalize) |
| I5 ETH accounting | `invariant_I5_ethAccounting` — **pre-finalize only**, see note below |
| I6 LP tokens ≤ reserve | indirectly: `test_soldOutLifecycle` and I12 |
| I7 / I8 price and tick at target | asserted by the contract itself (revert) and exercised by `test_finalizeNormalizesAfterFreeMove` and `test_finalizeCrossesHostileLiquidity` |
| I9 position never reduced | `invariant_I9_bootstrapPositionUntouched` + `test_collectPoolFeesLeavesPrincipalUntouched` |
| I10 immutable counterparties | `test_constructorRejectsManagerMismatch` |
| I11 liveness | `test_refundBelowSoftCap`, `test_refundAfterGraceAboveSoftCap` |
| I12 supply conservation | `invariant_I12_supplyConservation` |
| I13 unsaturable ticks | `test_I13_tickSaturation_costs`, using `SqrtPriceMath` on the bounds |

I9 and I12 only hold after the migration, so `test_handlerReachesEveryPhase` and
`test_handlerReachesRefund` prove the handler actually reaches those states:
without that guard the two invariants would pass vacuously.

## I13: cost of saturating the bounds

`test_I13_tickSaturation_costs` computes, with the maximum liquidity placeable
in a single tick (`type(uint128).max / 29576`), what it costs to push the price
past the position's bounds:

| Bound | Cost to cross the last tick |
| --- | --- |
| old full range (`maxUsable`, spacing 60) | 1.88e12 wei — **~0.0000019 ETH**, i.e. dust |
| `TICK_UPPER` = 251,340 | 1.21e26 wei — **~120 million ETH**, the order of the entire ETH supply |
| `TICK_LOWER` = -160,140 | 1.15e28 token units — **11.5× `MAX_TOTAL_SUPPLY`** |

This is the numeric check behind the claim in the contract header: the full
range was saturable with dust, the chosen bounds are not.

## Coverage

`forge coverage --report summary` on `src/FixedSaleV4.sol`:

| Metric | Value |
| --- | --- |
| Lines | 97.50% (156/160) |
| Statements | 90.99% (212/233) |
| Branches | 63.04% (29/46) |
| Functions | 100% (13/13) |

The missing branches are mostly revert paths and sign combinations of the deltas
during normalisation (`d0 > 0` together with `d1 > 0` and similar) that need
more elaborate hostile-liquidity setups than the one tested.

## Behaviours the tests surfaced

None of these is a bug; they are things to know.

1. **`ethForLiquidity` is not zeroed at finalize.** It keeps its pre-migration
   value, so after the migration the public getter no longer describes anything
   real (the funds are in the LP). That is why I5 is only asserted before
   finalize.
2. **`onERC721Received` is never invoked.** The PositionManager mints with
   `_mint`, not `safeMint`: the hook is defensive code that production never
   reaches. It is tested directly anyway.
3. **The ETH dust after the mint is not negligible.** With the launch parameters
   (473.68 ETH of LP budget) about 0.52 ETH is left over — 0.11%: the position
   is constrained on the token side and the leftover ETH is swept to
   `feeRecipient` inside `finalize()`.
4. **The last fragment of a token costs one wei more.** A wei buys 100,000
   minimal token units and the sale supply is not a multiple of that: at the
   nominal cost, rounded down, fractions of a token stay unsold and the sale
   never reads as sold out. One extra wei closes it (the surplus is refunded by
   `buy()`). The same applies to hitting the soft cap exactly; the fixture
   exposes `_costOfAll()` and `_costOfAtLeast()` for this.

## What is missing

Every invariant I1–I13 declared in the header now has a check. The **REV7
integration suite referenced in the contract header was never delivered into
this repository**: the tests here were written from scratch. If it is brought
in, the two files coexist without conflict (different contract names) and the
fixture in `test/utils/SaleFixture.sol` is reusable.
