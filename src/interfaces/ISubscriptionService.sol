// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;

/**
 * @title ISubscriptionService
 * @notice Interface for Reactive Network's subscription service.
 *         Used by reactive contracts to subscribe/unsubscribe to on-chain events.
 *
 * @dev Subscriptions are created in the reactive contract's constructor or
 *      dynamically via callbacks. Each subscription filters events by
 *      chain_id, contract address, and up to 4 topics.
 *
 * See: https://dev.reactive.network/subscriptions
 */
interface ISubscriptionService {
    /// @notice Subscribe to events matching the given filter criteria
    /// @param chain_id    Chain to monitor (e.g., 11155111 for Sepolia)
    /// @param _contract   Contract address to monitor (address(0) for any)
    /// @param topic_0     Event signature hash (bytes32(0) for any)
    /// @param topic_1     First indexed parameter (bytes32(0) for any)
    /// @param topic_2     Second indexed parameter (bytes32(0) for any)
    /// @param topic_3     Third indexed parameter (bytes32(0) for any)
    function subscribe(
        uint256 chain_id,
        address _contract,
        bytes32 topic_0,
        bytes32 topic_1,
        bytes32 topic_2,
        bytes32 topic_3
    ) external;

    /// @notice Remove a previously created subscription
    function unsubscribe(
        uint256 chain_id,
        address _contract,
        bytes32 topic_0,
        bytes32 topic_1,
        bytes32 topic_2,
        bytes32 topic_3
    ) external;
}
