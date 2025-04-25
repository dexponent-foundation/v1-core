// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Farm.sol";
import "./interfaces/IRootFarm.sol"; 
import "./interfaces/IDXPToken.sol"; 
import "./vDXPToken.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title RestakeFarm
 * @notice A specialized Farm that, instead of transferring bonus DXP directly to LPs,
 *         automatically restakes the bonus into the RootFarm and credits the user with vDXP.
 *         Inherits from the standard Farm contract.
 *
 * Additional functionality:
 * - restakeBonus: Approves and sends bonus DXP to the RootFarm for restaking.
 * - reverseRestakedBonus: Reverses a bonus restake by retrieving bonus DXP from the LP and
 *   invoking RootFarm’s reverseRestake function.
 */
contract RestakeFarm is Farm {
    using SafeERC20 for IERC20;

    // Address of the associated RootFarm.
    IRootFarm public rootFarm;
    // DXP token interface for bonus transfers.
    IDXPToken public dxpToken;

    /**
     * @notice Constructs a new RestakeFarm.
     * @param _farmId The unique farm identifier.
     * @param _asset The principal asset address.
     * @param _maturityPeriod The minimum maturity period for deposits.
     * @param _verifierIncentiveSplit Percentage for verifiers.
     * @param _yieldYodaIncentiveSplit Percentage for yield yodas.
     * @param _lpIncentiveSplit Percentage for LPs.
     * @param _strategy Address of the strategy contract.
     * @param _protocolMaster Address of the protocol master.
     * @param _claimToken Address of the claim token contract.
     * @param _farmOwner The designated farm owner.
     * @param _rootFarm Address of the RootFarm contract.
     */
    constructor(
        uint256 _farmId,
        address _asset,
        uint256 _maturityPeriod,
        uint256 _verifierIncentiveSplit,
        uint256 _yieldYodaIncentiveSplit,
        uint256 _lpIncentiveSplit,
        address _strategy,
        address _protocolMaster,
        address _claimToken,
        address _farmOwner,
        address _rootFarm
    )
        Farm(
            _farmId,
            _asset,
            _maturityPeriod,
            _verifierIncentiveSplit,
            _yieldYodaIncentiveSplit,
            _lpIncentiveSplit,
            _strategy,
            _protocolMaster,
            _claimToken,
            _farmOwner
        )
    {
        require(_rootFarm != address(0), "Invalid RootFarm address");
        rootFarm = IRootFarm(_rootFarm);
    }

    /**
     * @notice Sets the DXP token contract address.
     * @param _dxpToken The address of the deployed DXP token.
     */
    function setDXPToken(address _dxpToken) external onlyFarmOwner {
        dxpToken = IDXPToken(_dxpToken);
    }

    /**
     * @notice Restakes bonus DXP into the RootFarm.
     * Instead of transferring bonus DXP directly to the LP, the bonus is approved
     * and sent to the RootFarm, which then mints vDXP for the liquidity provider.
     * @param lp The liquidity provider’s address.
     * @param bonusDXP The bonus amount in DXP to restake.
     */
    function restakeBonus(address lp, uint256 bonusDXP) external onlyFarmOwner {
        require(bonusDXP > 0, "No bonus to restake");
        // Increase allowance for the RootFarm.
        IERC20(address(dxpToken)).safeIncreaseAllowance(address(rootFarm), bonusDXP);
        // Call the RootFarm's restakeDeposit function (this function must be implemented in RootFarm).
        rootFarm.restakeDeposit(lp, bonusDXP);
    }

    /**
     * @notice Reverses a bonus restake in case of early withdrawal or full exit.
     * Instead of a standard bonus reversal (which would transfer bonus DXP from the LP),
     * this function retrieves bonus DXP from the LP and calls the RootFarm to reverse the restake.
     * @param lp The liquidity provider’s address.
     * @param bonusDXP The bonus amount to reverse.
     */
    function reverseRestakedBonus(address lp, uint256 bonusDXP) external onlyFarmOwner {
        require(bonusDXP > 0, "No bonus to reverse");
        // Transfer bonus DXP from the LP to this contract.
        IERC20(address(dxpToken)).safeTransferFrom(lp, address(this), bonusDXP);
        // Call RootFarm's reverseRestake function (this function must be implemented in RootFarm).
        rootFarm.reverseRestake(lp, bonusDXP);
    }
}
