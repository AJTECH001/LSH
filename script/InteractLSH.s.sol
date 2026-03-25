// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseScript} from "./base/BaseScript.sol";
import {LiquidityHelpers} from "./base/LiquidityHelpers.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LiquidationShieldHook} from "../src/hooks/LiquidationShieldHook.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {console} from "forge-std/console.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

contract InteractLSH is BaseScript, LiquidityHelpers {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address hookAddr = vm.envAddress("HOOK_ADDRESS");
        address token0Addr = vm.envAddress("TOKEN0_ADDRESS");
        address token1Addr = vm.envAddress("TOKEN1_ADDRESS");

        Currency c0 = Currency.wrap(token0Addr < token1Addr ? token0Addr : token1Addr);
        Currency c1 = Currency.wrap(token0Addr < token1Addr ? token1Addr : token0Addr);

        PoolKey memory poolKey =
            PoolKey({currency0: c0, currency1: c1, fee: 3000, tickSpacing: 60, hooks: LiquidationShieldHook(hookAddr)});

        vm.startBroadcast(deployerPrivateKey);

        // 1. Initialize Pool & Add Liquidity
        uint160 startingPrice = SQRT_PRICE_1_1;
        positionManager.initializePool{value: 0}(poolKey, startingPrice);

        // Approve tokens for Position Manager
        IERC20(Currency.unwrap(c0)).approve(address(permit2), type(uint256).max);
        IERC20(Currency.unwrap(c1)).approve(address(permit2), type(uint256).max);
        permit2.approve(Currency.unwrap(c0), address(positionManager), type(uint160).max, type(uint48).max);
        permit2.approve(Currency.unwrap(c1), address(positionManager), type(uint160).max, type(uint48).max);

        // Add some liquidity
        int24 tickLower = truncateTickSpacing(-600, 60);
        int24 tickUpper = truncateTickSpacing(600, 60);
        uint128 liquidity = 10e18; // simplified

        (bytes memory actions, bytes[] memory params) =
            _mintLiquidityParams(poolKey, tickLower, tickUpper, liquidity, 100e18, 100e18, msg.sender, "");
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);

        // 2. Activate Shield
        IERC20(token0Addr).approve(hookAddr, 10e18);
        LiquidationShieldHook(hookAddr)
            .activateShield(
                11155111, // origin chain
                address(0x123), // mock lending pool
                token0Addr,
                token1Addr,
                1.2e18, // threshold
                10e18 // deposit
            );

        console.log("Shield activated for user:", msg.sender);

        vm.stopBroadcast();
    }
}
