// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IRootFarm
 * @notice Interface for the RootFarm contract in the Dexponent Protocol.
 *         RootFarm is a specialized Farm (with DXP as the principal asset)
 *         and includes additional functions for market-making and revenue handling.
 */
interface IRootFarm {
    /**
     * @notice Updates the strategy associated with the RootFarm.
     * @param _strategy The new strategy address.
     */
    function updateStrategy(address _strategy) external;

    /**
     * @notice Adds revenue (in DXP) to the RootFarm.
     * @param amount The amount of DXP to add.
     */
    function addRevenueDXP(uint256 amount) external;

    /**
     * @notice Pulls the RootFarm's accrued yield (in DXP) after LP share removal.
     * @return The net yield in DXP.
     */
    function pullFarmRevenue() external returns (uint256);

    /**
     * @notice Returns the owner of the RootFarm.
     * @return The address of the RootFarm owner.
     */
    function owner() external view returns (address);

    /**
     * @notice Accepts a deposit of bonus DXP and mints vDXP tokens for the given beneficiary.
     * @param beneficiary The address to receive the vDXP tokens.
     * @param amount The amount of DXP to restake.
     */
    function restakeDeposit(address beneficiary, uint256 amount) external;

    /**
     * @notice Reverses a restake in case of early withdrawal or full exit.
     * @param lp The liquidity provider's address.
     * @param amount The amount of DXP to reverse.
     */
    function reverseRestake(address lp, uint256 amount) external;
}
