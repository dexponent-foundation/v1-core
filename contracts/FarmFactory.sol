// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./Farm.sol";
import "./RestakeFarm.sol";
import "./RootFarm.sol";
import "./interfaces/IFarmFactory.sol";

/**
 * @title FarmFactory
 * @notice Factory for deploying Farm, RestakeFarm and RootFarm via CREATE2 salt
 *         using the new `new Contract{salt:...}` pattern.
 */
contract FarmFactory is Ownable, IFarmFactory {
    uint256 public currentFarmId;

    constructor() Ownable(msg.sender) {
        currentFarmId = 1;
    }

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
    ) external override onlyOwner returns (uint256 farmId, address farmAddress) {
        farmId = currentFarmId++;
        bytes32 finalSalt = keccak256(abi.encodePacked(msg.sender, salt));

        farmAddress = address(new Farm{salt: finalSalt}(
            farmId,
            asset,
            maturityPeriod,
            verifierIncentiveSplit,
            yieldYodaIncentiveSplit,
            lpIncentiveSplit,
            strategy,
            owner(),
            claimToken,
            farmOwner
        ));
    }

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
    ) external onlyOwner returns (uint256 farmId, address farmAddress) {
        farmId = currentFarmId++;
        bytes32 finalSalt = keccak256(abi.encodePacked(msg.sender, salt));

        farmAddress = address(new RestakeFarm{salt: finalSalt}(
            farmId,
            asset,
            maturityPeriod,
            verifierIncentiveSplit,
            yieldYodaIncentiveSplit,
            lpIncentiveSplit,
            strategy,
            owner(),
            claimToken,
            farmOwner,
            rootFarmAddress
        ));
    }

}
