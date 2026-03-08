// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {HealthFactorMonitor} from "../src/reactive/HealthFactorMonitor.sol";


contract DeployReactive is Script {
    function run() external {
        // ── Load config from env ───────────────────────────────────────────────
        address subscriptionService = vm.envAddress("REACTIVE_SUBSCRIPTION_SERVICE");
        uint256 hookChainId         = vm.envUint("HOOK_CHAIN_ID");
        address callbackReceiver    = vm.envAddress("CALLBACK_RECEIVER");
        address hookAddress         = vm.envAddress("HOOK_ADDRESS");
        uint256 hookOriginChainId   = vm.envUint("HOOK_ORIGIN_CHAIN_ID");

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        console2.log("=== HealthFactorMonitor Deployment (Reactive Network) ===");
        console2.log("Deployer             :", deployer);
        console2.log("SubscriptionService  :", subscriptionService);
        console2.log("Hook Chain ID        :", hookChainId);
        console2.log("CallbackReceiver     :", callbackReceiver);
        console2.log("Hook Address         :", hookAddress);
        console2.log("Hook Origin Chain ID :", hookOriginChainId);
        console2.log("");

        vm.startBroadcast(deployerPk);

        HealthFactorMonitor monitor = new HealthFactorMonitor(
            subscriptionService,
            hookChainId,
            callbackReceiver,
            hookAddress,
            hookOriginChainId
        );

        vm.stopBroadcast();

        console2.log("=== Deployment Complete ===");
        console2.log("HealthFactorMonitor  :", address(monitor));
        console2.log("");
        console2.log("=== Verify the subscription was registered ===");
        console2.log("Check Reactive Network explorer for subscription events");
        console2.log("from address:", address(monitor));
    }
}
