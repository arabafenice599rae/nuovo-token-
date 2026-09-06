# Deployment checklist

The deploy script takes the two Uniswap addresses from the environment rather
than hardcoding them. That is the safe default — a wrong constant compiled into
the source is discovered after it has cost something — but it moves the burden
onto this checklist. Work down it in order.

## 1. Fix the counterparties

`POOL_MANAGER` and `POSITION_MANAGER` must come from Uniswap's **official v4
deployment list** for the chain you are deploying to
(<https://docs.uniswap.org/contracts/v4/deployments>), copied from that page and
compared character by character, not from a search result or a block explorer
hit.

The contract does one check for you: the constructor reverts with
`ManagerMismatch` unless `positionManager.poolManager() == poolManager`. That
catches a mismatched pair. It does not catch two addresses that belong together
but are not Uniswap's — verify them yourself.

```bash
# what the PositionManager says its PoolManager is
cast call "$POSITION_MANAGER" "poolManager()(address)" --rpc-url "$RPC_URL"
```

## 2. Rehearse on a testnet

Deploy the whole thing on a testnet where Uniswap v4 is deployed and walk the
lifecycle end to end with real transactions:

1. deploy, and read back `saleSupply`, `pricePerToken`, `softCapTokens`,
   `saleDeadline`, `targetTick`, `token()`;
2. `buy()` from a second account, check `purchased` and `contributed`;
3. reach the close (sell out, or wait past the deadline above the soft cap);
4. `finalize()` — this is the transaction that matters: it normalises the price,
   mints the position and burns the remainder, and it is the one that costs the
   most gas;
5. `claim()` and confirm the tokens land;
6. `collectPoolFees()` after a swap or two, and confirm `bootstrapLiquidity` is
   unchanged;
7. on a separate deploy, let the deadline pass below the soft cap and check
   `refund()` returns the full amount, fee included.

The test suite already covers all of this against real v4 contracts, but a
testnet run exercises the actual addresses, the actual gas and the actual
wallet flow.

## 3. Deploy

```bash
POOL_MANAGER=0x… POSITION_MANAGER=0x… FEE_RECIPIENT=0x… \
  forge script script/Deploy.s.sol --rpc-url "$RPC_URL" --broadcast --verify
```

`FEE_RECIPIENT` is immutable and collects both the 10% sale fee and the pool's
swap fees forever. It cannot be changed afterwards — check it twice, and prefer
an address you control with a hardware wallet or a multisig.

Record from the run log: the `FixedSaleV4` address, the `LaunchToken` address,
the `poolId` and the `targetTick`.

## 4. Verify the source

Verify both contracts on the chain's explorer (`--verify` above, or
`forge verify-contract` afterwards). A sale whose source nobody can read asks
buyers to trust a promise instead of a contract, which is the opposite of what
this launch is for.

## 5. Point the frontend at it

In `frontend/config.js`:

```js
window.SALE_CONFIG = Object.freeze({
  chainId: "0x…",        // hex chain id of the deployment chain
  chainName: "…",
  saleAddress: "0x…",    // the FixedSaleV4 address, not the token
  explorer: "https://…"
});
```

Then open the page and confirm it reads the sale: symbol, price, supply and
countdown come from the chain, so wrong values here show up immediately. Serve
it with the headers listed in [frontend/README.md](../frontend/README.md).

## 6. After the close

`finalize()` is permissionless — anyone can call it, and the frontend exposes
it — but nobody is obliged to. Watch the sale as it closes and call it yourself
if no one else does: until it runs, buyers cannot claim, and past the deadline
plus `FINALIZE_GRACE` (3 days) they can start taking refunds instead.
