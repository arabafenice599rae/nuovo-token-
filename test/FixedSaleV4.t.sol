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

/// @dev Test di percorso: lifecycle, refund e arrotondamento della vendita.
/// Non sostituisce la suite di integrazione REV7 (che non e' in questo repo).
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
        assertEq(sale.feesAccrued(), cost / 10, "fee 10%");
        assertEq(sale.ethForLiquidity(), cost - cost / 10, "eth per LP");

        sale.finalize();

        assertTrue(sale.finalized(), "finalized");
        assertGt(sale.bootstrapTokenId(), 0, "posizione mintata");
        assertGt(sale.bootstrapLiquidity(), 0, "liquidita' > 0");
        // I12: dopo il burn restano solo i token in escrow per i compratori.
        assertEq(token.balanceOf(address(sale)), SALE_SUPPLY, "escrow == totalSold");

        vm.prank(alice);
        sale.claim();
        assertEq(token.balanceOf(alice), SALE_SUPPLY, "claim");
        assertEq(sale.purchased(alice), 0, "escrow azzerato");

        // Il dust ETH avanzato dal mint e' gia' stato spazzato a feeRecipient
        // dentro finalize(), quindi si misura il delta della withdraw.
        uint256 fees = sale.feesAccrued();
        uint256 recipientBefore = feeRecipient.balance;
        sale.withdrawFees();
        assertEq(feeRecipient.balance - recipientBefore, fees, "fee al recipient");
        assertEq(sale.feesAccrued(), 0, "fee azzerate");
        assertEq(address(sale).balance, 0, "nessun residuo ETH");
    }

    function test_refundBelowSoftCap() public {
        uint256 tokens = SALE_SUPPLY / 10; // sotto il soft cap del 50%
        uint256 cost = _costOf(tokens);

        vm.prank(alice);
        sale.buy{value: cost}();

        vm.warp(block.timestamp + SALE_DURATION);
        vm.expectRevert(FixedSaleV4.CapNotReached.selector);
        sale.finalize();

        uint256 before = alice.balance;
        vm.prank(alice);
        sale.refund();

        assertEq(alice.balance - before, cost, "rimborso integrale, fee inclusa");
        assertEq(sale.totalSold(), 0, "stato globale ripristinato");
        assertEq(sale.feesAccrued(), 0, "fee stornata");
        assertEq(sale.ethForLiquidity(), 0, "budget LP stornato");
    }

    /// @dev I11: oltre la grace il refund e' possibile anche sopra il soft cap.
    function test_refundAfterGraceAboveSoftCap() public {
        uint256 tokens = (SALE_SUPPLY * 6) / 10; // sopra il soft cap
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
        assertEq(alice.balance - before, cost, "rimborso post-grace");
    }

    function test_buyRefundsSurplusOnSoldOut() public {
        uint256 cost = _costOf(SALE_SUPPLY);
        uint256 before = alice.balance;

        vm.prank(alice);
        sale.buy{value: cost + 5 ether}();

        assertEq(before - alice.balance, cost, "surplus restituito");
        assertEq(sale.totalSold(), SALE_SUPPLY, "clamp alla supply");
    }

    function testFuzz_buyAccounting(uint256 value) public {
        value = bound(value, PRICE_PER_TOKEN / 1e18 + 1, _costOf(SALE_SUPPLY));

        vm.prank(alice);
        sale.buy{value: value}();

        uint256 spent = sale.contributed(alice);
        assertLe(spent, value, "speso <= inviato");
        assertEq(sale.feePaid(alice), (spent * sale.FEE_BPS()) / sale.BPS(), "fee per-utente");
        // I5
        assertEq(sale.feesAccrued() + sale.ethForLiquidity(), spent, "I5");
        // I2 / I3
        assertEq(sale.purchased(alice), sale.totalSold(), "I2");
        assertLe(sale.totalSold(), SALE_SUPPLY, "I3");
        // I1
        assertGe(address(sale).balance, sale.feesAccrued() + sale.ethForLiquidity(), "I1");
    }

    /// @dev H-1 / percorso [CUSTOM]: su un pool ancora senza liquidita' chiunque
    /// puo' spostare il prezzo gratis con uno swap limitato. finalize() deve
    /// normalizzare (unlockCallback) e mintare comunque al prezzo di listing.
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

        // free move: pool vuoto, lo swap sposta lo sqrtPrice fino al limite a costo zero
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
        assertEq(movedPrice, movedTo, "prezzo spostato prima del finalize");

        sale.finalize();

        // I7 + I8: il mint e' avvenuto esattamente al target
        (uint160 finalPrice, int24 finalTick,,) = IPoolManager(address(poolManager)).getSlot0(sale.poolId());
        assertEq(finalPrice, sale.targetSqrtPriceX96(), "I7: prezzo riportato al target");
        assertEq(finalTick, sale.targetTick(), "I8: tick al target");
        assertGt(sale.bootstrapLiquidity(), 0, "posizione mintata dopo la normalizzazione");
    }

    /// @dev Fase E / T6: dopo il finalize le swap fee sono raccoglibili in modo
    /// permissionless verso feeRecipient, senza toccare il principal (I9).
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

        // Uno swap reale contro la posizione appena creata: genera fee.
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

        assertGt(feeRecipient.balance - feeEthBefore, 0, "swap fee in ETH raccolte");
        assertEq(sale.bootstrapLiquidity(), liquidityBefore, "I9: principal invariato");
        assertEq(sale.bootstrapTokenId(), tokenIdBefore, "I9: stessa posizione");
        assertEq(positionManager.ownerOf(tokenIdBefore), address(sale), "I9: NFT non ceduto");
    }

    /// @dev T3: liquidita' ostile. L'attaccante sposta il prezzo sotto il target
    /// (free move) e piazza liquidita' solo-ETH sopra il prezzo corrente. La
    /// normalizzazione di finalize() deve attraversarla davvero — qui i delta
    /// dello swap sono diversi da zero su entrambe le currency — e finire
    /// comunque esattamente al target.
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

        // 1) free move: prezzo sotto il target
        vm.prank(bob);
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1, sqrtPriceLimitX96: sale.targetSqrtPriceX96() / 2}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        (, int24 movedTick,,) = IPoolManager(address(poolManager)).getSlot0(sale.poolId());
        assertLt(movedTick, sale.targetTick(), "prezzo spostato sotto il target");

        // 2) posizione solo-ETH sopra il prezzo corrente, che copre il target
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
        assertEq(finalPrice, sale.targetSqrtPriceX96(), "I7: prezzo al target dopo la traversata");
        assertEq(finalTick, sale.targetTick(), "I8: tick al target");
        assertGt(sale.bootstrapLiquidity(), 0, "posizione mintata");
        // la normalizzazione ha davvero venduto token nel pool (delta != 0)
        assertLt(token.balanceOf(address(sale)), saleTokensBefore, "token usciti verso il pool");
        // I12 resta valida dopo la traversata
        assertEq(token.balanceOf(address(sale)), sale.totalSold(), "escrow == totalSold");
    }

    // ---------------- guardie del costruttore e degli ingressi ----------------

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

    /// @dev I10: un PositionManager legato a un altro PoolManager e' rifiutato.
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
        assertFalse(ok, "ETH diretto rifiutato");
    }

    /// @dev L'hook ERC721 accetta solo dal PositionManager. In pratica non viene
    /// mai invocato: POSM minta con `_mint`, non `safeMint`.
    function test_onERC721ReceivedOnlyFromPosm() public {
        vm.prank(address(positionManager));
        assertEq(sale.onERC721Received(address(0), address(0), 1, ""), sale.onERC721Received.selector);

        vm.prank(bob);
        vm.expectRevert(FixedSaleV4.NotPositionManager.selector);
        sale.onERC721Received(address(0), address(0), 1, "");
    }

    /// @dev I13: costo di saturazione dei bound. Con la liquidita' massima
    /// piazzabile in un tick, spingere il prezzo oltre TICK_UPPER costa ordini
    /// di grandezza piu' del vecchio full-range, che era attaccabile con dust.
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
        assertLt(costOld, 1e13); // il vecchio full-range era attaccabile con dust
        assertGt(costNew, 1e25); // TICK_UPPER: >10M ETH
        assertGt(costLowTok, sale.MAX_TOTAL_SUPPLY() * 10); // TICK_LOWER: >10x supply
    }

    /// @dev Scenario soft cap dell'esempio in docs/overview.md: venduto il 50%,
    /// nel pool entra la liquidita' che l'ETH raccolto sostiene al prezzo di
    /// listing e tutto il resto — riserva avanzata e invenduto — viene bruciato.
    function test_softCapFinalizeBurnsUnsoldAndSurplus() public {
        vm.prank(alice);
        sale.buy{value: _costOfAtLeast(SALE_SUPPLY / 2)}();
        uint256 sold = sale.totalSold();

        vm.warp(block.timestamp + SALE_DURATION);
        sale.finalize();

        // escrow: esattamente i token dovuti agli acquirenti
        assertEq(token.balanceOf(address(sale)), sold, "escrow == venduto");
        // supply finale = venduto + token effettivamente nel pool (~450k)
        uint256 inPool = token.balanceOf(address(poolManager));
        assertEq(token.totalSupply(), sold + inPool, "supply == escrow + LP");
        assertApproxEqRel(inPool, SALE_SUPPLY * 45 / 100, 0.01e18, "~450k token nel pool");
        assertApproxEqRel(token.totalSupply(), SALE_SUPPLY * 95 / 100, 0.01e18, "~950k supply finale");
    }
}
