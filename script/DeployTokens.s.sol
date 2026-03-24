// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script} from "forge-std/Script.sol";
import {MockERC20} from "solmate/src/test/utils/mocks/MockERC20.sol";
import {console} from "forge-std/console.sol";

contract DeployTokens is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        MockERC20 token0 = new MockERC20("Shield Token A", "STA", 18);
        MockERC20 token1 = new MockERC20("Shield Token B", "STB", 18);

        console.log("Token0 deployed at:", address(token0));
        console.log("Token1 deployed at:", address(token1));

        address deployer = vm.addr(deployerPrivateKey);
        token0.mint(deployer, 1000e18);
        token1.mint(deployer, 1000e18);

        vm.stopBroadcast();
    }
}
