// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedSaleV4} from "../src/FixedSaleV4.sol";
import {SaleFixture} from "./utils/SaleFixture.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

/// @dev Path tests: lifecycle, refunds and sale rounding.
/// Not a replacement for the REV7 integration suite (which is not in this repo).
contract FixedSaleV4Test is SaleFixture {
    using StateLibrary for IPoolManager;

    uint160 internal constant MIN_SQRT_PRICE_PLUS_ONE = 4_295_128_740;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        vm.deal(alice, 10_000 ether);
        vm.deal(bob, 10_000 ether);
    }

    function test_soldOutLifecycle() public {
        uint256 cost = _costOf(SALE_SUPPLY);

        vm.prank(alice);
        sale.buy{value: _costOfAll()}();

        assertEq(sale.totalSold(), SALE_SUPPLY, "sold out");
        assertEq(sale.feesAccrued(), cost / 10, "10% fee");
        assertEq(sale.ethForLiquidity(), cost - cost / 10, "eth earmarked for the LP");

        sale.finalize();

        assertTrue(sale.finalized(), "finalized");
        assertGt(sale.bootstrapTokenId(), 0, "position minted");
        assertGt(sale.bootstrapLiquidity(), 0, "liquidity > 0");
        // I12: after the burn only the buyers' escrowed tokens are left.
        assertEq(token.balanceOf(address(sale)), SALE_SUPPLY, "escrow == totalSold");

        vm.prank(alice);
        sale.claim();
        assertEq(token.balanceOf(alice), SALE_SUPPLY, "claim");
        assertEq(sale.purchased(alice), 0, "escrow cleared");

        // The ETH dust left by the mint was already swept to feeRecipient inside
        // finalize(), so measure the delta of the withdrawal itself.
        uint256 fees = sale.feesAccrued();
        uint256 recipientBefore = feeRecipient.balance;
        sale.withdrawFees();
        assertEq(feeRecipient.balance - recipientBefore, fees, "fee to the recipient");
        assertEq(sale.feesAccrued(), 0, "fees cleared");
        assertEq(address(sale).balance, 0, "no ETH left behind");
    }

    function test_refundBelowSoftCap() public {
        uint256 tokens = SALE_SUPPLY / 10; // below the 50% soft cap
        uint256 cost = _costOf(tokens);

        vm.prank(alice);
        sale.buy{value: cost}();

        vm.warp(block.timestamp + SALE_DURATION);
        vm.expectRevert(FixedSaleV4.CapNotReached.selector);
        sale.finalize();

        uint256 before = alice.balance;
        vm.prank(alice);
        sale.refund();

        assertEq(alice.balance - before, cost, "full refund, fee included");
        assertEq(sale.totalSold(), 0, "global state restored");
        assertEq(sale.feesAccrued(), 0, "fee reversed");
        assertEq(sale.ethForLiquidity(), 0, "LP budget reversed");
    }

    /// @dev I11: past the grace window, refunds work even above the soft cap.
    function test_refundAfterGraceAboveSoftCap() public {
        uint256 tokens = (SALE_SUPPLY * 6) / 10; // above the soft cap
        uint256 cost = _costOf(tokens);

        vm.prank(alice);
        sale.buy{value: cost}();
        vm.warp(block.timestamp + SALE_DURATION);

        vm.prank(alice);
        vm.expectRevert(FixedSaleV4.FinalizeWindowOpen.selector);
        sale.refund();

        vm.warp(block.timestamp + sale.FINALIZE_GRACE());
        uint256 before = alice.balance;
        vm.prank(alice);
        sale.refund();
        assertEq(alice.balance - before, cost, "refund after the grace window");
    }

    function test_buyRefundsSurplusOnSoldOut() public {
        uint256 cost = _costOf(SALE_SUPPLY);
        uint256 before = alice.balance;

        vm.prank(alice);
        sale.buy{value: cost + 5 ether}();

        assertEq(before - alice.balance, cost, "surplus returned");
        assertEq(sale.totalSold(), SALE_SUPPLY, "clamped to the supply");
    }

    function testFuzz_buyAccounting(uint256 value) public {
        value = bound(value, PRICE_PER_TOKEN / 1e18 + 1, _costOf(SALE_SUPPLY));

        vm.prank(alice);
        sale.buy{value: value}();

        uint256 spent = sale.contributed(alice);
        assertLe(spent, value, "spent <= sent");
        assertEq(sale.feePaid(alice), (spent * sale.FEE_BPS()) / sale.BPS(), "per-user fee");
        // I5
        assertEq(sale.feesAccrued() + sale.ethForLiquidity(), spent, "I5");
        // I2 / I3
        assertEq(sale.purchased(alice), sale.totalSold(), "I2");
        assertLe(sale.totalSold(), SALE_SUPPLY, "I3");
        // I1
        assertGe(address(sale).balance, sale.feesAccrued() + sale.ethForLiquidity(), "I1");
    }

    /// @dev H-1 / the [CUSTOM] path: on a pool that still has no liquidity anyone
    /// can move the price for free with a limited swap. finalize() has to
    /// normalise it (unlockCallback) and still mint at the listing price.
    function test_finalizeNormalizesAfterFreeMove() public {
        vm.prank(alice);
        sale.buy{value: _costOfAll()}();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: sale.POOL_FEE(),
            tickSpacing: sale.TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        // free move: empty pool, the swap walks sqrtPrice to the limit at no cost
        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(poolManager)));
        uint160 movedTo = sale.targetSqrtPriceX96() / 2;
        vm.prank(bob);
        router.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: movedTo}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        (uint160 movedPrice,,,) = IPoolManager(address(poolManager)).getSlot0(sale.poolId());
        assertEq(movedPrice, movedTo, "price moved before finalize");

        sale.finalize();

        // I7 + I8: the mint happened exactly at the target
        (uint160 finalPrice, int24 finalTick,,) = IPoolManager(address(poolManager)).getSlot0(sale.poolId());
        assertEq(finalPrice, sale.targetSqrtPriceX96(), "I7: price brought back to target");
        assertEq(finalTick, sale.targetTick(), "I8: tick at target");
        assertGt(sale.bootstrapLiquidity(), 0, "position minted after normalisation");
    }

    /// @dev Phase E / T6: after the migration the swap fees are collectable
    /// permissionlessly to feeRecipient, without touching the principal (I9).
    function test_collectPoolFeesLeavesPrincipalUntouched() public {
        vm.prank(alice);
        sale.buy{value: _costOfAll()}();
        sale.finalize();

        uint128 liquidityBefore = sale.bootstrapLiquidity();
        uint256 tokenIdBefore = sale.bootstrapTokenId();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: sale.POOL_FEE(),
            tickSpacing: sale.TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        // A real swap against the freshly minted position: it generates fees.
        PoolSwapTest router = new PoolSwapTest(IPoolManager(address(poolManager)));
        vm.prank(bob);
        router.swap{value: 10 ether}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -10 ether, sqrtPriceLimitX96: MIN_SQRT_PRICE_PLUS_ONE}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );

        uint256 feeEthBefore = feeRecipient.balance;
        sale.collectPoolFees();

        assertGt(feeRecipient.balance - feeEthBefore, 0, "ETH swap fees collected");
        assertEq(sale.bootstrapLiquidity(), liquidityBefore, "I9: principal untouched");
        assertEq(sale.bootstrapTokenId(), tokenIdBefore, "I9: same position");
        assertEq(positionManager.ownerOf(tokenIdBefore), address(sale), "I9: NFT not transferred away");
    }

    /// @dev T3: hostile liquidity. The attacker moves the price below the target
    /// (free move) and places ETH-only liquidity above the current price. The
    /// normalisation inside finalize() has to actually cross it — here the swap
    /// deltas are non-zero on both currencies — and still land exactly on the
    /// target.
    function test_finalizeCrossesHostileLiquidity() public {
        vm.prank(alice);
        sale.buy{value: _costOfAll()}();

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: sale.POOL_FEE(),
            tickSpacing: sale.TICK_SPACING(),
            hooks: IHooks(address(0))
        });

        PoolSwapTest swapRouter = new PoolSwapTest(IPoolManager(address(poolManager)));
        PoolModifyLiquidityTest lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(poolManager)));

        // 1) free move: price below the target
        vm.prank(bob);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: sale.targetSqrtPriceX96() / 2}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (, int24 movedTick,,) = IPoolManager(address(poolManager)).getSlot0(sale.poolId());
        assertLt(movedTick, sale.targetTick(), "price moved below the target");

        // 2) ETH-only position above the current price, spanning the target
        int24 spacing = sale.TICK_SPACING();
        int24 lower = ((movedTick / spacing) + 2) * spacing;
        int24 upper = ((sale.targetTick() / spacing) + 20) * spacing;
        vm.prank(bob);
        lpRouter.modifyLiquidity{value: 50 ether}(
            key, ModifyLiquidityParams({tickLower: lower, tickUpper: upper, liquidityDelta: 1e16, salt: 0}), ""
        );

        uint256 saleTokensBefore = token.balanceOf(address(sale));
        sale.finalize();

        (uint160 finalPrice, int24 finalTick,,) = IPoolManager(address(poolManager)).getSlot0(sale.poolId());
        assertEq(finalPrice, sale.targetSqrtPriceX96(), "I7: price at target after the crossing");
        assertEq(finalTick, sale.targetTick(), "I8: tick at target");
        assertGt(sale.bootstrapLiquidity(), 0, "position minted");
        // the normalisation really did sell tokens into the pool (delta != 0)
        assertLt(token.balanceOf(address(sale)), saleTokensBefore, "tokens went out to the pool");
        // I12 still holds after the crossing
        assertEq(token.balanceOf(address(sale)), sale.totalSold(), "escrow == totalSold");
    }

    // ---------------- constructor and entry guards ----------------

    function test_constructorRejectsZeroAddress() public {
        vm.expectRevert(FixedSaleV4.ZeroAddress.selector);
        new FixedSaleV4(
            "L",
            "L",
            SALE_SUPPLY,
            PRICE_PER_TOKEN,
            SALE_DURATION,
            SOFT_CAP_BPS,
            address(0),
            address(poolManager),
            address(positionManager)
        );
    }

    /// @dev I10: a PositionManager bound to a different PoolManager is rejected.
    function test_constructorRejectsManagerMismatch() public {
        PoolManager other = new PoolManager(address(this));
        vm.expectRevert(FixedSaleV4.ManagerMismatch.selector);
        new FixedSaleV4(
            "L",
            "L",
            SALE_SUPPLY,
            PRICE_PER_TOKEN,
            SALE_DURATION,
            SOFT_CAP_BPS,
            feeRecipient,
            address(other),
            address(positionManager)
        );
    }

    function test_receiveRejectsDirectEth() public {
        vm.deal(bob, 1 ether);
        vm.prank(bob);
        (bool ok,) = address(sale).call{value: 1 ether}("");
        assertFalse(ok, "direct ETH rejected");
    }

    /// @dev The ERC721 hook only accepts calls from the PositionManager. In
    /// practice it is never invoked: POSM mints with `_mint`, not `safeMint`.
    function test_onERC721ReceivedOnlyFromPosm() public {
        vm.prank(address(positionManager));
        assertEq(sale.onERC721Received(address(0), address(0), 1, ""), sale.onERC721Received.selector);

        vm.prank(bob);
        vm.expectRevert(FixedSaleV4.NotPositionManager.selector);
        sale.onERC721Received(address(0), address(0), 1, "");
    }

    /// @dev I13: cost of saturating the bounds. With the maximum liquidity
    /// placeable in one tick, pushing the price past TICK_UPPER costs orders of
    /// magnitude more than the old full range, which was attackable with dust.
    function test_I13_tickSaturation_costs() public view {
        uint128 maxL = uint128(type(uint128).max / 29_576);
        int24 sp = 60;
        int24 maxUsable = (887_272 / sp) * sp;
        uint256 costOld = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(maxUsable - sp), TickMath.getSqrtPriceAtTick(maxUsable), maxL, true
        );
        uint256 costNew = SqrtPriceMath.getAmount0Delta(
            TickMath.getSqrtPriceAtTick(sale.TICK_UPPER() - sp),
            TickMath.getSqrtPriceAtTick(sale.TICK_UPPER()),
            maxL,
            true
        );
        uint256 costLowTok = SqrtPriceMath.getAmount1Delta(
            TickMath.getSqrtPriceAtTick(sale.TICK_LOWER()),
            TickMath.getSqrtPriceAtTick(sale.TICK_LOWER() + sp),
            maxL,
            true
        );
        assertLt(costOld, 1e13); // the old full range was attackable with dust
        assertGt(costNew, 1e25); // TICK_UPPER: >10M ETH
        assertGt(costLowTok, sale.MAX_TOTAL_SUPPLY() * 10); // TICK_LOWER: >10x supply
    }

    /// @dev The soft-cap scenario from docs/overview.md: with 50% sold, the pool
    /// receives the liquidity the raised ETH supports at the listing price and
    /// everything else — leftover reserve and unsold supply — is burned.
    function test_softCapFinalizeBurnsUnsoldAndSurplus() public {
        vm.prank(alice);
        sale.buy{value: _costOfAtLeast(SALE_SUPPLY / 2)}();
        uint256 sold = sale.totalSold();

        vm.warp(block.timestamp + SALE_DURATION);
        sale.finalize();

        // escrow: exactly the tokens owed to buyers
        assertEq(token.balanceOf(address(sale)), sold, "escrow == sold");
        // final supply = sold + the tokens actually in the pool
        uint256 inPool = token.balanceOf(address(poolManager));
        assertEq(token.totalSupply(), sold + inPool, "supply == escrow + LP");
        assertApproxEqRel(inPool, (SALE_SUPPLY * 45) / 100, 0.01e18, "~45% of the sale supply in the pool");
        assertApproxEqRel(token.totalSupply(), (SALE_SUPPLY * 95) / 100, 0.01e18, "~95% of the sale supply left");
    }
}
