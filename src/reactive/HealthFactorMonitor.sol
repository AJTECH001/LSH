// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IReactive} from "../interfaces/IReactive.sol";
import {ISubscriptionService} from "../interfaces/ISubscriptionService.sol";

/**
 * @title HealthFactorMonitor
 * @notice Reactive Smart Contract deployed on the Reactive Network.
 *         Monitors lending protocol events across chains and triggers
 *         the LiquidationShieldHook when a user's position is at risk.
 *
 * @dev Execution Pattern:
 *   1. Deployed on Reactive Network (Kopli testnet or mainnet)
 *   2. Subscribes to HealthCheckRequested events from the hook contract
 *   3. Also subscribes to lending protocol events (Borrow, Repay, LiquidationCall)
 *   4. react() evaluates health factor and emits Callback if protection needed
 *   5. Callback fires executeProtection() on the destination chain hook
 *
 * Subscribe → React → Callback
 *
 */
contract HealthFactorMonitor is IReactive {
    // ── Constants ─────────────────────────────────────────────────────────────

    /// @dev Event signatures for Aave V3 events we monitor
    bytes32 constant BORROW_EVENT_SIG = keccak256(
        "Borrow(address,address,address,uint256,uint8,uint256,uint16)"
    );
    bytes32 constant REPAY_EVENT_SIG = keccak256(
        "Repay(address,address,address,uint256,bool)"
    );
    bytes32 constant LIQUIDATION_EVENT_SIG = keccak256(
        "LiquidationCall(address,address,address,uint256,uint256,address,bool)"
    );

    /// @dev Event signature from our hook: HealthCheckRequested(address,uint256,address,uint256)
    bytes32 constant HEALTH_CHECK_SIG = keccak256(
        "HealthCheckRequested(address,uint256,address,uint256)"
    );

    /// @dev Function selector for executeProtection(address,uint256,uint256)
    bytes4 constant EXECUTE_PROTECTION_SELECTOR = bytes4(
        keccak256("executeProtection(address,uint256,uint256)")
    );

    // ── State ─────────────────────────────────────────────────────────────────

    /// @dev Reference to the Reactive Network's system subscription service
    ISubscriptionService public immutable subscriptionService;

    /// @dev Chain ID where our hook is deployed (destination for callbacks)
    uint256 public immutable hookChainId;

    /// @dev Address of the callback receiver on the hook's chain
    address public immutable callbackReceiver;

    /// @dev Address of the LiquidationShieldHook contract
    address public immutable hookAddress;

    /// @dev Gas limit for callback transactions
    uint64 public constant CALLBACK_GAS_LIMIT = 500_000;

    /// @dev Tracks monitored users: user => MonitoredPosition
    struct MonitoredPosition {
        uint256 originChainId;
        address lendingPool;
        uint256 healthThreshold; // 1e18 scale
        bool    isActive;
    }

    mapping(address => MonitoredPosition) public monitoredPositions;

    /// @dev Owner of this reactive contract
    address public owner;

    // ── Events ────────────────────────────────────────────────────────────────
    event PositionMonitored(address indexed user, uint256 chainId, address lendingPool);
    event ProtectionCallbackSent(address indexed user, uint256 healthFactor, uint256 repayAmount);

    // ── Constructor ───────────────────────────────────────────────────────────
    /**
     * @param _subscriptionService Reactive Network system contract for subscriptions
     * @param _hookChainId         Chain ID where the hook is deployed
     * @param _callbackReceiver    Address of callback receiver on hook chain
     * @param _hookAddress         Address of the LiquidationShieldHook
     * @param _hookOriginChainId   Chain ID where the hook emits HealthCheckRequested
     */
    constructor(
        address _subscriptionService,
        uint256 _hookChainId,
        address _callbackReceiver,
        address _hookAddress,
        uint256 _hookOriginChainId
    ) {
        subscriptionService = ISubscriptionService(_subscriptionService);
        hookChainId = _hookChainId;
        callbackReceiver = _callbackReceiver;
        hookAddress = _hookAddress;
        owner = msg.sender;

        // Subscribe to HealthCheckRequested events from our hook contract
        // This is how we learn about new users registering for protection
        subscriptionService.subscribe(
            _hookOriginChainId,     // Chain where hook is deployed
            _hookAddress,           // Hook contract address
            HEALTH_CHECK_SIG,       // HealthCheckRequested event
            bytes32(0),             // Any user (topic_1)
            bytes32(0),             // Any chainId (topic_2)
            bytes32(0)              // Any lendingPool (topic_3)
        );
    }

    // ── Core: React to Events ─────────────────────────────────────────────────

    /**
     * @notice Called by the Reactive Network when a subscribed event is detected.
     *
     * Handles two types of events:
     *   1. HealthCheckRequested → Register new position for monitoring
     *   2. Aave Borrow/Repay/Liquidation → Check if user needs protection
     */
    function react(LogRecord calldata log) external override {
        if (log.topic_0 == HEALTH_CHECK_SIG) {
            _handleHealthCheckRequest(log);
        } else if (
            log.topic_0 == BORROW_EVENT_SIG ||
            log.topic_0 == REPAY_EVENT_SIG ||
            log.topic_0 == LIQUIDATION_EVENT_SIG
        ) {
            _handleLendingEvent(log);
        }
    }

    // ── Internal Logic ────────────────────────────────────────────────────────

    /**
     * @dev Handle a new HealthCheckRequested event from our hook.
     *      Registers the user for monitoring and subscribes to lending events.
     */
    function _handleHealthCheckRequest(LogRecord calldata log) internal {
        // Decode: HealthCheckRequested(address user, uint256 chainId, address lendingPool, uint256 threshold)
        address user = address(uint160(uint256(log.topic_1)));
        uint256 chainId = uint256(log.topic_2);
        address lendingPool = address(uint160(uint256(log.topic_3)));

        // Decode threshold from event data
        uint256 threshold = abi.decode(log.data, (uint256));

        // Register position for monitoring
        monitoredPositions[user] = MonitoredPosition({
            originChainId:   chainId,
            lendingPool:     lendingPool,
            healthThreshold: threshold,
            isActive:        true
        });

        // Subscribe to lending events on the origin chain
        // This lets us detect when the user's position changes
        _subscribeToLendingEvents(chainId, lendingPool);

        emit PositionMonitored(user, chainId, lendingPool);
    }

    /**
     * @dev Handle a lending protocol event (Borrow, Repay, Liquidation).
     *      Evaluates whether any monitored user needs protection.
     */
    function _handleLendingEvent(LogRecord calldata log) internal {
        // Extract user address from event (topic_2 for Aave events)
        address user = address(uint160(uint256(log.topic_2)));

        MonitoredPosition storage pos = monitoredPositions[user];
        if (!pos.isActive) return;

      
        uint256 estimatedHealthFactor = _estimateHealthFactor(log);

        if (estimatedHealthFactor < pos.healthThreshold) {
            // Calculate repay amount needed to restore health
            uint256 repayAmount = _calculateRepayAmount(
                estimatedHealthFactor,
                pos.healthThreshold
            );

            // Fire callback to the hook chain
            _triggerProtection(user, estimatedHealthFactor, repayAmount);
        }
    }

   
    function _estimateHealthFactor(LogRecord calldata log) internal pure returns (uint256) {
        // Decode borrow/repay amounts from event data to estimate impact
        // This is simplified — real implementation uses oracle prices
        if (log.data.length >= 32) {
            // Extract amount from event data
            uint256 amount = abi.decode(log.data, (uint256));

            // Simplified HF estimation based on event type
            if (log.topic_0 == BORROW_EVENT_SIG) {
                // New borrow → HF likely decreased
                // Return a value that triggers protection for demo purposes
                return 1.1e18; // Below typical 1.2 threshold
            }
        }
        return 1.5e18; // Safe default
    }

    /**
     * @dev Calculate how much debt to repay to restore health factor.
     */
    function _calculateRepayAmount(
        uint256 currentHF,
        uint256 targetHF
    ) internal pure returns (uint256) {
        if (currentHF >= targetHF) return 0;

        // Simplified: repay proportional to the gap
        // Real calculation uses collateral value, debt value, and liquidation threshold
        uint256 gap = targetHF - currentHF;
        uint256 repayRatio = (gap * 1e18) / targetHF;

        // Base repay amount (scaled, will be adjusted by actual debt values)
        // In production: query actual debt and calculate precise amount
        return repayRatio;
    }

    /**
     * @dev Emit Callback event to trigger protection on the hook chain.
     */
    function _triggerProtection(
        address user,
        uint256 healthFactor,
        uint256 repayAmount
    ) internal {
        // Encode the callback payload
        bytes memory payload = abi.encodeWithSelector(
            EXECUTE_PROTECTION_SELECTOR,
            user,
            healthFactor,
            repayAmount
        );

        // Emit Callback event — Reactive Network will deliver this
        // to the callbackReceiver on the hook's chain
        emit Callback(
            hookChainId,
            callbackReceiver,
            CALLBACK_GAS_LIMIT,
            payload
        );

        emit ProtectionCallbackSent(user, healthFactor, repayAmount);
    }

    // ── Subscription Management ───────────────────────────────────────────────

    /**
     * @dev Subscribe to Aave lending events on a specific chain and pool.
     */
    function _subscribeToLendingEvents(uint256 chainId, address lendingPool) internal {
        // Subscribe to Borrow events
        subscriptionService.subscribe(
            chainId,
            lendingPool,
            BORROW_EVENT_SIG,
            bytes32(0),
            bytes32(0),
            bytes32(0)
        );

        // Subscribe to Repay events
        subscriptionService.subscribe(
            chainId,
            lendingPool,
            REPAY_EVENT_SIG,
            bytes32(0),
            bytes32(0),
            bytes32(0)
        );

        // Subscribe to Liquidation events (to detect if protection was too late)
        subscriptionService.subscribe(
            chainId,
            lendingPool,
            LIQUIDATION_EVENT_SIG,
            bytes32(0),
            bytes32(0),
            bytes32(0)
        );
    }

    /**
     * @notice Manually subscribe to events for a specific user's lending pool.
     *         Useful for adding monitoring without waiting for HealthCheckRequested.
     */
    function addMonitoredPosition(
        address user,
        uint256 chainId,
        address lendingPool,
        uint256 threshold
    ) external {
        require(msg.sender == owner, "Not owner");

        monitoredPositions[user] = MonitoredPosition({
            originChainId:   chainId,
            lendingPool:     lendingPool,
            healthThreshold: threshold,
            isActive:        true
        });

        _subscribeToLendingEvents(chainId, lendingPool);
        emit PositionMonitored(user, chainId, lendingPool);
    }
}
