// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {MockLendingPool} from "../src/test/MockLendingPool.sol";
import {console} from "forge-std/console.sol";

contract DeployMockLending is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MockLendingPool pool = new MockLendingPool();
        console.log("MockLendingPool deployed at:", address(pool));

        vm.stopBroadcast();
    }
}
