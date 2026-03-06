// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;
/**
 * @title CallbackReceiver
 * @notice Destination contract that receives callbacks from the Reactive Network
 *         and forwards them to the LiquidationShieldHook.
 *
 * @dev This contract is deployed on the same chain as the hook.
 *      It acts as a bridge between Reactive Network callbacks and the hook.
 *
 *      Flow:
 *        Reactive Network → CallbackReceiver.receiveCallback() → Hook.executeProtection()
 *
 * 
 */
interface ILiquidationShieldHook {
    function executeProtection(
        address user,
        uint256 currentHealthFactor,
        uint256 repayAmount
    ) external;
}

contract CallbackReceiver {
    // ── State ─────────────────────────────────────────────────────────────────
    address public hook;
    address public owner;

    /// @dev Whitelist of addresses allowed to call receiveCallback
    ///      In production: only the Reactive Network relayer should be whitelisted
    mapping(address => bool) public authorizedCallers;

    // ── Events ────────────────────────────────────────────────────────────────
    event CallbackReceived(address indexed user, uint256 healthFactor, uint256 repayAmount);
    event CallbackForwarded(address indexed user, bool success);

    // ── Errors ────────────────────────────────────────────────────────────────
    error NotAuthorized();
    error HookNotSet();

    // ── Constructor ───────────────────────────────────────────────────────────
    constructor(address _hook) {
        hook = _hook;
        owner = msg.sender;
        authorizedCallers[msg.sender] = true;
    }

    // ── Callback Handler ──────────────────────────────────────────────────────

    /**
     * @notice Receives a callback from the Reactive Network and forwards it to the hook.
     *         The payload is the ABI-encoded call to executeProtection().
     *
     * @dev In production, this is called by the Reactive Network's relayer.
     *      The relayer picks up Callback events from the reactive contract
     *      and submits them as transactions on the destination chain.
     */
    function receiveCallback(bytes calldata payload) external {
        if (!authorizedCallers[msg.sender]) revert NotAuthorized();
        if (hook == address(0)) revert HookNotSet();

        // Decode the payload to extract parameters for logging
        (address user, uint256 healthFactor, uint256 repayAmount) = abi.decode(
            payload[4:], // Skip the 4-byte function selector
            (address, uint256, uint256)
        );

        emit CallbackReceived(user, healthFactor, repayAmount);

        // Forward the call to the hook
        (bool success, ) = hook.call(payload);

        emit CallbackForwarded(user, success);
    }

    /**
     * @notice Direct call to forward protection execution.
     *         Alternative to receiveCallback for simpler integration.
     */
    function triggerProtection(
        address user,
        uint256 currentHealthFactor,
        uint256 repayAmount
    ) external {
        if (!authorizedCallers[msg.sender]) revert NotAuthorized();
        if (hook == address(0)) revert HookNotSet();

        ILiquidationShieldHook(hook).executeProtection(
            user,
            currentHealthFactor,
            repayAmount
        );

        emit CallbackForwarded(user, true);
    }

    // ── Admin ─────────────────────────────────────────────────────────────────

    function setHook(address _hook) external {
        if (msg.sender != owner) revert NotAuthorized();
        hook = _hook;
    }

    function addAuthorizedCaller(address caller) external {
        if (msg.sender != owner) revert NotAuthorized();
        authorizedCallers[caller] = true;
    }

    function removeAuthorizedCaller(address caller) external {
        if (msg.sender != owner) revert NotAuthorized();
        authorizedCallers[caller] = false;
    }
}
