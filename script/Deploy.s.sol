// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {HookMiner} from "v4-hooks-public/src/utils/HookMiner.sol";

import {LiquidationShieldHook} from "../src/hooks/LiquidationShieldHook.sol";
import {CallbackReceiver} from "../src/reactive/CallbackReceiver.sol";

/**
 * @title Deploy
 * @notice Deploys LiquidationShieldHook + CallbackReceiver on Sepolia (or any EVM chain).
 *
 * @dev Pre-requisites:
 *   1. Set environment variables (see below)
 *   2. Run:
 *        forge script script/Deploy.s.sol \
 *          --rpc-url $SEPOLIA_RPC_URL \
 *          --broadcast \
 *          --verify \
 *          -vvvv
 *
 * Required env vars:
 *   POOL_MANAGER      — Uniswap v4 PoolManager address on target chain
 *   MIN_DEPOSIT       — Minimum deposit in wei (e.g. 100000000000000000000 = 100e18)
 *   REACTIVE_RELAYER  — (optional) Reactive Network relayer to whitelist immediately
 *
 * Uniswap v4 PoolManager addresses:
 *   Sepolia:  0x8C4BcBE6b9eF47855f97E675296FA3F6fafa5F1A
 *   Mainnet:  0x000000000004444c5dc75cB358380D2e3dE08A90
 *
 * After running this script, copy the printed addresses and use them to
 * deploy HealthFactorMonitor on the Reactive Network (Kopli testnet).
 * See script/DeployReactive.s.sol for that step.
 */
contract Deploy is Script {
    // CREATE2 deployer proxy — used by HookMiner in forge script context
    address constant CREATE2_PROXY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    // Hook permission flags required by LiquidationShieldHook
    uint160 constant HOOK_FLAGS = uint160(
        Hooks.AFTER_INITIALIZE_FLAG |
        Hooks.BEFORE_SWAP_FLAG      |
        Hooks.AFTER_SWAP_FLAG
    );

    function run() external {
        // ── Load config from env ───────────────────────────────────────────────
        address poolManager    = vm.envAddress("POOL_MANAGER");
        uint256 minDeposit     = vm.envUint("MIN_DEPOSIT");
        address reactiveRelayer = vm.envOr("REACTIVE_RELAYER", address(0));

        uint256 deployerPk = vm.envUint("PRIVATE_KEY");
        address deployer   = vm.addr(deployerPk);

        console2.log("=== Liquidation Shield Hook Deployment ===");
        console2.log("Deployer     :", deployer);
        console2.log("PoolManager  :", poolManager);
        console2.log("Min Deposit  :", minDeposit);
        console2.log("Chain ID     :", block.chainid);
        console2.log("");

        vm.startBroadcast(deployerPk);

        // ── Step 1: Deploy CallbackReceiver (hook address unknown yet) ─────────
        CallbackReceiver callbackReceiver = new CallbackReceiver(address(0));
        console2.log("CallbackReceiver :", address(callbackReceiver));

        // ── Step 2: Mine a salt so the hook address encodes the right flags ────
        // The bottom 14 bits of the hook address must match HOOK_FLAGS.
        // HookMiner iterates salts until it finds one that satisfies this.
        bytes memory constructorArgs = abi.encode(
            IPoolManager(poolManager),
            address(callbackReceiver),
            minDeposit
        );

        (address hookAddress, bytes32 salt) = HookMiner.find(
            CREATE2_PROXY,
            HOOK_FLAGS,
            type(LiquidationShieldHook).creationCode,
            constructorArgs
        );

        console2.log("Hook salt found  :", uint256(salt));
        console2.log("Predicted address:", hookAddress);

        // ── Step 3: Deploy hook at the mined address using CREATE2 ─────────────
        LiquidationShieldHook hook = new LiquidationShieldHook{salt: salt}(
            IPoolManager(poolManager),
            address(callbackReceiver),
            minDeposit
        );

        require(address(hook) == hookAddress, "Deploy: address mismatch");
        console2.log("Hook deployed at :", address(hook));

        // ── Step 4: Wire CallbackReceiver → Hook ───────────────────────────────
        callbackReceiver.setHook(address(hook));
        console2.log("CallbackReceiver: hook set");

        // ── Step 5: Whitelist the Reactive Network relayer (if provided) ───────
        // The relayer is the address Reactive Network uses to call receiveCallback.
        // You can always add it later via callbackReceiver.addAuthorizedCaller().
        if (reactiveRelayer != address(0)) {
            callbackReceiver.addAuthorizedCaller(reactiveRelayer);
            console2.log("Reactive relayer whitelisted:", reactiveRelayer);
        } else {
            console2.log("REACTIVE_RELAYER not set - add it later via addAuthorizedCaller()");
        }

        vm.stopBroadcast();

        // ── Summary ────────────────────────────────────────────────────────────
        console2.log("");
        console2.log("=== Deployment Complete ===");
        console2.log("CallbackReceiver :", address(callbackReceiver));
        console2.log("Hook             :", address(hook));
        console2.log("");
        console2.log("=== Next Step: Deploy HealthFactorMonitor on Reactive Network ===");
        console2.log("Use these values in DeployReactive.s.sol:");
        console2.log("  HOOK_CHAIN_ID        =", block.chainid);
        console2.log("  CALLBACK_RECEIVER    =", address(callbackReceiver));
        console2.log("  HOOK_ADDRESS         =", address(hook));
    }
}
