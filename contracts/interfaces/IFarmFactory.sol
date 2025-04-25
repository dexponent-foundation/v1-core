// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IFarmFactory
 * @notice Interface for the FarmFactory contract.
 */
interface IFarmFactory {
    /**
     * @notice Creates a new Farm contract using an internal farm ID counter.
     * @param salt A user-supplied salt to influence CREATE2 deployment.
     * @param asset The principal asset address for the new farm.
     * @param maturityPeriod The maturity period (in seconds) for deposits in the farm.
     * @param verifierIncentiveSplit The percentage allocated to verifiers.
     * @param yieldYodaIncentiveSplit The percentage allocated to yield yodas.
     * @param lpIncentiveSplit The percentage allocated to liquidity providers.
     * @param strategy The address of the strategy contract for liquidity deployment.
     * @param claimToken The claim token contract address (e.g. vDXPToken) for the farm.
     * @param farmOwner The user who is recorded as the farm owner.
     * @return farmId The unique identifier for the newly created farm.
     * @return farmAddress The deployed Farm contract address.
     */
    function createFarm(
        bytes32 salt,
        address asset,
        uint256 maturityPeriod,
        uint256 verifierIncentiveSplit,
        uint256 yieldYodaIncentiveSplit,
        uint256 lpIncentiveSplit,
        address strategy,
        address claimToken,
        address farmOwner
    ) external returns (uint256 farmId, address farmAddress);

    /**
     * @notice Creates the special RootFarm contract.
     * The RootFarm is always created with id 0. This function can be called only if no RootFarm exists.
     * @param salt A user-supplied salt for CREATE2.
     * @param dxpToken The DXP token address (to be used as the asset).
     * @param vdxpToken The vDXP token address (to be used as the claim token).
     * @param farmOwner The address that will be recorded as the owner of the RootFarm.
     * @return farmId The unique identifier for the RootFarm (always 0).
     * @return farmAddress The deployed RootFarm contract address.
     */
    function createRootFarm(
        bytes32 salt,
        address dxpToken,
        address vdxpToken,
        address farmOwner
    ) external returns (uint256 farmId, address farmAddress);
}
