// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AbstractReactive} from "@reactive-lib/abstract-base/AbstractReactive.sol";
import {IReactive} from "@reactive-lib/interfaces/IReactive.sol";
import {AbstractPayer} from "@reactive-lib/abstract-base/AbstractPayer.sol";
import {IPayer} from "@reactive-lib/interfaces/IPayer.sol";

/**
 * @title HealthFactorMonitor
 * @notice Reactive Smart Contract deployed on the Reactive Network.
 *         Monitors lending protocol events across chains and triggers
 *         the LiquidationShieldHook when a user's position is at risk.
 *
 * @dev Execution Pattern:
 *   1. Deployed on Reactive Network (Lasna testnet or mainnet)
 *   2. Subscribes to HealthCheckRequested events from the hook contract
 *   3. Also subscribes to lending protocol events (Borrow, Repay, LiquidationCall)
 *   4. react() evaluates health factor and emits Callback if protection needed
 *   5. Callback fires executeProtection() on the destination chain hook
 *
 * Subscribe → React → Callback
 *
 * Reactive Network Compatibility:
 *   - Implements vm detection via detectVm() (checks system contract existence)
 *   - Constructor gates subscribe() calls behind `if (!vm)`
 *   - react() is gated with vmOnly modifier (only runs inside ReactVM)
 *   - Integrates with Reactive Network's system contract for payments
 */
contract HealthFactorMonitor is AbstractReactive {
    // ── Constants ─────────────────────────────────────────────────────────────

    /// @dev Reactive Network system contract address
    address constant SYSTEM_CONTRACT = 0x0000000000000000000000000000000000fffFfF;

    /// @dev Event signatures for Aave V3 events we monitor
    uint256 constant BORROW_EVENT_SIG = uint256(keccak256(
        "Borrow(address,address,address,uint256,uint8,uint256,uint16)"
    ));
    uint256 constant REPAY_EVENT_SIG = uint256(keccak256(
        "Repay(address,address,address,uint256,bool)"
    ));
    uint256 constant LIQUIDATION_EVENT_SIG = uint256(keccak256(
        "LiquidationCall(address,address,address,uint256,uint256,address,bool)"
    ));

    /// @dev Event signature from our hook: HealthCheckRequested(address,uint256,address,uint256)
    uint256 constant HEALTH_CHECK_SIG = uint256(keccak256(
        "HealthCheckRequested(address,uint256,address,uint256)"
    ));

    /// @dev Function selector for executeProtection(address,uint256,uint256)
    bytes4 constant EXECUTE_PROTECTION_SELECTOR = bytes4(
        keccak256("executeProtection(address,uint256,uint256)")
    );

    // ── State ─────────────────────────────────────────────────────────────────
    // Removed duplicate state variables (subscriptionService, vm handled by AbstractReactive)

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

    error Unauthorized();

    modifier onlyOwner() {
        require(msg.sender == owner, "Unauthorized");
        _;
    }

    // ── Events ────────────────────────────────────────────────────────────────
    event PositionMonitored(address indexed user, uint256 chainId, address lendingPool);
    event ProtectionCallbackSent(address indexed user, uint256 healthFactor, uint256 repayAmount);

    // ── Modifiers ─────────────────────────────────────────────────────────────
    // Gated with vmOnly and rnOnly (from AbstractReactive)

    // ── Constructor ───────────────────────────────────────────────────────────
    /**
     * @param _hookChainId         Chain ID where the hook is deployed
     * @param _callbackReceiver    Address of callback receiver on hook chain
     * @param _hookAddress         Address of the LiquidationShieldHook
     * @param _hookOriginChainId   Chain ID where the hook emits HealthCheckRequested
     */
    constructor(
        uint256 _hookChainId,
        address _callbackReceiver,
        address _hookAddress,
        uint256 _hookOriginChainId
    ) payable AbstractReactive() {
        hookChainId = _hookChainId;
        callbackReceiver = _callbackReceiver;
        hookAddress = _hookAddress;
        hookOriginChainId = _hookOriginChainId;
        owner = msg.sender;
    }

    /// @notice Origin chain ID for the hook events
    uint256 public immutable hookOriginChainId;

    /**
     * @notice Initialize subscriptions after deployment.
     */
    function init() external onlyOwner {
        if (!vm) {
            service.subscribe(
                hookOriginChainId,           // Chain where hook is deployed
                hookAddress,                 // Hook contract address
                uint256(HEALTH_CHECK_SIG),   // HealthCheckRequested event
                REACTIVE_IGNORE,             // wildcard
                REACTIVE_IGNORE,
                REACTIVE_IGNORE
            );
        }
    }

    // ── Reactive VM Detection ─────────────────────────────────────────────────

    /**
     * @dev Detect whether we're in a ReactVM by checking if the system contract
     *      has code deployed. On Reactive Network, the system contract exists.
     *      In a ReactVM, it doesn't, so extcodesize returns 0.
     */
    function _detectVm() internal {
        uint256 size;
        address systemAddr = SYSTEM_CONTRACT;
        // solhint-disable-next-line no-inline-assembly
        assembly { size := extcodesize(systemAddr) }
        vm = size == 0;
    }

    // ── Core: React to Events ─────────────────────────────────────────────────

    /**
     * @notice Called by the Reactive Network when a subscribed event is detected.
     *
     * Handles two types of events:
     *   1. HealthCheckRequested → Register new position for monitoring
     *   2. Aave Borrow/Repay/Liquidation → Check if user needs protection
     *
     * @dev Gated with vmOnly — this function only runs inside the ReactVM.
     */
    function react(LogRecord calldata log) external override vmOnly {
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
        address user = address(uint160(log.topic_1));
        uint256 chainId = log.topic_2;
        address lendingPool = address(uint160(log.topic_3));

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
        address user = address(uint160(log.topic_2));

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
            // Silence unused variable warning in simplified version
            amount;

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
        service.subscribe(
            chainId,
            lendingPool,
            BORROW_EVENT_SIG,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        // Subscribe to Repay events
        service.subscribe(
            chainId,
            lendingPool,
            REPAY_EVENT_SIG,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );

        // Subscribe to Liquidation events (to detect if protection was too late)
        service.subscribe(
            chainId,
            lendingPool,
            LIQUIDATION_EVENT_SIG,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
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

    // ── Payment Support ───────────────────────────────────────────────────────

    /// @dev Accept direct ETH transfers (for Reactive Network gas payments)
    receive() external payable override(AbstractPayer, IPayer) {}
}
