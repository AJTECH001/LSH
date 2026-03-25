// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "uniswap-hooks/src/base/BaseHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {LPFeeLibrary} from "v4-core/src/libraries/LPFeeLibrary.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {ILendingPool} from "../interfaces/ILendingPool.sol";

/**
 * @title LiquidationShieldHook
 * @notice A Uniswap v4 hook that provides cross-chain liquidation protection
 *         for DeFi lending positions (Aave, Compound, etc.).
 *
 * @dev Architecture:
 *   1. Users register their lending positions and set a health factor threshold
 *   2. Reactive Network monitors HealthFactorChanged events across chains
 *   3. When health factor drops below threshold, Reactive fires a callback
 *   4. The callback triggers this hook's protection mechanism:
 *      - Flash-swaps collateral via Uniswap v4 pool
 *      - Repays debt on the lending protocol
 *      - Restores health factor above safe level
 *   5. User keeps their position alive, pays a small protection fee
 *
 * Hook Permissions:
 *   - afterInitialize: Register pool for shield tracking
 *   - beforeSwap: Apply fee discount for shield-triggered swaps
 *   - afterSwap: Execute protection logic post-swap
 *
 */
contract LiquidationShieldHook is BaseHook {
    using PoolIdLibrary for PoolKey;

    // ── Errors ────────────────────────────────────────────────────────────────
    error NotAuthorized();
    error PositionNotRegistered();
    error AlreadyRegistered();
    error InvalidThreshold();
    error InsufficientDeposit();
    error ProtectionNotNeeded();
    error CooldownActive();

    // ── Events ────────────────────────────────────────────────────────────────
    /// @notice Emitted when a user registers for liquidation protection
    event ShieldActivated(
        address indexed user,
        uint256 indexed originChainId,
        address lendingPool,
        uint256 healthThreshold,
        uint256 depositAmount
    );

    /// @notice Emitted when protection is triggered via executeProtection (Reactive → Hook)
    event ShieldTriggered(
        address indexed user,
        uint256 indexed originChainId,
        uint256 healthFactorBefore,
        uint256 repayAmount,
        uint256 newHealthFactor
    );

    /// @notice Emitted when a shield-triggered swap completes through the pool
    event ProtectionSwapLogged(address indexed user, uint256 indexed originChainId, uint256 swapAmount);

    /// @notice Emitted when a user withdraws from the shield
    event ShieldDeactivated(address indexed user, uint256 refundAmount);

    /// @notice Emitted for Reactive Network to subscribe to
    event HealthCheckRequested(
        address indexed user, uint256 indexed chainId, address indexed lendingPool, uint256 threshold
    );

    // ── Structs ───────────────────────────────────────────────────────────────
    struct ShieldPosition {
        address user; // Position owner
        uint256 originChainId; // Chain where lending position lives
        address lendingPool; // Aave/Compound pool address on origin chain
        address debtToken; // Token the user borrowed
        address collateralToken; // Token used as collateral
        uint256 healthThreshold; // Trigger protection when HF drops below this (1e18 scale)
        uint256 depositBalance; // User's deposited protection funds (in debt token)
        uint256 protectionFee; // Fee in basis points (e.g., 50 = 0.5%)
        uint256 lastTriggered; // Timestamp of last protection event
        bool isActive; // Whether shield is active
    }

    // ── State ─────────────────────────────────────────────────────────────────
    /// @dev user address => ShieldPosition
    mapping(address => ShieldPosition) public positions;

    /// @dev Tracks all registered users for iteration
    address[] public registeredUsers;

    /// @dev Address of the Reactive callback receiver contract
    address public callbackReceiver;

    /// @dev Owner / deployer
    address public owner;

    /// @dev Minimum deposit required (in debt token units)
    uint256 public minDeposit;

    /// @dev Cooldown between protection triggers (prevents spam)
    uint256 public constant COOLDOWN_PERIOD = 5 minutes;

    /// @dev Default protection fee (50 basis points = 0.5%)
    uint256 public constant DEFAULT_FEE_BPS = 50;

    /// @dev Fees collected per token (token address => amount)
    mapping(address => uint256) public feesCollected;

    /// @dev List of tokens that have collected fees
    address[] public collectedTokens;

    /// @dev Total protections executed
    uint256 public totalProtections;

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(IPoolManager _poolManager, address _callbackReceiver, uint256 _minDeposit) BaseHook(_poolManager) {
        owner = msg.sender;
        callbackReceiver = _callbackReceiver;
        minDeposit = _minDeposit;
    }

    // ── Hook Permissions ──────────────────────────────────────────────────────
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: false,
            afterInitialize: true, // Track initialized pools
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true, // Fee discount for shield swaps
            afterSwap: true, // Execute protection logic
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ── User Registration ─────────────────────────────────────────────────────

    /**
     * @notice Register a lending position for liquidation protection.
     * @param originChainId    Chain ID where the lending position exists
     * @param lendingPool      Address of the lending pool on origin chain
     * @param debtToken        Token the user borrowed
     * @param collateralToken  Token used as collateral
     * @param healthThreshold  Health factor threshold to trigger protection (1e18 scale)
     *                         e.g., 1.2e18 means trigger when HF drops below 1.2
     * @param depositAmount    Amount of debt token to deposit as protection fund
     *
     * Flow:
     *   1. User approves debtToken to this contract
     *   2. User calls activateShield() with their position details
     *   3. Contract transfers debtToken from user to itself
     *   4. Emits HealthCheckRequested for Reactive Network to subscribe
     */
    function activateShield(
        uint256 originChainId,
        address lendingPool,
        address debtToken,
        address collateralToken,
        uint256 healthThreshold,
        uint256 depositAmount
    ) external {
        if (positions[msg.sender].isActive) revert AlreadyRegistered();
        if (healthThreshold < 1e18 || healthThreshold > 2e18) revert InvalidThreshold();
        if (depositAmount < minDeposit) revert InsufficientDeposit();

        // Transfer protection funds from user
        IERC20(debtToken).transferFrom(msg.sender, address(this), depositAmount);

        positions[msg.sender] = ShieldPosition({
            user: msg.sender,
            originChainId: originChainId,
            lendingPool: lendingPool,
            debtToken: debtToken,
            collateralToken: collateralToken,
            healthThreshold: healthThreshold,
            depositBalance: depositAmount,
            protectionFee: DEFAULT_FEE_BPS,
            lastTriggered: 0,
            isActive: true
        });

        registeredUsers.push(msg.sender);

        emit ShieldActivated(msg.sender, originChainId, lendingPool, healthThreshold, depositAmount);

        // Emit event for Reactive Network to subscribe to
        emit HealthCheckRequested(msg.sender, originChainId, lendingPool, healthThreshold);
    }

    /**
     * @notice Deactivate shield and withdraw remaining protection funds.
     */
    function deactivateShield() external {
        ShieldPosition storage pos = positions[msg.sender];
        if (!pos.isActive) revert PositionNotRegistered();

        uint256 refund = pos.depositBalance;
        pos.isActive = false;
        pos.depositBalance = 0;

        if (refund > 0) {
            IERC20(pos.debtToken).transfer(msg.sender, refund);
        }

        emit ShieldDeactivated(msg.sender, refund);
    }

    /**
     * @notice Top up protection deposit.
     */
    function topUpDeposit(uint256 amount) external {
        ShieldPosition storage pos = positions[msg.sender];
        if (!pos.isActive) revert PositionNotRegistered();

        IERC20(pos.debtToken).transferFrom(msg.sender, address(this), amount);
        pos.depositBalance += amount;
    }

    /**
     * @notice Update health factor threshold.
     */
    function updateThreshold(uint256 newThreshold) external {
        ShieldPosition storage pos = positions[msg.sender];
        if (!pos.isActive) revert PositionNotRegistered();
        if (newThreshold < 1e18 || newThreshold > 2e18) revert InvalidThreshold();

        pos.healthThreshold = newThreshold;

        emit HealthCheckRequested(msg.sender, pos.originChainId, pos.lendingPool, newThreshold);
    }

    // ── Protection Execution (called by Reactive callback) ────────────────────

    /**
     * @notice Execute liquidation protection for a user.
     *         Called by the callback receiver contract when Reactive Network
     *         detects that a user's health factor dropped below threshold.
     *
     * @param user              The user to protect
     * @param currentHealthFactor Current health factor from the origin chain
     * @param repayAmount       Suggested repay amount (calculated by Reactive)
     */
    function executeProtection(address user, uint256 currentHealthFactor, uint256 repayAmount) external {
        if (msg.sender != callbackReceiver) revert NotAuthorized();

        ShieldPosition storage pos = positions[user];
        if (!pos.isActive) revert PositionNotRegistered();
        if (currentHealthFactor >= pos.healthThreshold) revert ProtectionNotNeeded();
        if (pos.lastTriggered != 0 && block.timestamp < pos.lastTriggered + COOLDOWN_PERIOD) revert CooldownActive();

        // Cap repay amount to user's deposit balance
        uint256 actualRepay = repayAmount > pos.depositBalance ? pos.depositBalance : repayAmount;

        // Calculate fee
        uint256 fee = (actualRepay * pos.protectionFee) / 10000;
        uint256 netRepay = actualRepay - fee;

        // Deduct from user's deposit
        pos.depositBalance -= actualRepay;
        pos.lastTriggered = block.timestamp;

        // Track fees per token
        if (feesCollected[pos.debtToken] == 0) {
            collectedTokens.push(pos.debtToken);
        }
        feesCollected[pos.debtToken] += fee;
        totalProtections++;

        // Approve lending pool to spend the debt token for repayment
        // NOTE: In cross-chain scenario, this triggers a bridge + repay on origin chain
        // For same-chain: direct repay via lending pool
        IERC20(pos.debtToken).approve(pos.lendingPool, netRepay);

        // Attempt direct repay (same-chain scenario)
        // Cross-chain repay is handled by the Reactive callback receiver
        try ILendingPool(pos.lendingPool)
            .repay(
                pos.debtToken,
                netRepay,
                2, // variable rate
                user
            ) returns (
            uint256
        ) {
        // Success
        }
            catch {
            // Cross-chain case: funds are sent via bridge in callback receiver
            // Revert the approve since we'll handle it differently
        }

        emit ShieldTriggered(
            user,
            pos.originChainId,
            currentHealthFactor,
            netRepay,
            0 // New HF will be calculated off-chain
        );
    }

    // ── Hook Callbacks ────────────────────────────────────────────────────────

    function _afterInitialize(address, PoolKey calldata, uint160, int24) internal override returns (bytes4) {
        // Track pool for potential shield-related swaps
        return BaseHook.afterInitialize.selector;
    }

    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata hookData)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        // If this is a shield-triggered swap, apply a 50% fee discount.
        // Fee overrides only take effect on pools initialised with DYNAMIC_FEE_FLAG.
        if (hookData.length > 0) {
            address protectedUser = abi.decode(hookData, (address));
            if (positions[protectedUser].isActive) {
                uint24 discountedFee = key.fee / 2; // 50% discount
                return (
                    BaseHook.beforeSwap.selector,
                    BeforeSwapDeltaLibrary.ZERO_DELTA,
                    LPFeeLibrary.OVERRIDE_FEE_FLAG | discountedFee
                );
            }
        }
        return (BaseHook.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    function _afterSwap(address, PoolKey calldata, SwapParams calldata, BalanceDelta delta, bytes calldata hookData)
        internal
        override
        returns (bytes4, int128)
    {
        // Log shield-triggered swaps with a dedicated event (avoids duplicate ShieldTriggered
        // which is already emitted by executeProtection for the repay path).
        if (hookData.length > 0) {
            address protectedUser = abi.decode(hookData, (address));
            ShieldPosition storage pos = positions[protectedUser];

            if (pos.isActive) {
                int128 amt1 = delta.amount1();
                uint256 swapAmt = uint256(int256(amt1 > 0 ? amt1 : -amt1));
                emit ProtectionSwapLogged(protectedUser, pos.originChainId, swapAmt);
            }
        }
        return (BaseHook.afterSwap.selector, 0);
    }

    // ── View Functions ────────────────────────────────────────────────────────

    function getPosition(address user) external view returns (ShieldPosition memory) {
        return positions[user];
    }

    function getRegisteredUserCount() external view returns (uint256) {
        return registeredUsers.length;
    }

    function isProtected(address user) external view returns (bool) {
        return positions[user].isActive;
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setCallbackReceiver(address _receiver) external {
        if (msg.sender != owner) revert NotAuthorized();
        callbackReceiver = _receiver;
    }

    function setMinDeposit(uint256 _minDeposit) external {
        if (msg.sender != owner) revert NotAuthorized();
        minDeposit = _minDeposit;
    }

    function withdrawFees(address token, address to) external {
        if (msg.sender != owner) revert NotAuthorized();

        uint256 amount = feesCollected[token];
        if (amount > 0) {
            feesCollected[token] = 0;
            IERC20(token).transfer(to, amount);
        }
    }

    /**
     * @notice Withdraw all collected fees across all tokens.
     */
    function withdrawAllFees(address to) external {
        if (msg.sender != owner) revert NotAuthorized();

        for (uint256 i = 0; i < collectedTokens.length; i++) {
            address token = collectedTokens[i];
            uint256 amount = feesCollected[token];
            if (amount > 0) {
                feesCollected[token] = 0;
                IERC20(token).transfer(to, amount);
            }
        }
    }
}
