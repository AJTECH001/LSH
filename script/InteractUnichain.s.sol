// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {IAllowanceTransfer} from "permit2/src/interfaces/IAllowanceTransfer.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidationShieldHook} from "../src/hooks/LiquidationShieldHook.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

contract InteractUnichain is Script {
    address constant POSITION_MANAGER = 0xf969Aee60879C54bAAed9F3eD26147Db216Fd664;
    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint256 constant UNICHAIN_CHAIN_ID = 1301;

    // Stored between internal calls to avoid stack pressure in run()
    address private _t0;
    address private _t1;
    address private _hookAddr;
    address private _deployer;

    function run() external {
        uint256 pk = vm.envUint("PRIVATE_KEY");
        _deployer = vm.addr(pk);
        _hookAddr = vm.envAddress("HOOK_ADDRESS");
        address mockPool = vm.envAddress("MOCK_LENDING_POOL");

        {
            address a = vm.envAddress("TOKEN0_ADDRESS");
            address b = vm.envAddress("TOKEN1_ADDRESS");
            (_t0, _t1) = a < b ? (a, b) : (b, a);
        }

        vm.startBroadcast(pk);
        _initPool();
        _approveTokens();
        _addLiquidity();
        _activateShield(mockPool);
        vm.stopBroadcast();
    }

    function _initPool() internal {
        PoolKey memory poolKey = _buildPoolKey();
        IPositionManager(POSITION_MANAGER).initializePool(poolKey, SQRT_PRICE_1_1);
        console.log("Pool initialized");
    }

    function _approveTokens() internal {
        IERC20(_t0).approve(PERMIT2, type(uint256).max);
        IERC20(_t1).approve(PERMIT2, type(uint256).max);
        IAllowanceTransfer(PERMIT2).approve(_t0, POSITION_MANAGER, type(uint160).max, type(uint48).max);
        IAllowanceTransfer(PERMIT2).approve(_t1, POSITION_MANAGER, type(uint160).max, type(uint48).max);
    }

    function _addLiquidity() internal {
        PoolKey memory poolKey = _buildPoolKey();
        bytes memory actions = abi.encodePacked(
            uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE_PAIR), uint8(Actions.SWEEP), uint8(Actions.SWEEP)
        );
        bytes[] memory params = new bytes[](4);
        params[0] = abi.encode(
            poolKey, int24(-600), int24(600), uint128(10e18), uint256(100e18), uint256(100e18), _deployer, bytes("")
        );
        params[1] = abi.encode(Currency.wrap(_t0), Currency.wrap(_t1));
        params[2] = abi.encode(Currency.wrap(_t0), _deployer);
        params[3] = abi.encode(Currency.wrap(_t1), _deployer);
        IPositionManager(POSITION_MANAGER).modifyLiquidities(abi.encode(actions, params), block.timestamp + 3600);
        console.log("Liquidity added");
    }

    function _activateShield(address mockPool) internal {
        IERC20(_t0).approve(_hookAddr, 10e18);
        LiquidationShieldHook(_hookAddr).activateShield(UNICHAIN_CHAIN_ID, mockPool, _t0, _t1, 1.2e18, 10e18);
        console.log("Shield activated for:", _deployer);
    }

    function _buildPoolKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(_t0),
            currency1: Currency.wrap(_t1),
            fee: 3000,
            tickSpacing: 60,
            hooks: LiquidationShieldHook(_hookAddr)
        });
    }
}
