// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IReactive
 * @notice Interface for Reactive Network's reactive contract pattern.
 *         Reactive contracts implement react() to process incoming event logs
 *         from monitored chains and emit Callback events to trigger actions
 *         on destination chains.
 *
 * @dev Based on Reactive Network's official interface specification.
 *      See: https://dev.reactive.network/reactive-contracts
 */
interface IReactive {
    /// @notice Log record received from a monitored chain
    struct LogRecord {
        uint256 chain_id;
        address _contract;
        bytes32 topic_0;
        bytes32 topic_1;
        bytes32 topic_2;
        bytes32 topic_3;
        bytes   data;
        uint256 block_number;
        uint256 op_code;
        bytes32 block_hash;
        bytes32 tx_hash;
        uint256 log_index;
    }

    /// @notice Emitted to request a callback on a destination chain
    event Callback(
        uint256 indexed chain_id,
        address indexed _contract,
        uint64  indexed gas_limit,
        bytes   payload
    );

    /// @notice Called by the Reactive Network when a subscribed event is detected
    function react(LogRecord calldata log) external;
}
