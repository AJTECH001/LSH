// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {HealthFactorMonitor} from "../src/reactive/HealthFactorMonitor.sol";

contract DeployLasna is Script {
    // Standard system contract address on Reactive Network
    address constant SYSTEM_CONTRACT = 0x0000000000000000000000000000000000fffFfF;
    uint256 constant UNICHAIN_SEPOLIA_CHAIN_ID = 1301;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Required addresses from previous deployment
        address callbackReceiver = vm.envAddress("CALLBACK_RECEIVER_ADDRESS");
        address hookAddress = vm.envAddress("HOOK_ADDRESS");

        require(callbackReceiver != address(0), "CALLBACK_RECEIVER_ADDRESS not set");
        require(hookAddress != address(0), "HOOK_ADDRESS not set");

        HealthFactorMonitor monitor = new HealthFactorMonitor{value: 0.01 ether}(
            UNICHAIN_SEPOLIA_CHAIN_ID, // Callback destination: Unichain Sepolia
            callbackReceiver,          // CallbackReceiver on Unichain Sepolia
            hookAddress,               // Hook Address on Unichain Sepolia
            0                          // Monitor all chains for the hook for now
        );

        console.log("HealthFactorMonitor deployed to Lasna at:", address(monitor));

        vm.stopBroadcast();
    }
}
