// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IFarm
 * @notice Interface for a standard Farm used in the Dexponent Protocol.
 *         This exposes the functions that the protocol needs to call on any Farm.
 */
interface IFarm {
    /**
     * @notice Updates the strategy associated with the farm.
     * @param _strategy The new strategy address.
     */
    function updateStrategy(address _strategy) external;

    /**
     * @notice Pulls the farm's accrued yield (in DXP) after LP share removal.
     * @return The net yield in DXP.
     */
    function pullFarmRevenue() external returns (uint256);

    /**
     * @notice Returns the verifier incentive split.
     * @return The verifier incentive split percentage.
     */
    function verifierIncentiveSplit() external view returns (uint256);

    /**
     * @notice Returns the yield yoda incentive split.
     * @return The yield yoda incentive split percentage.
     */
    function yieldYodaIncentiveSplit() external view returns (uint256);
}
