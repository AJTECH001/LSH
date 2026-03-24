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
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {LiquidationShieldHook} from "../src/hooks/LiquidationShieldHook.sol";
import {CallbackReceiver} from "../src/reactive/CallbackReceiver.sol";
import {HealthFactorMonitor} from "../src/reactive/HealthFactorMonitor.sol";
import {IReactive} from "@reactive-lib/interfaces/IReactive.sol";
import {ISubscriptionService} from "../src/interfaces/ISubscriptionService.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

// ─── Mocks ───────────────────────────────────────────────────────────────────

/// @dev Minimal mock that satisfies ILendingPool.repay() for unit tests
contract MockLendingPool {
    function repay(address, uint256, uint256, address) external pure returns (uint256) {
        return 0;
    }
}

/// @dev Mock subscription service for HealthFactorMonitor tests
contract MockSubscriptionService is ISubscriptionService {
    event Subscribed(uint256 chainId, address _contract, uint256 topic_0);

    function subscribe(uint256 chain_id, address _contract, uint256 topic_0, uint256, uint256, uint256)
        external
        override
    {
        emit Subscribed(chain_id, _contract, topic_0);
    }

    function unsubscribe(uint256, address, uint256, uint256, uint256, uint256) external override {}
}

/// @dev Harness to test internal functions and otherwise unreachable modifiers of HealthFactorMonitor
contract HealthFactorMonitorHarness is HealthFactorMonitor {
    constructor(uint256 _cId, address _cb, address _hk, uint256 _oId) HealthFactorMonitor(_cId, _cb, _hk, _oId) {}

    function testRnOnly() external rnOnly {}

    function testCalculateRepay(uint256 curr, uint256 target) external pure returns (uint256) {
        return _calculateRepayAmount(curr, target);
    }
}

/**
 * @title LiquidationShieldHookTest
 * @notice Comprehensive test suite for the Liquidation Shield Hook system.
 *
 * Coverage targets:
 *   LiquidationShieldHook — all branches including fee withdrawal, swap hooks,
 *     zero-balance deactivation, threshold validation, and fee tracking.
 *   CallbackReceiver      — receiveCallback, removeAuthorizedCaller, HookNotSet,
 *     setHook unauthorised, addAuthorizedCaller unauthorised.
 *   HealthFactorMonitor   — react() for all event types, _estimateHealthFactor
 *     branches, _calculateRepayAmount, addMonitoredPosition.
 */
