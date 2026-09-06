// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Test} from "forge-std/Test.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {IPositionManager} from "v4-periphery/interfaces/IPositionManager.sol";

/// @dev Smoke test for the pinned dependencies in lib/: checks that the
/// remappings in remappings.txt resolve and that v4-core compiles and deploys
/// under the project's compiler profile (solc 0.8.26, cancun).
/// PoolManager inherits solmate's `Owned`, so this covers lib/v4-core/lib/solmate too.
contract DependenciesTest is Test {
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    function test_poolManagerDeploys() public {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));

        assertTrue(address(manager) != address(0));
        // The EIP-170 limit is checked by `forge build --sizes` in CI, not here:
        // `forge coverage` compiles without the optimizer and the size changes.
        assertGt(address(manager).code.length, 0);
    }

    function test_poolKeyIsUsable() public pure {
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(1)),
            fee: FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });

        assertEq(key.fee, FEE);
        assertEq(key.tickSpacing, TICK_SPACING);
    }

    function test_peripheryAndPermit2InterfacesResolve() public pure {
        assertTrue(type(IPositionManager).interfaceId != bytes4(0));
        assertTrue(type(IAllowanceTransfer).interfaceId != bytes4(0));
        assertTrue(type(IERC20).interfaceId != bytes4(0));
    }
}
