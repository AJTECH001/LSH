// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LiquidationShieldHook} from "../src/hooks/LiquidationShieldHook.sol";
import {CallbackReceiver} from "../src/reactive/CallbackReceiver.sol";

contract DeployUnichain is Script {
    // Unichain Sepolia Uniswap v4 PoolManager
    address constant POOL_MANAGER = 0x00B036B58a818B1BC34d502D3fE730Db729e62AC;
    uint256 constant MIN_DEPOSIT = 0.001 ether;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address reactiveCallbackProxy = vm.envAddress("UNICHAIN_CALLBACK_PROXY");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy CallbackReceiver
        CallbackReceiver callbackReceiver = new CallbackReceiver(address(0));
        console.log("CallbackReceiver deployed at:", address(callbackReceiver));

        // 2. Mine salt and deploy Hook via CREATE2
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);

        bytes memory constructorArgs = abi.encode(IPoolManager(POOL_MANAGER), address(callbackReceiver), MIN_DEPOSIT);

        (address hookAddress, bytes32 salt) =
            HookMiner.find(CREATE2_FACTORY, flags, type(LiquidationShieldHook).creationCode, constructorArgs);

        LiquidationShieldHook hook =
            new LiquidationShieldHook{salt: salt}(IPoolManager(POOL_MANAGER), address(callbackReceiver), MIN_DEPOSIT);

        require(address(hook) == hookAddress, "Hook address mismatch");
        console.log("LiquidationShieldHook deployed at:", address(hook));

        // 3. Link CallbackReceiver to Hook and authorize Reactive proxy
        callbackReceiver.setHook(address(hook));
        callbackReceiver.addAuthorizedCaller(reactiveCallbackProxy);
        console.log("Callback proxy authorized:", reactiveCallbackProxy);

        vm.stopBroadcast();
    }
}