contract LiquidationShieldHookTest is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using CurrencyLibrary for Currency;

    // ── Contracts ─────────────────────────────────────────────────────────────
    LiquidationShieldHook public hook;
    CallbackReceiver public callbackReceiver;

    // ── Pool ──────────────────────────────────────────────────────────────────
    PoolKey poolKey;

    // ── Test Accounts ─────────────────────────────────────────────────────────
    address public deployer = address(0xDEAD);
    address public user1 = address(0x1111);
    address public user2 = address(0x2222);
    address public attacker = address(0xBAD);

    // ── Mock Addresses ────────────────────────────────────────────────────────
    address public mockLendingPool;
    address public mockDebtToken;
    address public mockCollateralToken;

    // ── Constants ─────────────────────────────────────────────────────────────
    uint256 constant SEPOLIA_CHAIN_ID = 11155111;
    uint256 constant MIN_DEPOSIT = 100e18;
    uint256 constant INITIAL_BALANCE = 10_000e18;

    // ── Setup ─────────────────────────────────────────────────────────────────
    function setUp() public {
        deployFreshManagerAndRouters();
        (Currency currency0, Currency currency1) = deployMintAndApprove2Currencies();

        mockDebtToken = Currency.unwrap(currency0);
        mockCollateralToken = Currency.unwrap(currency1);
        mockLendingPool = address(new MockLendingPool());

        vm.startPrank(deployer);

        callbackReceiver = new CallbackReceiver(address(0));

        // Flags: AFTER_INITIALIZE | BEFORE_SWAP | AFTER_SWAP
        uint160 flags = uint160(Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG);
        address hookAddress = address(flags);
        deployCodeTo(
            "src/hooks/LiquidationShieldHook.sol:LiquidationShieldHook",
            abi.encode(manager, address(callbackReceiver), MIN_DEPOSIT),
            hookAddress
        );
        hook = LiquidationShieldHook(hookAddress);

        callbackReceiver.setHook(address(hook));
        callbackReceiver.addAuthorizedCaller(address(callbackReceiver));

        vm.stopPrank();

        // Initialise a real pool so swap callbacks can be exercised
        poolKey = PoolKey(currency0, currency1, 3000, 60, IHooks(hook));
        manager.initialize(poolKey, SQRT_PRICE_1_1);

        // Seed liquidity so swaps don't revert for insufficient liquidity
        modifyLiquidityRouter.modifyLiquidity(
            poolKey,
            ModifyLiquidityParams({
                tickLower: TickMath.minUsableTick(60),
                tickUpper: TickMath.maxUsableTick(60),
                liquidityDelta: 100e18,
                salt: bytes32(0)
            }),
            new bytes(0)
        );

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
        emit LiquidationShieldHook.ShieldActivated(user1, SEPOLIA_CHAIN_ID, mockLendingPool, 1.2e18, 500e18);

        hook.activateShield(SEPOLIA_CHAIN_ID, mockLendingPool, mockDebtToken, mockCollateralToken, 1.2e18, 500e18);
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
        emit LiquidationShieldHook.HealthCheckRequested(user1, SEPOLIA_CHAIN_ID, mockLendingPool, 1.2e18);

        hook.activateShield(SEPOLIA_CHAIN_ID, mockLendingPool, mockDebtToken, mockCollateralToken, 1.2e18, 500e18);
        vm.stopPrank();
    }

    function test_RevertIf_AlreadyRegistered() public {
        _activateShieldForUser(user1);

        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 500e18);
        vm.expectRevert(LiquidationShieldHook.AlreadyRegistered.selector);
        hook.activateShield(SEPOLIA_CHAIN_ID, mockLendingPool, mockDebtToken, mockCollateralToken, 1.2e18, 500e18);
        vm.stopPrank();
    }

    function test_RevertIf_InvalidThreshold_TooLow() public {
        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 500e18);
        vm.expectRevert(LiquidationShieldHook.InvalidThreshold.selector);
        hook.activateShield(SEPOLIA_CHAIN_ID, mockLendingPool, mockDebtToken, mockCollateralToken, 0.5e18, 500e18);
        vm.stopPrank();
    }

    function test_RevertIf_InvalidThreshold_TooHigh() public {
        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 500e18);
        vm.expectRevert(LiquidationShieldHook.InvalidThreshold.selector);
        hook.activateShield(SEPOLIA_CHAIN_ID, mockLendingPool, mockDebtToken, mockCollateralToken, 3e18, 500e18);
        vm.stopPrank();
    }

    function test_RevertIf_InsufficientDeposit() public {
        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 10e18);
        vm.expectRevert(LiquidationShieldHook.InsufficientDeposit.selector);
        hook.activateShield(SEPOLIA_CHAIN_ID, mockLendingPool, mockDebtToken, mockCollateralToken, 1.2e18, 10e18);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Shield Deactivation Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_DeactivateShield() public {
        _activateShieldForUser(user1);

        uint256 balanceBefore = IERC20(mockDebtToken).balanceOf(user1);

        vm.prank(user1);
        vm.expectEmit(true, false, false, true);
        emit LiquidationShieldHook.ShieldDeactivated(user1, 500e18);
        hook.deactivateShield();

        assertFalse(hook.isProtected(user1));
        assertEq(IERC20(mockDebtToken).balanceOf(user1) - balanceBefore, 500e18);
    }

    /// @notice Deactivate after funds fully consumed → refund == 0 branch (no transfer)
    function test_DeactivateShield_ZeroBalance() public {
        _activateShieldForUser(user1);

        // Drain entire deposit
        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 1000e18); // capped to 500e18

        uint256 userBalBefore = IERC20(mockDebtToken).balanceOf(user1);

        vm.prank(user1);
        hook.deactivateShield(); // refund == 0 → no transfer

        assertFalse(hook.isProtected(user1));
        assertEq(IERC20(mockDebtToken).balanceOf(user1), userBalBefore); // unchanged
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

        assertEq(hook.getPosition(user1).depositBalance, 700e18);
    }

    function test_RevertIf_TopUpDeposit_NotRegistered() public {
        vm.startPrank(user1);
        IERC20(mockDebtToken).approve(address(hook), 200e18);
        vm.expectRevert(LiquidationShieldHook.PositionNotRegistered.selector);
        hook.topUpDeposit(200e18);
        vm.stopPrank();
    }

    function test_UpdateThreshold() public {
        _activateShieldForUser(user1);

        vm.prank(user1);
        hook.updateThreshold(1.5e18);

        assertEq(hook.getPosition(user1).healthThreshold, 1.5e18);
    }

    function test_UpdateThreshold_EmitsEvent() public {
        _activateShieldForUser(user1);

        vm.prank(user1);
        vm.expectEmit(true, true, true, true);
        emit LiquidationShieldHook.HealthCheckRequested(user1, SEPOLIA_CHAIN_ID, mockLendingPool, 1.5e18);
        hook.updateThreshold(1.5e18);
    }

    function test_RevertIf_UpdateThreshold_TooLow() public {
        _activateShieldForUser(user1);

        vm.prank(user1);
        vm.expectRevert(LiquidationShieldHook.InvalidThreshold.selector);
        hook.updateThreshold(0.9e18);
    }

    function test_RevertIf_UpdateThreshold_TooHigh() public {
        _activateShieldForUser(user1);

        vm.prank(user1);
        vm.expectRevert(LiquidationShieldHook.InvalidThreshold.selector);
        hook.updateThreshold(2.1e18);
    }

    function test_RevertIf_UpdateThreshold_NotRegistered() public {
        vm.prank(user1);
        vm.expectRevert(LiquidationShieldHook.PositionNotRegistered.selector);
        hook.updateThreshold(1.5e18);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Protection Execution Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_ExecuteProtection() public {
        _activateShieldForUser(user1);

        vm.prank(address(callbackReceiver));
        vm.expectEmit(true, true, false, false);
        emit LiquidationShieldHook.ShieldTriggered(user1, SEPOLIA_CHAIN_ID, 1.1e18, 0, 0);
        hook.executeProtection(user1, 1.1e18, 100e18);

        LiquidationShieldHook.ShieldPosition memory pos = hook.getPosition(user1);
        assertEq(pos.depositBalance, 400e18);
        assertEq(hook.totalProtections(), 1);
    }

    /// @notice Fees are tracked in feesCollected and collectedTokens (first-time push)
    function test_ExecuteProtection_FeeTracking() public {
        _activateShieldForUser(user1);

        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 100e18);

        // fee = 100e18 * 50 / 10000 = 0.5e18
        uint256 expectedFee = (100e18 * 50) / 10000;
        assertEq(hook.feesCollected(mockDebtToken), expectedFee);
    }

    /// @notice Second same-token protection hits the already-collected branch (>0 check)
    function test_ExecuteProtection_FeeTracking_SecondTime() public {
        _activateShieldForUser(user1);

        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 50e18);

        vm.warp(block.timestamp + 6 minutes);

        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.05e18, 50e18);

        uint256 expectedTotal = (50e18 * 50) / 10000 * 2;
        assertEq(hook.feesCollected(mockDebtToken), expectedTotal);
    }

    function test_RevertIf_ProtectionFromUnauthorized() public {
        _activateShieldForUser(user1);

        vm.prank(attacker);
        vm.expectRevert(LiquidationShieldHook.NotAuthorized.selector);
        hook.executeProtection(user1, 1.1e18, 100e18);
    }

    function test_RevertIf_ExecuteProtection_NotRegistered() public {
        vm.prank(address(callbackReceiver));
        vm.expectRevert(LiquidationShieldHook.PositionNotRegistered.selector);
        hook.executeProtection(user1, 1.1e18, 100e18);
    }

    function test_RevertIf_ProtectionNotNeeded() public {
        _activateShieldForUser(user1);

        vm.prank(address(callbackReceiver));
        vm.expectRevert(LiquidationShieldHook.ProtectionNotNeeded.selector);
        hook.executeProtection(user1, 1.5e18, 100e18);
    }

    function test_RevertIf_CooldownActive() public {
        _activateShieldForUser(user1);

        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 50e18);

        vm.prank(address(callbackReceiver));
        vm.expectRevert(LiquidationShieldHook.CooldownActive.selector);
        hook.executeProtection(user1, 1.1e18, 50e18);
    }

    function test_ExecuteProtection_AfterCooldown() public {
        _activateShieldForUser(user1);

        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 50e18);

        vm.warp(block.timestamp + 6 minutes);

        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.05e18, 50e18);

        assertEq(hook.totalProtections(), 2);
    }

    function test_ExecuteProtection_CapsAtDepositBalance() public {
        _activateShieldForUser(user1);

        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 1000e18);

        assertEq(hook.getPosition(user1).depositBalance, 0);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Fee Withdrawal Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_WithdrawFees() public {
        _activateShieldForUser(user1);
        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 100e18);

        uint256 expectedFee = (100e18 * 50) / 10000;
        address receiver = makeAddr("feeReceiver");
        uint256 before = IERC20(mockDebtToken).balanceOf(receiver);

        vm.prank(deployer);
        hook.withdrawFees(mockDebtToken, receiver);

        assertEq(IERC20(mockDebtToken).balanceOf(receiver) - before, expectedFee);
        assertEq(hook.feesCollected(mockDebtToken), 0);
    }

    /// @notice withdrawFees with zero balance → inner if(amount > 0) not taken
    function test_WithdrawFees_ZeroAmount_IsNoop() public {
        address receiver = makeAddr("feeReceiver");
        uint256 before = IERC20(mockDebtToken).balanceOf(receiver);

        vm.prank(deployer);
        hook.withdrawFees(mockDebtToken, receiver);

        assertEq(IERC20(mockDebtToken).balanceOf(receiver), before);
    }

    function test_RevertIf_WithdrawFees_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(LiquidationShieldHook.NotAuthorized.selector);
        hook.withdrawFees(mockDebtToken, attacker);
    }

    function test_WithdrawAllFees() public {
        _activateShieldForUser(user1);
        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 100e18);

        uint256 expectedFee = (100e18 * 50) / 10000;
        address receiver = makeAddr("feeReceiver");

        vm.prank(deployer);
        hook.withdrawAllFees(receiver);

        assertEq(IERC20(mockDebtToken).balanceOf(receiver), expectedFee);
        assertEq(hook.feesCollected(mockDebtToken), 0);
    }

    /// @notice withdrawAllFees when no fees have been collected (empty loop)
    function test_WithdrawAllFees_Empty() public {
        address receiver = makeAddr("feeReceiver");
        vm.prank(deployer);
        hook.withdrawAllFees(receiver); // no-op, collectedTokens empty
    }

    function test_RevertIf_WithdrawAllFees_NotOwner() public {
        vm.prank(attacker);
        vm.expectRevert(LiquidationShieldHook.NotAuthorized.selector);
        hook.withdrawAllFees(attacker);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Hook Callback Tests (_beforeSwap / _afterSwap)
    // ══════════════════════════════════════════════════════════════════════════

    /// @notice _beforeSwap with hookData encoding an ACTIVE user → fee discount branch
    function test_BeforeSwap_WithActiveUserHookData() public {
        _activateShieldForUser(user1);

        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(user1)
        );
    }

    /// @notice _beforeSwap with hookData encoding an INACTIVE user → fallback branch
    function test_BeforeSwap_WithInactiveUserHookData() public {
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(user1) // user1 not registered
        );
    }

    /// @notice _beforeSwap and _afterSwap with no hookData (length == 0)
    function test_Swap_NoHookData() public {
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            new bytes(0)
        );
    }

    /// @notice _afterSwap with active user hookData emits ProtectionSwapLogged (not ShieldTriggered)
    function test_AfterSwap_WithActiveUserHookData() public {
        _activateShieldForUser(user1);

        vm.expectEmit(true, true, false, false);
        emit LiquidationShieldHook.ProtectionSwapLogged(user1, SEPOLIA_CHAIN_ID, 0);

        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            abi.encode(user1)
        );
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

        vm.prank(address(callbackReceiver));
        hook.executeProtection(user1, 1.1e18, 100e18);

        assertEq(hook.getPosition(user1).depositBalance, 400e18);
        assertEq(hook.getPosition(user2).depositBalance, 500e18);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Admin Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_OwnerCanSetCallbackReceiver() public {
        vm.prank(deployer);
        hook.setCallbackReceiver(address(0x9999));
        assertEq(hook.callbackReceiver(), address(0x9999));
    }

    function test_OwnerCanSetMinDeposit() public {
        vm.prank(deployer);
        hook.setMinDeposit(200e18);
        assertEq(hook.minDeposit(), 200e18);
    }

    function test_NonOwnerCannotSetCallbackReceiver() public {
        vm.prank(attacker);
        vm.expectRevert(LiquidationShieldHook.NotAuthorized.selector);
        hook.setCallbackReceiver(address(0x9999));
    }

    function test_NonOwnerCannotSetMinDeposit() public {
        vm.prank(attacker);
        vm.expectRevert(LiquidationShieldHook.NotAuthorized.selector);
        hook.setMinDeposit(200e18);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // CallbackReceiver Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_CallbackReceiver_TriggerProtection() public {
        _activateShieldForUser(user1);

        vm.prank(deployer);
        callbackReceiver.addAuthorizedCaller(deployer);

        vm.prank(deployer);
        callbackReceiver.triggerProtection(user1, 1.1e18, 100e18);

        assertEq(hook.getPosition(user1).depositBalance, 400e18);
    }

    function test_CallbackReceiver_RejectsUnauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(CallbackReceiver.NotAuthorized.selector);
        callbackReceiver.triggerProtection(user1, 1.1e18, 100e18);
    }

    /// @notice receiveCallback forwards a raw ABI-encoded executeProtection payload
    function test_CallbackReceiver_ReceiveCallback() public {
        _activateShieldForUser(user1);

        vm.prank(deployer);
        callbackReceiver.addAuthorizedCaller(deployer);

        bytes memory payload = abi.encodeWithSelector(
            bytes4(keccak256("executeProtection(address,uint256,uint256)")), user1, uint256(1.1e18), uint256(50e18)
        );

        vm.prank(deployer);
        vm.expectEmit(true, false, false, true);
        emit CallbackReceiver.CallbackReceived(user1, 1.1e18, 50e18);
        callbackReceiver.receiveCallback(payload);

        assertEq(hook.getPosition(user1).depositBalance, 450e18);
    }

    function test_CallbackReceiver_ReceiveCallback_Unauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(CallbackReceiver.NotAuthorized.selector);
        callbackReceiver.receiveCallback(new bytes(32));
    }

    function test_CallbackReceiver_TriggerProtection_HookNotSet() public {
        vm.prank(deployer);
        CallbackReceiver fresh = new CallbackReceiver(address(0));

        vm.prank(deployer);
        vm.expectRevert(CallbackReceiver.HookNotSet.selector);
        fresh.triggerProtection(user1, 1.1e18, 100e18);
    }

    function test_CallbackReceiver_ReceiveCallback_HookNotSet() public {
        vm.prank(deployer);
        CallbackReceiver fresh = new CallbackReceiver(address(0));

        bytes memory payload = abi.encodeWithSelector(
            bytes4(keccak256("executeProtection(address,uint256,uint256)")), user1, uint256(1.1e18), uint256(50e18)
        );

        vm.prank(deployer);
        vm.expectRevert(CallbackReceiver.HookNotSet.selector);
        fresh.receiveCallback(payload);
    }

    function test_CallbackReceiver_SetHook() public {
        vm.prank(deployer);
        callbackReceiver.setHook(address(0x1234));
        assertEq(callbackReceiver.hook(), address(0x1234));
    }

    function test_CallbackReceiver_SetHook_Unauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(CallbackReceiver.NotAuthorized.selector);
        callbackReceiver.setHook(address(0x1234));
    }

    function test_CallbackReceiver_RemoveAuthorizedCaller() public {
        vm.startPrank(deployer);
        callbackReceiver.addAuthorizedCaller(user1);
        callbackReceiver.removeAuthorizedCaller(user1);
        vm.stopPrank();

        assertFalse(callbackReceiver.authorizedCallers(user1));

        vm.prank(user1);
        vm.expectRevert(CallbackReceiver.NotAuthorized.selector);
        callbackReceiver.triggerProtection(address(0), 0, 0);
    }

    function test_CallbackReceiver_RemoveAuthorizedCaller_Unauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(CallbackReceiver.NotAuthorized.selector);
        callbackReceiver.removeAuthorizedCaller(deployer);
    }

    function test_CallbackReceiver_AddAuthorizedCaller_Unauthorized() public {
        vm.prank(attacker);
        vm.expectRevert(CallbackReceiver.NotAuthorized.selector);
        callbackReceiver.addAuthorizedCaller(user1);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // HealthFactorMonitor Tests
    // ══════════════════════════════════════════════════════════════════════════

    MockSubscriptionService subService;
    HealthFactorMonitor monitor;

    uint256 constant BORROW_SIG_U = uint256(keccak256("Borrow(address,address,address,uint256,uint8,uint256,uint16)"));
    uint256 constant REPAY_SIG_U = uint256(keccak256("Repay(address,address,address,uint256,bool)"));
    uint256 constant LIQUIDATION_SIG_U =
        uint256(keccak256("LiquidationCall(address,address,address,uint256,uint256,address,bool)"));
    uint256 constant HEALTH_CHECK_SIG_U = uint256(keccak256("HealthCheckRequested(address,uint256,address,uint256)"));

    function _deployMonitor() internal returns (HealthFactorMonitor m) {
        subService = new MockSubscriptionService();
        m = new HealthFactorMonitor(
            1, // hookChainId
            address(callbackReceiver),
            address(hook),
            SEPOLIA_CHAIN_ID
        );
        // Etch MockSubscriptionService code at the system contract address so that
        // service.subscribe() calls succeed in tests (Solidity 0.8.x rejects calls
        // to addresses with no code when using an interface type).
        vm.etch(address(0x0000000000000000000000000000000000fffFfF), address(subService).code);
    }

    function _buildLog(uint256 topic0, uint256 topic1, uint256 topic2, uint256 topic3, bytes memory data)
        internal
        pure
        returns (IReactive.LogRecord memory)
    {
        return IReactive.LogRecord({
            chain_id: SEPOLIA_CHAIN_ID,
            _contract: address(0),
            topic_0: topic0,
            topic_1: topic1,
            topic_2: topic2,
            topic_3: topic3,
            data: data,
            block_number: 1,
            op_code: 0,
            block_hash: 0,
            tx_hash: 0,
            log_index: 0
        });
    }

    function test_Monitor_Deploy() public {
        monitor = _deployMonitor();
        assertEq(monitor.hookChainId(), 1);
        assertEq(monitor.callbackReceiver(), address(callbackReceiver));
        assertEq(monitor.hookAddress(), address(hook));
    }

    /// @notice react() with HEALTH_CHECK_SIG registers a position and subscribes
    function test_Monitor_React_HealthCheckRequest() public {
        monitor = _deployMonitor();

        address monUser = makeAddr("monUser");

        IReactive.LogRecord memory log = _buildLog(
            HEALTH_CHECK_SIG_U,
            uint256(uint160(monUser)),
            uint256(SEPOLIA_CHAIN_ID),
            uint256(uint160(mockLendingPool)),
            abi.encode(uint256(1.2e18))
        );

        vm.expectEmit(true, false, false, true);
        emit HealthFactorMonitor.PositionMonitored(monUser, SEPOLIA_CHAIN_ID, mockLendingPool);
        monitor.react(log);

        (uint256 chainId,, uint256 ht, bool isActive) = monitor.monitoredPositions(monUser);
        assertEq(chainId, SEPOLIA_CHAIN_ID);
        assertEq(ht, 1.2e18);
        assertTrue(isActive);
    }

    /// @notice react() with BORROW_SIG for monitored user below threshold → fires callback
    function test_Monitor_React_BorrowEvent_BelowThreshold() public {
        monitor = _deployMonitor();
        address monUser = makeAddr("monUser");

        // Register user
        monitor.react(
            _buildLog(
                HEALTH_CHECK_SIG_U,
                uint256(uint160(monUser)),
                uint256(SEPOLIA_CHAIN_ID),
                uint256(uint160(mockLendingPool)),
                abi.encode(uint256(1.2e18))
            )
        );

        // Borrow event with data ≥ 32 bytes → _estimateHealthFactor returns 1.1e18 < 1.2
        vm.expectEmit(true, false, false, false);
        emit HealthFactorMonitor.ProtectionCallbackSent(monUser, 0, 0);
        monitor.react(_buildLog(BORROW_SIG_U, 0, uint256(uint160(monUser)), 0, abi.encode(uint256(1000e18))));
    }

    /// @notice react() with REPAY_SIG for monitored user → _estimateHealthFactor returns 1.5e18 (no callback)
    function test_Monitor_React_RepayEvent_AboveThreshold() public {
        monitor = _deployMonitor();
        address monUser = makeAddr("monUser2");

        monitor.react(
            _buildLog(
                HEALTH_CHECK_SIG_U,
                uint256(uint160(monUser)),
                uint256(SEPOLIA_CHAIN_ID),
                uint256(uint160(mockLendingPool)),
                abi.encode(uint256(1.2e18))
            )
        );

        // Repay with data: topic_0 != BORROW_SIG → returns safe 1.5e18 → no callback
        monitor.react(_buildLog(REPAY_SIG_U, 0, uint256(uint160(monUser)), 0, abi.encode(uint256(500e18))));
    }

    /// @notice react() with BORROW_SIG but empty data → _estimateHealthFactor returns 1.5e18 (no callback)
    function test_Monitor_React_BorrowEvent_EmptyData_AboveThreshold() public {
        monitor = _deployMonitor();
        address monUser = makeAddr("monUser3");

        monitor.react(
            _buildLog(
                HEALTH_CHECK_SIG_U,
                uint256(uint160(monUser)),
                uint256(SEPOLIA_CHAIN_ID),
                uint256(uint160(mockLendingPool)),
                abi.encode(uint256(1.2e18))
            )
        );

        // Borrow event but data.length < 32 → safe default 1.5e18
        monitor.react(_buildLog(BORROW_SIG_U, 0, uint256(uint160(monUser)), 0, new bytes(0)));
    }

    /// @notice react() with LIQUIDATION_SIG for monitored user
    function test_Monitor_React_LiquidationEvent() public {
        monitor = _deployMonitor();
        address monUser = makeAddr("monUser4");

        monitor.react(
            _buildLog(
                HEALTH_CHECK_SIG_U,
                uint256(uint160(monUser)),
                uint256(SEPOLIA_CHAIN_ID),
                uint256(uint160(mockLendingPool)),
                abi.encode(uint256(1.2e18))
            )
        );

        monitor.react(
            _buildLog(
                LIQUIDATION_SIG_U,
                0,
                uint256(uint160(monUser)),
                0,
                new bytes(0) // no data → 1.5e18 safe (above 1.2)
            )
        );
    }

    /// @notice react() with unrecognized topic_0 → no-op
    function test_Monitor_React_UnknownEventSig() public {
        monitor = _deployMonitor();

        monitor.react(_buildLog(uint256(keccak256("Unknown()")), 0, 0, 0, new bytes(0)));
    }

    /// @notice react() lending event for user NOT in monitoredPositions → early return
    function test_Monitor_React_UnmonitoredUser() public {
        monitor = _deployMonitor();

        address unknown = makeAddr("unknown");

        monitor.react(_buildLog(BORROW_SIG_U, 0, uint256(uint160(unknown)), 0, abi.encode(uint256(1000e18))));
        // Should not emit ProtectionCallbackSent
    }

    function test_Monitor_AddMonitoredPosition() public {
        monitor = _deployMonitor();

        address monUser = makeAddr("manualUser");
        monitor.addMonitoredPosition(monUser, SEPOLIA_CHAIN_ID, mockLendingPool, 1.3e18);

        (,, uint256 ht, bool isActive) = monitor.monitoredPositions(monUser);
        assertEq(ht, 1.3e18);
        assertTrue(isActive);
    }

    function test_Monitor_AddMonitoredPosition_NotOwner() public {
        monitor = _deployMonitor();

        vm.prank(attacker);
        vm.expectRevert("Not owner");
        monitor.addMonitoredPosition(address(0), 1, address(0), 1e18);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // View / State helpers
    // ══════════════════════════════════════════════════════════════════════════

    function test_IsProtected_False_WhenNotRegistered() public view {
        assertFalse(hook.isProtected(user1));
    }

    function test_GetRegisteredUserCount_Zero() public view {
        assertEq(hook.getRegisteredUserCount(), 0);
    }

    function test_Constants() public view {
        assertEq(hook.COOLDOWN_PERIOD(), 5 minutes);
        assertEq(hook.DEFAULT_FEE_BPS(), 50);
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Helpers
    // ══════════════════════════════════════════════════════════════════════════

    function _activateShieldForUser(address user) internal {
        vm.startPrank(user);
        IERC20(mockDebtToken).approve(address(hook), 500e18);
        hook.activateShield(SEPOLIA_CHAIN_ID, mockLendingPool, mockDebtToken, mockCollateralToken, 1.2e18, 500e18);
        vm.stopPrank();
    }

    // ══════════════════════════════════════════════════════════════════════════
    // Additional Coverage Tests
    // ══════════════════════════════════════════════════════════════════════════

    function test_Monitor_ReceiveETH() public {
        monitor = _deployMonitor();
        deal(user1, 1 ether);
        vm.prank(user1);
        (bool success,) = address(monitor).call{value: 1 ether}("");
        assertTrue(success);
        assertEq(address(monitor).balance, 1 ether);
    }

    function test_Monitor_Constructor_RNEnv() public {
        _deployMonitor(); // Initialize subService
        // Etch code to SYSTEM_CONTRACT to mock RN environment
        address sysContract = 0x0000000000000000000000000000000000fffFfF;
        vm.etch(sysContract, bytes("mock code"));

        // This deployment will now execute the `if (!vm)` branch and subscribe
        HealthFactorMonitor rnMonitor =
            new HealthFactorMonitor(1, address(callbackReceiver), address(hook), SEPOLIA_CHAIN_ID);

        assertEq(rnMonitor.hookChainId(), 1);

        // Cleanup etch so it doesn't break other tests
        vm.etch(sysContract, bytes(""));
    }

    function test_Monitor_Harness_RnOnly_Revert() public {
        _deployMonitor();
        // Clear etch so 0xfffFfF has no code → detectVm sets vm=true → rnOnly reverts
        vm.etch(address(0x0000000000000000000000000000000000fffFfF), bytes(""));
        HealthFactorMonitorHarness harness =
            new HealthFactorMonitorHarness(1, address(callbackReceiver), address(hook), SEPOLIA_CHAIN_ID);
        vm.expectRevert("Reactive Network only");
        harness.testRnOnly();
    }

    function test_Monitor_Harness_RnOnly_Success() public {
        _deployMonitor(); // Initialize subService
        address sysContract = 0x0000000000000000000000000000000000fffFfF;
        vm.etch(sysContract, bytes("mock code"));

        HealthFactorMonitorHarness harness =
            new HealthFactorMonitorHarness(1, address(callbackReceiver), address(hook), SEPOLIA_CHAIN_ID);

        harness.testRnOnly(); // should not revert

        vm.etch(sysContract, bytes(""));
    }

    function test_Monitor_Harness_CalculateRepay_GtTarget() public {
        _deployMonitor();
        HealthFactorMonitorHarness harness =
            new HealthFactorMonitorHarness(1, address(callbackReceiver), address(hook), SEPOLIA_CHAIN_ID);
        assertEq(harness.testCalculateRepay(1.5e18, 1.2e18), 0);
    }
}
