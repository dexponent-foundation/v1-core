// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IFarmFactory
 * @notice Interface for FarmFactory, allowing ProtocolCore (owner) to deploy
 *         standard farms and restake farms via CREATE2-based constructors.
 */
interface IFarmFactory {
    /**
     * @notice Deploys a new standard Farm contract using CREATE2.
     * @param salt                User-supplied salt for deterministic deployment.
     * @param asset               The ERC-20 asset to be used as principal in the farm.
     * @param maturityPeriod      Deposit maturity period (in seconds) before full withdrawal.
     * @param verifierIncentiveSplit Percentage of yield allocated to verifiers (0-100).
     * @param yieldYodaIncentiveSplit Percentage of yield allocated to yield yodas (0-100).
     * @param lpIncentiveSplit      Percentage of yield allocated to liquidity providers (0-100).
     * @param strategy            The strategy contract address to manage deployed assets.
     * @param claimToken          The associated claim token contract address for this farm.
     * @param farmOwner           The address that will be set as the farm owner.
     * @return farmId             The unique identifier assigned to the deployed farm.
     * @return farmAddress        The address of the newly created Farm contract.
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
     * @notice Deploys a new RestakeFarm contract using CREATE2.
     * @param salt                User-supplied salt for deterministic deployment.
     * @param asset               The ERC-20 asset to be used as principal in the restake farm.
     * @param maturityPeriod      Restake deposit maturity period (in seconds).
     * @param verifierIncentiveSplit Percentage of yield allocated to verifiers (0-100).
     * @param yieldYodaIncentiveSplit Percentage of yield allocated to yield yodas (0-100).
     * @param lpIncentiveSplit      Percentage of yield allocated to liquidity providers (0-100).
     * @param strategy            The strategy contract address to manage restaked assets.
     * @param claimToken          The associated claim token contract address for this farm.
     * @param farmOwner           The address that will be set as the restake farm owner.
     * @param rootFarmAddress     The address of the RootFarm to which this restake farm is linked.
     * @return farmId             The unique identifier assigned to the deployed restake farm.
     * @return farmAddress        The address of the newly created RestakeFarm contract.
     */
    function createRestakeFarm(
        bytes32 salt,
        address asset,
        uint256 maturityPeriod,
        uint256 verifierIncentiveSplit,
        uint256 yieldYodaIncentiveSplit,
        uint256 lpIncentiveSplit,
        address strategy,
        address claimToken,
        address farmOwner,
        address rootFarmAddress
    ) external returns (uint256 farmId, address farmAddress);
}