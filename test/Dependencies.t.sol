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

/// @dev Smoke test delle dipendenze pinnate in lib/: verifica che i remapping di
/// remappings.txt risolvano e che v4-core compili e sia deployabile con il
/// profilo di compilazione del progetto (solc 0.8.26, cancun).
/// PoolManager eredita da solmate `Owned`, quindi copre anche lib/v4-core/lib/solmate.
contract DependenciesTest is Test {
    uint24 internal constant FEE = 3000;
    int24 internal constant TICK_SPACING = 60;

    function test_poolManagerDeploysUnderCodeSizeLimit() public {
        IPoolManager manager = IPoolManager(address(new PoolManager(address(this))));

        assertTrue(address(manager) != address(0));
        assertLt(address(manager).code.length, 24_576);
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
