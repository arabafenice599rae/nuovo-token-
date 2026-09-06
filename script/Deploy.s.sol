// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {FixedSaleV4} from "../src/FixedSaleV4.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

/// @notice Deploy di FixedSaleV4 con i parametri del lancio.
///
/// PoolManager e PositionManager NON sono hardcoded: vanno passati da env, presi
/// dalla lista ufficiale dei deployment Uniswap v4 per la chain di destinazione
/// (https://docs.uniswap.org/contracts/v4/deployments). Il costruttore verifica
/// comunque che il PositionManager sia legato a quel PoolManager (I10).
///
///   POOL_MANAGER=0x... POSITION_MANAGER=0x... FEE_RECIPIENT=0x... \
///   forge script script/Deploy.s.sol --rpc-url $RPC_URL --broadcast
contract DeployScript is Script {
    // ---- parametri del lancio ----
    string internal constant NAME = "Launch Token";
    string internal constant SYMBOL = "LNCH";

    /// @dev Token in vendita. La supply totale coniata e' SALE_SUPPLY + 90%
    ///      (riserva di liquidita'), cioe' 19/10 di SALE_SUPPLY: per una supply
    ///      totale di esattamente 100.000.000 token servono 100M * 10/19 in
    ///      vendita e 100M * 9/19 di riserva. E' l'unico valore intero che
    ///      chiude a 100M esatti con lo split 90/10 del contratto.
    ///      52.631.578,947368421052631579 + 47.368.421,052631578947368421 = 100M
    uint256 internal constant SALE_SUPPLY = 52_631_578_947_368_421_052_631_579;

    /// @dev Prezzo fisso: wei per 1e18 unita' di token. 0,00001 ETH per token
    ///      => 1.000 ETH raccolti a vendita esaurita.
    uint256 internal constant PRICE_PER_TOKEN = 0.000_01 ether;

    uint256 internal constant SALE_DURATION = 7 days;
    uint256 internal constant SOFT_CAP_BPS = 5000; // 50% di SALE_SUPPLY

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
