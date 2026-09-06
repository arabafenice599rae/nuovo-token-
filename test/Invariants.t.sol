// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedSaleV4, LaunchToken} from "../src/FixedSaleV4.sol";
import {SaleFixture} from "./utils/SaleFixture.sol";
import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";

/// @dev Handler: guida la macchina a stati della vendita (buy / refund / claim /
/// finalize / withdrawFees / sweepDust / passaggio del tempo) e tiene i ghost
/// necessari alle invarianti che non sono osservabili dallo stato del contratto.
contract SaleHandler is CommonBase, StdCheats, StdUtils {
    FixedSaleV4 internal immutable sale;
    LaunchToken internal immutable token;
    address[] internal actors;

    uint256 public ghostContributed; // somma contributed outstanding (I5)
    uint256 public ghostPurchased; // somma purchased outstanding (I2)
    uint256 public ghostSoldAtFinalize; // totalSold al momento del finalize (I4)
    uint128 public ghostLiquidity; // ultima bootstrapLiquidity vista (I9)
    uint256 public ghostTokenId; // bootstrapTokenId visto (I9)
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

    /// @dev Fa avanzare il tempo: senza questo non si raggiungono ne' la
    /// deadline (soft cap) ne' la grace di I11.
    function warp(uint256 secs) public {
        calls++;
        vm.warp(block.timestamp + bound(secs, 1 hours, 5 days));
    }
}

/// @dev Invarianti I1-I5, I9 e I12 dell'header di FixedSaleV4.
/// I6/I7/I8 sono asserite dentro finalize() dal contratto stesso (revert), I11
/// e' coperta dai test di percorso in FixedSaleV4.t.sol, I10 e I13 sono statiche.
contract InvariantsTest is SaleFixture {
    SaleHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new SaleHandler(sale);
        targetContract(address(handler));
    }

    /// I1: il contratto copre sempre cio' che deve ancora ai suoi utenti.
    function invariant_I1_ethSolvency() public view {
        if (!sale.finalized()) {
            assertGe(address(sale).balance, sale.feesAccrued() + sale.ethForLiquidity(), "I1 pre-finalize");
        } else {
            assertGe(address(sale).balance, sale.feesAccrued(), "I1 post-finalize");
        }
    }

    /// I2: i token in escrow coprono sempre il claimabile ancora aperto.
    function invariant_I2_tokenEscrow() public view {
        uint256 outstanding;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            outstanding += sale.purchased(handler.actorAt(i));
        }
        assertEq(outstanding, handler.ghostPurchased(), "ghost purchased allineato");
        assertGe(token.balanceOf(address(sale)), outstanding, "I2");
    }

    /// I3: non si vende mai piu' della supply in vendita.
    function invariant_I3_soldWithinSupply() public view {
        assertLe(sale.totalSold(), sale.saleSupply(), "I3");
    }

    /// I4: si finalizza solo sopra il soft cap (o a sold out).
    function invariant_I4_softCapAtFinalize() public view {
        if (sale.finalized()) {
            assertGe(handler.ghostSoldAtFinalize(), sale.softCapTokens(), "I4");
        }
    }

    /// I5: la contabilita' ETH e' esattamente la somma dei contributi aperti.
    /// @dev Vale prima del finalize: dopo, ethForLiquidity resta al valore che
    /// aveva (viene speso nella LP, non azzerato).
    function invariant_I5_ethAccounting() public view {
        if (sale.finalized()) return;
        uint256 outstanding;
        uint256 n = handler.actorCount();
        for (uint256 i = 0; i < n; i++) {
            outstanding += sale.contributed(handler.actorAt(i));
        }
        assertEq(outstanding, handler.ghostContributed(), "ghost contributed allineato");
        assertEq(sale.feesAccrued() + sale.ethForLiquidity(), outstanding, "I5");
    }

    /// I9: la posizione di bootstrap non viene mai ridotta ne' ceduta.
    function invariant_I9_bootstrapPositionUntouched() public view {
        if (!sale.finalized()) return;
        assertEq(sale.bootstrapTokenId(), handler.ghostTokenId(), "tokenId immutato");
        assertGe(sale.bootstrapLiquidity(), handler.ghostLiquidity(), "liquidita' mai ridotta");
        assertEq(positionManager.ownerOf(sale.bootstrapTokenId()), address(sale), "NFT non ceduto");
    }

    /// I12: dopo il burn la supply e' esattamente escrow + circolante + LP.
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

    /// @dev Diagnostica: mostra quante chiamate e quanti finalize sono passati.
    function invariant_callSummary() public view {
        assertLe(handler.finalizeCalls(), 1, "finalize una sola volta");
    }

    /// @dev Guardia anti-vacuita': le invarianti I9 e I12 valgono solo dopo il
    /// finalize, quindi va dimostrato che l'handler ci arriva davvero.
    function test_handlerReachesEveryPhase() public {
        uint256 soldOutValue = _costOf(SALE_SUPPLY);

        handler.buy(0, soldOutValue);
        assertEq(handler.buySuccess(), 1, "buy raggiungibile");

        handler.finalize();
        assertEq(handler.finalizeCalls(), 1, "finalize raggiungibile");
        assertTrue(sale.finalized(), "stato finalized raggiunto");

        handler.claim(0);
        assertEq(handler.claimSuccess(), 1, "claim raggiungibile");

        assertGt(sale.bootstrapLiquidity(), 0, "posizione LP creata dall'handler");
    }

    /// @dev Stessa guardia per il ramo refund (sotto soft cap, oltre deadline).
    function test_handlerReachesRefund() public {
        handler.buy(1, _costOf(SALE_SUPPLY / 100));
        // 3 salti da 5 giorni: oltre deadline (7g) e grace (3g)
        handler.warp(type(uint256).max);
        handler.warp(type(uint256).max);
        handler.warp(type(uint256).max);
        handler.refund(1);
        assertEq(handler.refundSuccess(), 1, "refund raggiungibile");
        assertEq(sale.totalSold(), 0, "stato ripristinato dal refund");
    }
}
