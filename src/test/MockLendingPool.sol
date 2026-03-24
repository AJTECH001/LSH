// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

contract MockLendingPool {
    // We must match the EXACT string used in HealthFactorMonitor BORROW_EVENT_SIG
    // "Borrow(address,address,address,uint256,uint8,uint256,uint16)"
    event Borrow(
        address indexed reserve,
        address user,
        address indexed onBehalfOf,
        uint256 amount,
        uint8 borrowRateMode,
        uint256 borrowRate,
        uint16 indexed referralCode
    );

    function triggerBorrow(address user, uint256 amount) external {
        emit Borrow(
            address(0), // reserve
            user, // user
            user, // onBehalfOf (topic_2)
            amount, // amount
            1, // borrowRateMode
            0, // borrowRate
            0 // referralCode
        );
    }
}
