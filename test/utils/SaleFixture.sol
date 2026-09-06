// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedSaleV4, LaunchToken} from "../../src/FixedSaleV4.sol";
import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
import {IPositionDescriptor} from "@uniswap/v4-periphery/src/interfaces/IPositionDescriptor.sol";
import {IWETH9} from "@uniswap/v4-periphery/src/interfaces/external/IWETH9.sol";
import {Test} from "forge-std/Test.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {DeployPermit2} from "permit2/test/utils/DeployPermit2.sol";
import {WETH} from "solmate/src/tokens/WETH.sol";

/// @dev Fixture condiviso: PoolManager e PositionManager reali (nessun mock),
/// permit2 etchato dal bytecode precompilato come nei test di v4-periphery.
abstract contract SaleFixture is Test, DeployPermit2 {
    uint256 internal constant SALE_SUPPLY = 1_000_000e18;
    uint256 internal constant PRICE_PER_TOKEN = 0.001 ether; // wei per 1e18 token
    uint256 internal constant SALE_DURATION = 7 days;
    uint256 internal constant SOFT_CAP_BPS = 5000; // 50%

    PoolManager internal poolManager;
    PositionManager internal positionManager;
    IAllowanceTransfer internal permit2;
    IWETH9 internal weth;

    FixedSaleV4 internal sale;
    LaunchToken internal token;
    address internal feeRecipient = makeAddr("feeRecipient");

    function _deployStack() internal {
        poolManager = new PoolManager(address(this));
        permit2 = IAllowanceTransfer(deployPermit2());
        weth = IWETH9(address(new WETH()));
        positionManager = new PositionManager(
            IPoolManager(address(poolManager)), permit2, 100_000, IPositionDescriptor(address(0)), weth
        );
    }

    function _deploySale() internal {
        sale = new FixedSaleV4(
            "Launch",
            "LNCH",
            SALE_SUPPLY,
            PRICE_PER_TOKEN,
            SALE_DURATION,
            SOFT_CAP_BPS,
            feeRecipient,
            address(poolManager),
            address(positionManager)
        );
        token = sale.token();
    }

    function setUp() public virtual {
        _deployStack();
        _deploySale();
    }

    /// @dev ETH necessario per comprare `tokens` unita' di token.
    function _costOf(uint256 tokens) internal pure returns (uint256) {
        return (tokens * PRICE_PER_TOKEN) / 1e18;
    }
}
