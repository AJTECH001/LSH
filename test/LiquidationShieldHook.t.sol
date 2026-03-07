// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "forge-std/Test.sol";
import {Deployers} from "v4-core/test/utils/Deployers.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency, CurrencyLibrary} from "v4-core/src/types/Currency.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {LiquidationShieldHook} from "../src/hooks/LiquidationShieldHook.sol";
import {CallbackReceiver} from "../src/reactive/CallbackReceiver.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

/// @dev Minimal mock that satisfies ILendingPool.repay() for unit tests
contract MockLendingPool {
    function repay(address, uint256, uint256, address) external pure returns (uint256) {
        return 0;
    }
}

/**
 * @title LiquidationShieldHook Tests
 * @notice Comprehensive test suite for the Liquidation Shield Hook.
 *
 * Tests cover:
 *   1. Shield activation / deactivation
 *   2. Deposit management (top-up, withdrawal)
 *   3. Protection execution via callback
 *   4. Hook integration with Uniswap v4 swaps
 *   5. Edge cases (cooldown, unauthorized access, invalid thresholds)
 *
 * Author: Jamiu Damilola Alade
 */
contract LiquidationShieldHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ── Contracts ─────────────────────────────────────────────────────────────
    LiquidationShieldHook public hook;
    CallbackReceiver public callbackReceiver;

    // ── Test Accounts ─────────────────────────────────────────────────────────
    address public deployer = address(0xDEAD);
    address public user1    = address(0x1111);
    address public user2    = address(0x2222);
    address public attacker = address(0xBAD);

    // ── Mock Addresses ────────────────────────────────────────────────────────
    address public mockLendingPool;
    address public mockDebtToken;
    address public mockCollateralToken;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 constant MIN_DEPOSIT = 100e18; // 100 tokens
    uint256 constant INITIAL_BALANCE = 10000e18;

    // ── Setup ─────────────────────────────────────────────────────────────────
    function setUp() public {
        // Deploy PoolManager and routers as the test contract (required by Deployers ownership checks)
        deployFreshManagerAndRouters();
        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();

        mockDebtToken = Currency.unwrap(currency0);
        mockCollateralToken = Currency.unwrap(currency1);

        // Deploy a real mock lending pool so try/catch repay works correctly
        mockLendingPool = address(new MockLendingPool());

        vm.startPrank(deployer);

        // Deploy callback receiver (will set hook later)
        callbackReceiver = new CallbackReceiver(address(0));

        // Hook address must encode permission flags in its lower bits.
        // deployCodeTo etches the bytecode at the exact address we choose.
        uint160 flags = uint160(
            Hooks.AFTER_INITIALIZE_FLAG |
            Hooks.BEFORE_SWAP_FLAG |
            Hooks.AFTER_SWAP_FLAG
        );

        address hookAddress = address(flags);
        deployCodeTo(
            "src/hooks/LiquidationShieldHook.sol:LiquidationShieldHook",
            abi.encode(manager, address(callbackReceiver), MIN_DEPOSIT),
            hookAddress
        );
        hook = LiquidationShieldHook(hookAddress);

        // Set hook in callback receiver
        callbackReceiver.setHook(address(hook));
        callbackReceiver.addAuthorizedCaller(address(callbackReceiver));

        vm.stopPrank();

        // Fund test users
        deal(mockDebtToken, user1, INITIAL_BALANCE);
        deal(mockDebtToken, user2, INITIAL_BALANCE);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Shield Activation Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_ActivateShield() public {
        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 500e18);

        vm.expectEmit(true, true, false, true);
        emit LiquidationShieldHook.ShieldActivated(
            user1,
            SEPOLIA_CHAIN_ID,
            mockLendingPool,
            1.2e18,
            500e18
        );

        hook.activateShield(
            SEPOLIA_CHAIN_ID,
            mockLendingPool,
            mockDebtToken,
            mockCollateralToken,
            1.2e18,     // Trigger at HF < 1.2
            500e18      // Deposit 500 tokens
        );

        vm.stopPrank();

        assertTrue(hook.isProtected(user1));
        assertEq(hook.getRegisteredUserCount(), 1);

        LiquidationShieldHook.ShieldPosition memory pos = hook.getPosition(user1);
        assertEq(pos.user, user1);
        assertEq(pos.originChainId, SEPOLIA_CHAIN_ID);
        assertEq(pos.lendingPool, mockLendingPool);
        assertEq(pos.healthThreshold, 1.2e18);
        assertEq(pos.depositBalance, 500e18);
        assertTrue(pos.isActive);
    }

    function test_ActivateShield_EmitsHealthCheckRequested() public {
        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 500e18);

        vm.expectEmit(true, true, true, true);
        emit LiquidationShieldHook.HealthCheckRequested(
            user1,
            SEPOLIA_CHAIN_ID,
            mockLendingPool,
            1.2e18
        );

        hook.activateShield(
            SEPOLIA_CHAIN_ID,
            mockLendingPool,
            mockDebtToken,
            mockCollateralToken,
            1.2e18,
            500e18
        );

        vm.stopPrank();
    }

    function test_RevertIf_AlreadyRegistered() public {
        _activateShieldForUser(user1);

        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 500e18);

        vm.expectRevert(LiquidationShieldHook.AlreadyRegistered.selector);
        hook.activateShield(
            SEPOLIA_CHAIN_ID,
            mockLendingPool,
            mockDebtToken,
            mockCollateralToken,
            1.2e18,
            500e18
        );
        vm.stopPrank();
    }

    function test_RevertIf_InvalidThreshold_TooLow() public {
        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 500e18);

        vm.expectRevert(LiquidationShieldHook.InvalidThreshold.selector);
        hook.activateShield(
            SEPOLIA_CHAIN_ID,
            mockLendingPool,
            mockDebtToken,
            mockCollateralToken,
            0.5e18,     // Too low — must be >= 1.0
            500e18
        );
        vm.stopPrank();
    }

    function test_RevertIf_InvalidThreshold_TooHigh() public {
        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 500e18);

        vm.expectRevert(LiquidationShieldHook.InvalidThreshold.selector);
        hook.activateShield(
            SEPOLIA_CHAIN_ID,
            mockLendingPool,
            mockDebtToken,
            mockCollateralToken,
            3e18,       // Too high — must be <= 2.0
            500e18
        );
        vm.stopPrank();
    }

    function test_RevertIf_InsufficientDeposit() public {
        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 10e18);

        vm.expectRevert(LiquidationShieldHook.InsufficientDeposit.selector);
        hook.activateShield(
            SEPOLIA_CHAIN_ID,
            mockLendingPool,
            mockDebtToken,
            mockCollateralToken,
            1.2e18,
            10e18       // Below minimum deposit
        );
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Shield Deactivation Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_DeactivateShield() public {
        _activateShieldForUser(user1);

        uint256 balanceBefore = IERC20(mockDebtToken).balanceOf(user1);

        vm.prank(user1);
        hook.deactivateShield();

        assertFalse(hook.isProtected(user1));
        uint256 balanceAfter = IERC20(mockDebtToken).balanceOf(user1);
        assertEq(balanceAfter - balanceBefore, 500e18); // Full refund
    }

    function test_RevertIf_DeactivateWhenNotRegistered() public {
        vm.prank(user1);
        vm.expectRevert(LiquidationShieldHook.PositionNotRegistered.selector);
        hook.deactivateShield();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Deposit Management Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_TopUpDeposit() public {
        _activateShieldForUser(user1);

        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 200e18);
        hook.topUpDeposit(200e18);
        vm.stopPrank();

        LiquidationShieldHook.ShieldPosition memory pos = hook.getPosition(user1);
        assertEq(pos.depositBalance, 700e18); // 500 + 200
    }

    function test_UpdateThreshold() public {
        _activateShieldForUser(user1);

        vm.prank(user1);
        hook.updateThreshold(1.5e18);

        LiquidationShieldHook.ShieldPosition memory pos = hook.getPosition(user1);
        assertEq(pos.healthThreshold, 1.5e18);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Protection Execution Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_ExecuteProtection() public {
        _activateShieldForUser(user1);

        // Simulate callback from Reactive Network
        vm.prank(address(callbackReceiver));

        vm.expectEmit(true, true, false, false);
        emit LiquidationShieldHook.ShieldTriggered(
            user1,
            SEPOLIA_CHAIN_ID,
            1.1e18,
            0,
            0
        );

        hook.executeProtection(
            user1,
            1.1e18,     // Health factor below threshold (1.2)
            100e18      // Repay 100 tokens
        );

        LiquidationShieldHook.ShieldPosition memory pos = hook.getPosition(user1);
        assertEq(pos.depositBalance, 400e18); // 500 - 100
        assertEq(hook.totalProtections(), 1);
    }

    function test_RevertIf_ProtectionFromUnauthorized() public {
        _activateShieldForUser(user1);

        vm.prank(attacker);
        vm.expectRevert(LiquidationShieldHook.NotAuthorized.selector);
        hook.executeProtection(user1, 1.1e18, 100e18);
    }

    function test_RevertIf_ProtectionNotNeeded() public {
        _activateShieldForUser(user1);

        vm.prank(address(callbackReceiver));
        vm.expectRevert(LiquidationShieldHook.ProtectionNotNeeded.selector);
        hook.executeProtection(
            user1,
            1.5e18,     // Health factor ABOVE threshold — no protection needed
            100e18
        );
    }

    function test_RevertIf_CooldownActive() public {
        _activateShieldForUser(user1);

        // First protection
        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 50e18);

        // Second protection within cooldown
        vm.prank(address(callbackReceiver));
        vm.expectRevert(LiquidationShieldHook.CooldownActive.selector);
        hook.executeProtection(user1, 1.1e18, 50e18);
    }

    function test_ExecuteProtection_AfterCooldown() public {
        _activateShieldForUser(user1);

        // First protection
        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 50e18);

        // Advance time past cooldown
        vm.warp(block.timestamp + 6 minutes);

        // Second protection should succeed
        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.05e18, 50e18);

        assertEq(hook.totalProtections(), 2);
    }

    function test_ExecuteProtection_CapsAtDepositBalance() public {
        _activateShieldForUser(user1);

        // Try to repay more than deposit
        vm.prank(address(callbackReceiver));
        hook.executeProtection(
            user1,
            1.1e18,
            1000e18     // More than the 500 deposit
        );

        LiquidationShieldHook.ShieldPosition memory pos = hook.getPosition(user1);
        assertEq(pos.depositBalance, 0); // Capped at full deposit
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Multiple Users Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_MultipleUsersCanRegister() public {
        _activateShieldForUser(user1);
        _activateShieldForUser(user2);

        assertEq(hook.getRegisteredUserCount(), 2);
        assertTrue(hook.isProtected(user1));
        assertTrue(hook.isProtected(user2));
    }

    function test_IndependentProtectionExecution() public {
        _activateShieldForUser(user1);
        _activateShieldForUser(user2);

        // Protect user1 only
        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 100e18);

        // user1 deposit reduced, user2 unchanged
        assertEq(hook.getPosition(user1).depositBalance, 400e18);
        assertEq(hook.getPosition(user2).depositBalance, 500e18);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CallbackReceiver Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_CallbackReceiver_TriggerProtection() public {
        _activateShieldForUser(user1);

        // Add callback receiver as authorized caller on itself
        vm.prank(deployer);
        callbackReceiver.addAuthorizedCaller(deployer);

        // Simulate Reactive Network callback via receiver
        vm.prank(deployer);
        callbackReceiver.triggerProtection(user1, 1.1e18, 100e18);

        assertEq(hook.getPosition(user1).depositBalance, 400e18);
    }

    function test_CallbackReceiver_RejectsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(CallbackReceiver.NotAuthorized.selector);
        callbackReceiver.triggerProtection(user1, 1.1e18, 100e18);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Admin Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_OwnerCanSetCallbackReceiver() public {
        vm.prank(deployer);
        hook.setCallbackReceiver(address(0x9999));
    }

    function test_OwnerCanSetMinDeposit() public {
        vm.prank(deployer);
        hook.setMinDeposit(200e18);
    }

    function test_NonOwnerCannotSetCallbackReceiver() public {
        vm.prank(attacker);
        vm.expectRevert(LiquidationShieldHook.NotAuthorized.selector);
        hook.setCallbackReceiver(address(0x9999));
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════════════

    function _activateShieldForUser(address user) internal {
        vm.startPrank(user);
        IERC20(mockDebtToken).approve(address(hook), 500e18);
        hook.activateShield(
            SEPOLIA_CHAIN_ID,
            mockLendingPool,
            mockDebtToken,
            mockCollateralToken,
            1.2e18,
            500e18
        );
        vm.stopPrank();
    }
}
