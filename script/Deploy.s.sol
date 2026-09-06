// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedSaleV4} from "../src/FixedSaleV4.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploys FixedSaleV4 with the launch parameters.
///
/// PoolManager and PositionManager are NOT hardcoded: pass them through the
/// environment, taken from Uniswap's official v4 deployment list for the target
/// chain (https://docs.uniswap.org/contracts/v4/deployments). The constructor
/// checks anyway that the PositionManager belongs to that PoolManager (I10).
///
///   POOL_MANAGER=0x... POSITION_MANAGER=0x... FEE_RECIPIENT=0x... \
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
contract DeployScript is Script {
    // ---- launch parameters ----
    string internal constant NAME = "Launch Token";
    string internal constant SYMBOL = "LNCH";

    /// @dev Tokens on sale. The minted supply is SALE_SUPPLY + 90% (the
    ///      liquidity reserve), i.e. 19/10 of SALE_SUPPLY: a total supply of
    ///      exactly 100,000,000 tokens means selling 100M * 10/19 and keeping
    ///      100M * 9/19 in reserve. This is the only integer that closes at
    ///      exactly 100M under the contract's 90/10 integer split.
    ///      52.631.578,947368421052631579 + 47.368.421,052631578947368421 = 100M
    uint256 internal constant SALE_SUPPLY = 52_631_578_947_368_421_052_631_579;

    /// @dev Fixed price: wei per 1e18 token units. 0.00001 ETH per token
    ///      => 526.32 ETH raised at full sale.
    uint256 internal constant PRICE_PER_TOKEN = 0.000_01 ether;

    uint256 internal constant SALE_DURATION = 7 days;
    uint256 internal constant SOFT_CAP_BPS = 5000; // 50% of SALE_SUPPLY

    function run() external returns (FixedSaleV4 sale) {
        address poolManager = vm.envAddress("POOL_MANAGER");
        address positionManager = vm.envAddress("POSITION_MANAGER");
        address feeRecipient = vm.envAddress("FEE_RECIPIENT");

        vm.startBroadcast();
        sale = new FixedSaleV4(
            NAME,
            SYMBOL,
            SALE_SUPPLY,
            PRICE_PER_TOKEN,
            SALE_DURATION,
            SOFT_CAP_BPS,
            feeRecipient,
            poolManager,
            positionManager
        );
        vm.stopBroadcast();

        console2.log("FixedSaleV4 ", address(sale));
        console2.log("LaunchToken ", address(sale.token()));
        console2.log("poolId      ");
        console2.logBytes32(PoolId.unwrap(sale.poolId()));
        console2.log("targetTick  ", sale.targetTick());
        console2.log("supply      ", sale.token().totalSupply());
    }
}
