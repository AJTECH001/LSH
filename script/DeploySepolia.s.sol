// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseScript} from "./base/BaseScript.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LiquidationShieldHook} from "../src/hooks/LiquidationShieldHook.sol";
import {CallbackReceiver} from "../src/reactive/CallbackReceiver.sol";
import {console} from "forge-std/console.sol";

contract DeploySepolia is BaseScript {
    uint256 constant MIN_DEPOSIT = 0.001 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy CallbackReceiver
        CallbackReceiver callbackReceiver = new CallbackReceiver(address(0));
        console.log("CallbackReceiver deployed at:", address(callbackReceiver));

        // 2. Mine and Deploy Hook
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
        );

        bytes memory constructorArgs = abi.encode(
            poolManager, 
            address(callbackReceiver), 
            MIN_DEPOSIT
        );
        
        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_FACTORY, 
            flags, 
            type(LiquidationShieldHook).creationCode, 
            constructorArgs
        );

        LiquidationShieldHook hook = new LiquidationShieldHook{salt: salt}(
            poolManager,
            address(callbackReceiver),
            MIN_DEPOSIT
        );

        console.log("LiquidationShieldHook deployed at:", address(hook));

        // 3. Link them
        callbackReceiver.setHook(address(hook));
        
        // Authorize Reactive Network callback proxy for Unichain Sepolia
        address reactiveCallbackProxy = vm.envAddress("UNICHAIN_CALLBACK_PROXY");
        callbackReceiver.addAuthorizedCaller(reactiveCallbackProxy);

        vm.stopBroadcast();
    }
}
