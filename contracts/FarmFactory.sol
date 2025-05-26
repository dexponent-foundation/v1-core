// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Create2.sol";
import "./RootFarm.sol";
import "./interfaces/IFarmFactory.sol";

/**
 * @title FarmFactory
 * @notice Factory contract for deploying new Farm contracts using CREATE2.
 * Only the owner (ProtocolCore) may call these functions. The factory internally maintains
 * an incremented farm ID counter. The RootFarm is created separately with id 0.
 */
contract FarmFactory is Ownable, IFarmFactory {
    // Internal counter for farm IDs.
    uint256 public currentFarmId;

    constructor() Ownable(msg.sender) {
        // Initialize the counter.
        currentFarmId = 0;
    }

    /**
     * @notice Creates a new Farm contract.
     * @dev The farm identifier is assigned automatically from currentFarmId.
     *      After deployment, the internal counter is incremented.
     * @param salt A user-supplied salt for CREATE2.
     * @param asset The principal asset for the farm.
     * @param maturityPeriod The maturity period for deposits (in seconds).
     * @param verifierIncentiveSplit Incentive percentage for verifiers.
     * @param yieldYodaIncentiveSplit Incentive percentage for yield yodas.
     * @param lpIncentiveSplit Incentive percentage for liquidity providers.
     * @param strategy The strategy contract address.
     * @param claimToken The claim token contract address.
     * @param farmOwner The address recorded as the farm owner.
     * @return farmId The unique identifier for the new farm.
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
    ) external override onlyOwner returns (uint256 farmId, address farmAddress) {
        // Assign the next farm ID.
        farmId = currentFarmId;
        // Increment the counter for future farms.
        currentFarmId++;

        // The protocol master is the owner of this factory.
        address protocolMasterAddress = owner();

        // Build the initialization code for Farm.
        // Farm constructor: (uint256 farmId, address asset, uint256 maturityPeriod, 
        // verifierIncentiveSplit, yieldYodaIncentiveSplit, lpIncentiveSplit, address strategy,
        // address protocolMaster, address claimToken, address farmOwner)
        bytes memory initCode = abi.encodePacked(
            type(Farm).creationCode,
            abi.encode(
                farmId,
                asset,
                maturityPeriod,
                verifierIncentiveSplit,
                yieldYodaIncentiveSplit,
                lpIncentiveSplit,
                strategy,
                protocolMasterAddress,
                claimToken,
                farmOwner
            )
        );

        // Derive the final salt based on the caller and provided salt.
        bytes32 finalSalt = keccak256(abi.encodePacked(msg.sender, salt));
        // Deploy the Farm contract via CREATE2.
        farmAddress = Create2.deploy(0, finalSalt, initCode);
    }

    /**
     * @notice Creates the special RootFarm contract.
     * @dev If a RootFarm already exists (i.e. currentFarmId > 0), this call will revert.
     *      After creation, the farmId counter is incremented (so that subsequent farms start at 1).
     * @param salt A user-supplied salt for CREATE2.
     * @param dxpToken The DXP token address, used as the asset.
     * @param vdxpToken The vDXP token address, used as the claim token.
     * @param farmOwner The address to record as the farm owner.
     * @return farmId The unique identifier for the RootFarm (always 0).
     * @return farmAddress The deployed RootFarm contract address.
     */
    function createRootFarm(
        bytes32 salt,
        address dxpToken,
        address vdxpToken,
        address farmOwner
    ) external override onlyOwner returns (uint256 farmId, address farmAddress) {
        require(currentFarmId == 0, "RootFarm already created");
        // RootFarm always has id 0.
        farmId = 0;
        // Preset parameters for RootFarm.
        uint256 maturityPeriod = 30 days;
        uint256 verifierIncentiveSplit = 30;
        uint256 yieldYodaIncentiveSplit = 0;
        uint256 lpIncentiveSplit = 70;
        address strategy = address(0); // Initially no strategy assigned.
        address protocolMasterAddress = owner();

        bytes memory initCode = abi.encodePacked(
            type(RootFarm).creationCode,
            abi.encode(
                farmId,
                dxpToken,           // RootFarm asset is the DXP token.
                maturityPeriod,
                verifierIncentiveSplit,
                yieldYodaIncentiveSplit,
                lpIncentiveSplit,
                strategy,
                protocolMasterAddress,
                vdxpToken,          // RootFarm claim token is the vDXP token.
                farmOwner
            )
        );
        bytes32 finalSalt = keccak256(abi.encodePacked(msg.sender, salt));
        farmAddress = Create2.deploy(0, finalSalt, initCode);

        // Increment the counter so that subsequent farms start at farmId = 1.
        currentFarmId++;

        // (Optional: Additional RootFarm-specific initialization can be done here.)

        return (farmId, farmAddress);
    }
}
