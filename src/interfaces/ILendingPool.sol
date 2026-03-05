// SPDX-License-Identifier: MIT
pragma solidity ^0.8.35;


interface ILendingPool {
    /// @notice Returns aggregate account data for a user
    /// @return totalCollateralBase     Total collateral in base currency
    /// @return totalDebtBase           Total debt in base currency
    /// @return availableBorrowsBase    Available borrows in base currency
    /// @return currentLiquidationThreshold Current liquidation threshold
    /// @return ltv                     Loan-to-value ratio
    /// @return healthFactor            Health factor (1e18 = 1.0, below = liquidatable)
    function getUserAccountData(address user)
        external
        view
        returns (
            uint256 totalCollateralBase,
            uint256 totalDebtBase,
            uint256 availableBorrowsBase,
            uint256 currentLiquidationThreshold,
            uint256 ltv,
            uint256 healthFactor
        );

    /// @notice Repay debt on behalf of a user
    /// @param asset      The debt token address
    /// @param amount     Amount to repay (use type(uint256).max for full repay)
    /// @param rateMode   1 = stable, 2 = variable
    /// @param onBehalfOf The user whose debt is being repaid
    function repay(
        address asset,
        uint256 amount,
        uint256 rateMode,
        address onBehalfOf
    ) external returns (uint256);

    /// @notice Supply collateral on behalf of a user
    /// @param asset      The collateral token address
    /// @param amount     Amount to supply
    /// @param onBehalfOf The user receiving the collateral credit
    /// @param referralCode Referral code (use 0)
    function supply(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
}
