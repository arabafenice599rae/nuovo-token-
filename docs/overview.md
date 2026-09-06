# What this launch is for

## In one line

Sell a fixed share of the supply at a fixed price and, as soon as the sale
closes successfully, move the proceeds and the liquidity reserve into a Uniswap
v4 pool at that same price — with the liquidity position held by the contract
forever and nobody left with administrative power after deployment.

## The problem

In a token launch the risk is not the token code: it is the window between the
end of the raise and the creation of the market. In that window, in manually run
launches, whoever collected the funds decides alone how much liquidity to add,
at what price, when — and whether to pull it the next day. The three typical
failure modes are:

1. **thin or absent liquidity** — the market opens shallow and the first order
   moves the price by double-digit percentages;
2. **withdrawable liquidity** — whoever controls the LP position can remove it
   and walk away with the proceeds (rug pull);
3. **arbitrary opening price** — the pool is initialised at a price unrelated to
   what buyers paid, or is manipulated by a third party before the liquidity
   arrives.

## The objective

Make all three **impossible by construction**, rather than a matter of promises.
Concretely, the launch must guarantee that:

| Guarantee | How it is enforced |
| --- | --- |
| The sale price is known and cannot change | `pricePerToken` is `immutable`: set at deployment, nobody can change it |
| Market opening price = sale price | the pool is initialised in the constructor at the price derived from `pricePerToken`; before minting the position the contract **checks** that price and tick are still exactly that, and reverts otherwise |
| Liquidity proportional to the raise | 90% of the ETH raised and 90% of the sale supply go into the pool; the ratio is a constant, not a decision |
| Liquidity cannot be pulled | the position NFT stays with the contract: no function transfers it, approves it, or decreases liquidity |
| No hidden allocation | the entire supply is minted in the constructor and is only sale + liquidity; there is no mint function, and unsold tokens are **burned** |
| A guaranteed exit if the launch fails | below the soft cap at the deadline, or if the migration does not happen within 3 days, every buyer takes back **100% of the ETH they paid, fee included** |
| No discretionary power | no owner, no admin, no pause, no upgrade, no proxy |

## How it works

### Parameters (set at deployment, all `immutable`)

| Parameter | Meaning |
| --- | --- |
| `saleSupply` | tokens put on sale |
| `pricePerToken` | wei per 1e18 token units |
| `saleDuration` | length of the buying window |
| `softCapBps` | minimum share of `saleSupply` that must sell for the launch to be valid |
| `feeRecipient` | recipient of the sale fee and of the pool swap fees |

Everything else follows without further choices: `liquidityReserve` = 90% of
`saleSupply` (the share destined for the pool), the token's total supply
(`saleSupply + liquidityReserve`, capped at one billion) and the pool's
initialisation price. For this launch the total supply is fixed at exactly
**100,000,000 tokens**: since the reserve is 90% of what is sold, the minted
supply is 19/10 of the sale supply, so **52,631,578.95 tokens are on sale**
(100M × 10/19) and 47,368,421.05 form the reserve.

### The phases

**A. Sale.** Anyone buys with `buy()` at the fixed price while supply lasts and
the window is open. 10% of the ETH is the fee, 90% is committed to liquidity.
Tokens stay in escrow inside the contract and are withdrawn after the migration.
Any ETH sent in excess on the last purchase is returned in the same transaction.

**B. Outcome.** The launch is valid if the sale sells out (at any time) or if
the soft cap has been reached by the deadline. Otherwise it has failed, and
refunds open.

**C. Migration.** `finalize()` is **permissionless**: anyone can call it, the
deployer is not needed. In a single transaction the contract:

1. checks the pool price and, if someone moved it, brings it **back to the
   listing price** with a budget-limited swap;
2. **refuses to proceed** if price and tick do not match the target exactly
   (manipulating the pool blocks the migration, it does not alter it);
3. mints the liquidity position over a wide but bounded range, through the
   official Uniswap v4 PositionManager;
4. **burns** every residual token not owed to buyers;
5. returns to `feeRecipient` the ETH left over from the mint.

If the sale closes below 100% (the soft-cap case) the liquidity is computed on
what was actually raised: the pool receives the amount of tokens that matches
the available ETH at that price, and **everything else is burned**. There is no
scenario in which unsold tokens end up in somebody's hands.

**The figures for this launch.** The parameters live in `script/Deploy.s.sol`
and are the ones the test suite exercises:

| Item | Value |
| --- | --- |
| Total minted supply | 100,000,000 tokens (exact) |
| On sale | 52,631,578.947368421052631579 |
| Liquidity reserve | 47,368,421.052631578947368421 |
| Price | 0.00001 ETH per token |
| Soft cap | 26,315,789.47 tokens (50%) |
| Sale window | 7 days |
| Raised at full sale | 526.32 ETH |
| Pool opening price | 0.00001 ETH (tick 115,135) |

At full sale: **526.32 ETH raised**, of which **52.63 ETH in fees** and
**473.68 ETH into the pool** alongside **47,368,421 tokens**, at the same price
as the sale. The 52,631,578.95 tokens sold stay in escrow until `claim()`; about
0.52 ETH (0.11% of the liquidity budget) does not fit into the position because
of rounding and is swept to `feeRecipient` along with the fee.

Closing at the soft cap (50%): about 263 ETH raised, 237 ETH into the pool with
23,710,333 tokens, and both the unused reserve and the unsold supply are burned
— roughly 49,974,000 tokens destroyed, final supply about 50,026,000. Both
scenarios are covered by `test_soldOutLifecycle` and
`test_softCapFinalizeBurnsUnsoldAndSurplus`.

One rounding detail: a single wei of ETH buys 100,000 minimal token units, and
the amount on sale is not a multiple of that block. Selling out therefore takes
**one wei more** than the nominal cost; the surplus is refunded by `buy()`
itself.

**D. Delivery or refund.** Once migrated, each buyer withdraws their tokens with
`claim()`. If the launch failed instead, `refund()` returns the entire ETH paid,
fee included. The fee can only be withdrawn **after** the migration: while
refunds are still possible it stays as collateral for buyers.

**E. Pool life.** Swap fees accrued by the position are collected with
`collectPoolFees()`, also permissionless and with a recipient fixed at
deployment: anyone can make the call, the proceeds always go to `feeRecipient`.
The position's principal is never touched.

## What the launch does **not** promise

Stated with the same clarity as the guarantees:

- **It does not promise a price.** The contract guarantees the market opens at
  the sale price with real liquidity; from there the price is whatever the
  market makes it, and it can fall.
- **It does not remove counterparty risk on the fees.** `feeRecipient` collects
  10% of the raise and the perpetual swap fees. The address is fixed at
  deployment and cannot be changed, but it remains an economic concentration:
  anyone assessing the launch needs to know who it is.
- **It is not immune to griefing.** A third party with enough capital can
  manipulate the pool so that the migration reverts. They gain nothing and touch
  no funds: the effect is that, 3 days after the deadline, buyers recover their
  contributions in full.
- **It is not an audit.** This repository carries static analysis, 20 tests and
  invariants checked over 150,000 calls (see [testing.md](testing.md) and
  [findings.md](findings.md)); the Uniswap v4 integration is custom code and
  needs independent review before it handles real funds.

## Verifiability

The properties claimed here are not marketing statements: each corresponds to a
numbered invariant in the contract header and to a test that exercises it. The
full map — which test covers which invariant, with which numbers — is in
[testing.md](testing.md).
