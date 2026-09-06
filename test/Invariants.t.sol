// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedSaleV4, LaunchToken} from "../src/FixedSaleV4.sol";
import {SaleFixture} from "./utils/SaleFixture.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @dev Handler: drives the sale's state machine (buy / refund / claim /
/// finalize / withdrawFees / sweepDust / time) and keeps the ghost variables the
/// invariants need but the contract's own state does not expose.
contract SaleHandler is CommonBase, StdCheats, StdUtils {
    FixedSaleV4 internal immutable sale;
    LaunchToken internal immutable token;
    address[] internal actors;

    uint256 public ghostContributed; // sum of outstanding contributions (I5)
    uint256 public ghostPurchased; // sum of outstanding purchases (I2)
    uint256 public ghostSoldAtFinalize; // totalSold at the moment of finalize (I4)
    uint128 public ghostLiquidity; // last bootstrapLiquidity seen (I9)
    uint256 public ghostTokenId; // bootstrapTokenId seen (I9)
    uint256 public calls;
    uint256 public finalizeCalls;
    uint256 public buySuccess;
    uint256 public refundSuccess;
    uint256 public claimSuccess;

    constructor(FixedSaleV4 sale_) {
        sale = sale_;
        token = sale_.token();
        for (uint256 i = 0; i < 4; i++) {
            address actor = address(uint160(uint256(keccak256(abi.encode("actor", i)))));
            actors.push(actor);
            vm.deal(actor, 100_000 ether);
        }
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function actorAt(uint256 i) external view returns (address) {
        return actors[i];
    }

    function buy(uint256 actorSeed, uint256 value) public {
        calls++;
        address actor = _actor(actorSeed);
        value = bound(value, 1e12, 2000 ether);
        if (actor.balance < value) return;

        uint256 contributedBefore = sale.contributed(actor);
        uint256 purchasedBefore = sale.purchased(actor);
        vm.prank(actor);
        try sale.buy{value: value}() {
            buySuccess++;
            ghostContributed += sale.contributed(actor) - contributedBefore;
            ghostPurchased += sale.purchased(actor) - purchasedBefore;
        } catch {}
    }

    function refund(uint256 actorSeed) public {
        calls++;
        address actor = _actor(actorSeed);
        uint256 contributedBefore = sale.contributed(actor);
        uint256 purchasedBefore = sale.purchased(actor);
        vm.prank(actor);
        try sale.refund() {
            refundSuccess++;
            ghostContributed -= contributedBefore;
            ghostPurchased -= purchasedBefore;
        } catch {}
    }

    function claim(uint256 actorSeed) public {
        calls++;
        address actor = _actor(actorSeed);
        uint256 purchasedBefore = sale.purchased(actor);
        vm.prank(actor);
        try sale.claim() {
            claimSuccess++;
            ghostPurchased -= purchasedBefore;
        } catch {}
    }

    function finalize() public {
        calls++;
        uint256 soldBefore = sale.totalSold();
        try sale.finalize() {
            finalizeCalls++;
            ghostSoldAtFinalize = soldBefore;
            ghostLiquidity = sale.bootstrapLiquidity();
            ghostTokenId = sale.bootstrapTokenId();
        } catch {}
    }

    function withdrawFees() public {
        calls++;
        try sale.withdrawFees() {} catch {}
    }

    function sweepDust() public {
        calls++;
        try sale.sweepDust() {} catch {}
    }

    /// @dev Moves time forward: without it neither the deadline (soft cap) nor
    /// the I11 grace window is ever reached.
    function warp(uint256 secs) public {
        calls++;
        vm.warp(block.timestamp + bound(secs, 1 hours, 5 days));
    }
}

/// @dev Invariants I1-I5, I9 and I12 from the FixedSaleV4 header.
/// I6/I7/I8 are asserted inside finalize() by the contract itself (revert), I11
/// is covered by the path tests in FixedSaleV4.t.sol, I10 and I13 are static.
contract InvariantsTest is SaleFixture {
    SaleHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SaleHandler(sale);
        targetContract(address(handler));
    }

    /// I1: the contract always covers what it still owes its users.
    function invariant_I1_ethSolvency() public view {
        if (!sale.finalized()) {
            assertGe(address(sale).balance, sale.feesAccrued() + sale.ethForLiquidity(), "I1 pre-finalize");
        } else {
            assertGe(address(sale).balance, sale.feesAccrued(), "I1 post-finalize");
        }
    }

    /// I2: escrowed tokens always cover the outstanding claimable amount.
    function invariant_I2_tokenEscrow() public view {
        uint256 outstanding;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            outstanding += sale.purchased(handler.actorAt(i));
        }
        assertEq(outstanding, handler.ghostPurchased(), "ghost purchased in sync");
        assertGe(token.balanceOf(address(sale)), outstanding, "I2");
    }

    /// I3: never sell more than the sale supply.
    function invariant_I3_soldWithinSupply() public view {
        assertLe(sale.totalSold(), sale.saleSupply(), "I3");
    }

    /// I4: migration only happens above the soft cap (or on a sold-out sale).
    function invariant_I4_softCapAtFinalize() public view {
        if (sale.finalized()) {
            assertGe(handler.ghostSoldAtFinalize(), sale.softCapTokens(), "I4");
        }
    }

    /// I5: the ETH accounting equals the sum of outstanding contributions.
    /// @dev Holds before finalize: afterwards ethForLiquidity keeps the value it
    /// had (it is spent into the LP, not zeroed).
    function invariant_I5_ethAccounting() public view {
        if (sale.finalized()) return;
        uint256 outstanding;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            outstanding += sale.contributed(handler.actorAt(i));
        }
        assertEq(outstanding, handler.ghostContributed(), "ghost contributed in sync");
        assertEq(sale.feesAccrued() + sale.ethForLiquidity(), outstanding, "I5");
    }

    /// I9: the bootstrap position is never reduced nor given away.
    function invariant_I9_bootstrapPositionUntouched() public view {
        if (!sale.finalized()) return;
        assertEq(sale.bootstrapTokenId(), handler.ghostTokenId(), "tokenId unchanged");
        assertGe(sale.bootstrapLiquidity(), handler.ghostLiquidity(), "liquidity never reduced");
        assertEq(positionManager.ownerOf(sale.bootstrapTokenId()), address(sale), "NFT not transferred away");
    }

    /// I12: after the burn, supply is exactly escrow + circulating + LP.
    function invariant_I12_supplyConservation() public view {
        if (!sale.finalized()) return;
        uint256 held = token.balanceOf(address(sale)) + token.balanceOf(address(poolManager))
            + token.balanceOf(address(positionManager));
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            held += token.balanceOf(handler.actorAt(i));
        }
        assertEq(token.totalSupply(), held, "I12");
    }

    /// @dev Diagnostic: a sale can only be finalized once.
    function invariant_callSummary() public view {
        assertLe(handler.finalizeCalls(), 1, "finalize happens at most once");
    }

    /// @dev Anti-vacuity guard: I9 and I12 only hold after the migration, so the
    /// handler must be shown to actually reach that state.
    function test_handlerReachesEveryPhase() public {
        uint256 soldOutValue = _costOfAll();

        handler.buy(0, soldOutValue);
        assertEq(handler.buySuccess(), 1, "buy is reachable");

        handler.finalize();
        assertEq(handler.finalizeCalls(), 1, "finalize is reachable");
        assertTrue(sale.finalized(), "finalized state reached");

        handler.claim(0);
        assertEq(handler.claimSuccess(), 1, "claim is reachable");

        assertGt(sale.bootstrapLiquidity(), 0, "LP position created through the handler");
    }

    /// @dev Same guard for the refund branch (below soft cap, past the deadline).
    function test_handlerReachesRefund() public {
        handler.buy(1, _costOf(SALE_SUPPLY / 100));
        // three 5-day jumps: past the deadline (7d) and the grace window (3d)
        handler.warp(type(uint256).max);
        handler.warp(type(uint256).max);
        handler.warp(type(uint256).max);
        handler.refund(1);
        assertEq(handler.refundSuccess(), 1, "refund is reachable");
        assertEq(sale.totalSold(), 0, "state restored by the refund");
    }
}
