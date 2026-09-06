// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Counter} from "../src/Counter.sol";
import {Script} from "forge-std/Script.sol";

contract CounterScript is Script {
    Counter public counter;

    function run() public {
        vm.startBroadcast();

        counter = new Counter();

        vm.stopBroadcast();
    }
}
