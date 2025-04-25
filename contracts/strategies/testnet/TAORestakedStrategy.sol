// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/IDXPToken.sol";
import "../../interfaces/IRootFarm.sol";
import "../../interfaces/FarmStrategy.sol";

// Bittensor staking precompile address as per official docs.
address constant BITTENSOR_STAKING_PRECOMPILE = 0x0000000000000000000000000000000000000801;

interface IBittensorStaking {
    function addStake(bytes32 hotkey) external payable;
    function removeStake(bytes32 hotkey, uint256 amount) external;
}

/**
 * @title TAORestakedStrategy
 * @notice A strategy that stakes native TAO (Bittensor's token) across multiple validator hotkeys,
 * and allows any bonus DXP (e.g. deposit bonus) to be automatically restaked into RootFarm to boost yield.
 *
 * Key features:
 * - Accepts native TAO deposits (asset is address(0)).
 * - Splits deposits among registered validator hotkeys according to specified ratios.
 * - Uses Bittensor's staking precompile to add/remove stake.
 * - HarvestRewards returns 0 since TAO staking yield is auto‐credited off‐chain.
 * - Provides bonus restaking functions that forward bonus DXP into RootFarm, minting vDXP for the LP.
 */
contract TAORestakedStrategy is FarmStrategy {
    using SafeERC20 for IERC20;

    // --- Bittensor staking precompile ---
    IBittensorStaking public constant STAKING = IBittensorStaking(BITTENSOR_STAKING_PRECOMPILE);

    // --- Validator data structure ---
    struct ValidatorInfo {
        bytes32 hotkey; // 32-byte Substrate public key
        uint256 ratio;  // Weighting factor (e.g., basis points)
        uint256 staked; // Amount of TAO staked to this hotkey (in wei)
    }
    ValidatorInfo[] public validators;
    uint256 public totalRatio; // Sum of all validator ratios
    uint256 public totalStaked; // Total TAO staked across all validators

    // --- References for bonus restaking ---
    IRootFarm public rootFarm;
    IDXPToken public dxpToken;

    event ValidatorAdded(bytes32 hotkey, uint256 ratio);
    event ValidatorUpdated(uint256 index, uint256 newRatio);
    event StakeDeployed(uint256 amount);
    event StakeWithdrawn(uint256 amount);
    event BonusRestaked(address indexed lp, uint256 bonusAmount);
    event BonusRestakeReversed(address indexed lp, uint256 bonusAmount);

    /**
     * @notice Constructor.
     * @param _farm The Farm contract that owns this strategy.
     * @param _asset Should be address(0) for native TAO.
     * @param _rootFarm Address of the RootFarm contract for bonus restaking.
     */
    constructor(address _farm, address _asset, address _rootFarm)
        FarmStrategy(_farm, _asset) Ownable(msg.sender)
    {
        require(_asset == address(0), "TAOBoostStrategy: asset must be native (address(0))");
        require(_rootFarm != address(0), "TAOBoostStrategy: invalid RootFarm address");
        rootFarm = IRootFarm(_rootFarm);
    }

    /**
     * @notice Allows the farm owner (or protocol) to set the DXP token address.
     * @param _dxpToken Address of the deployed DXP token.
     */
    function setDXPToken(address _dxpToken) external onlyOwner {
        require(_dxpToken != address(0), "Invalid DXP token address");
        dxpToken = IDXPToken(_dxpToken);
    }

    /**
     * @notice Adds a new validator hotkey with a specified ratio.
     * @param hotkey The 32-byte hotkey.
     * @param ratio The weighting factor for staking distribution.
     */
    function addValidator(bytes32 hotkey, uint256 ratio) external onlyOwner {
        require(hotkey != bytes32(0), "Invalid hotkey");
        require(ratio > 0, "Ratio must be > 0");
        validators.push(ValidatorInfo(hotkey, ratio, 0));
        totalRatio += ratio;
        emit ValidatorAdded(hotkey, ratio);
    }

    /**
     * @notice Updates the ratio for an existing validator.
     * @param index The index in the validators array.
     * @param newRatio The new ratio value.
     */
    function updateValidatorRatio(uint256 index, uint256 newRatio) external onlyOwner {
        require(index < validators.length, "Index out of range");
        require(newRatio > 0, "New ratio must be > 0");
        totalRatio = totalRatio - validators[index].ratio + newRatio;
        validators[index].ratio = newRatio;
        emit ValidatorUpdated(index, newRatio);
    }

    /**
     * @notice Deploys TAO liquidity by staking the deposited amount across all validators.
     * @param amount The amount of TAO (in wei) to stake.
     * @dev Called only by the associated Farm. The function is payable and expects msg.value == amount.
     */
    function deployLiquidity(uint256 amount)
        external
        payable
        override
        onlyFarm
        nonReentrant
    {
        require(msg.value == amount, "TAOBoostStrategy: Incorrect TAO sent");
        require(amount > 0, "Amount must be > 0");
        require(validators.length > 0 && totalRatio > 0, "No validators or invalid ratios");

        uint256 remaining = amount;
        for (uint256 i = 0; i < validators.length; i++) {
            uint256 portion = (amount * validators[i].ratio) / totalRatio;
            if (i == validators.length - 1) {
                portion = remaining;
            }
            if (portion > 0) {
                // Stake portion to validator using Bittensor precompile.
                (bool success, ) = address(STAKING).call{value: portion}(
                    abi.encodeWithSelector(IBittensorStaking.addStake.selector, validators[i].hotkey)
                );
                require(success, "TAOBoostStrategy: addStake failed");
                validators[i].staked += portion;
                totalStaked += portion;
                remaining -= portion;
            }
        }
        require(remaining == 0, "Staking distribution error");
        emit StakeDeployed(amount);
    }

    /**
     * @notice Withdraws staked TAO from validators proportionally and transfers it back to the Farm.
     * @param amount The total amount of TAO to withdraw.
     * @dev Called only by the associated Farm.
     */
    function withdrawLiquidity(uint256 amount)
        external
        override
        onlyFarm
        nonReentrant
    {
        require(validators.length > 0, "No validators available");
        require(amount > 0 && amount <= totalStaked, "Withdraw amount exceeds staked");

        uint256 remaining = amount;
        for (uint256 i = 0; i < validators.length; i++) {
            uint256 portion = (amount * validators[i].staked) / totalStaked;
            if (i == validators.length - 1) {
                portion = remaining;
            }
            if (portion > 0) {
                (bool success, ) = address(STAKING).call(
                    abi.encodeWithSelector(IBittensorStaking.removeStake.selector, validators[i].hotkey, portion)
                );
                require(success, "TAOBoostStrategy: removeStake failed");
                validators[i].staked -= portion;
                totalStaked -= portion;
                remaining -= portion;
            }
            if (remaining == 0) break;
        }
        require(remaining == 0, "Withdrawal distribution error");

        // Transfer the withdrawn TAO back to the Farm.
        (bool sent, ) = farm.call{value: amount}("");
        require(sent, "TAOBoostStrategy: TAO transfer failed");
        emit StakeWithdrawn(amount);
    }

    /**
     * @notice Harvests yield from TAO staking.
     * @dev Bittensor staking auto-credits yield off-chain, so this returns 0.
     */
    function harvestRewards()
        external
        override
        onlyFarm
        nonReentrant
        returns (uint256 harvested)
    {
        harvested = 0;
        // No direct yield harvesting; yield is auto-credited off-chain.
    }

    /**
     * @notice Restakes bonus DXP into the RootFarm to boost yield.
     * @param lp The liquidity provider's address.
     * @param bonusDXP The bonus amount in DXP to restake.
     * @dev This function approves bonus DXP to the RootFarm and calls its restakeDeposit.
     */
    function restakeBonus(address lp, uint256 bonusDXP) external onlyOwner {
        require(bonusDXP > 0, "No bonus to restake");
        // Approve bonus DXP for RootFarm.
        IERC20(address(dxpToken)).safeIncreaseAllowance(address(rootFarm), bonusDXP);
        // Call RootFarm's restakeDeposit function.
        rootFarm.restakeDeposit(lp, bonusDXP);
        emit BonusRestaked(lp, bonusDXP);
    }

    /**
     * @notice Reverses a previously restaked bonus.
     * @param lp The liquidity provider's address.
     * @param bonusDXP The bonus amount to reverse.
     * @dev This retrieves bonus DXP from the LP and calls RootFarm's reverseRestake.
     */
    function reverseRestakeBonus(address lp, uint256 bonusDXP) external onlyOwner {
        require(bonusDXP > 0, "No bonus to reverse");
        IERC20(address(dxpToken)).safeTransferFrom(lp, address(this), bonusDXP);
        rootFarm.reverseRestake(lp, bonusDXP);
        emit BonusRestakeReversed(lp, bonusDXP);
    }

    /**
     * @notice Emergency withdraws all staked TAO and returns it to the Farm.
     * @dev Called only by the associated Farm.
     */
    function emergencyWithdraw() external override onlyFarm nonReentrant {
        uint256 remaining = totalStaked;
        for (uint256 i = 0; i < validators.length; i++) {
            uint256 portion = validators[i].staked;
            if (portion > 0) {
                (bool success, ) = address(STAKING).call(
                    abi.encodeWithSelector(IBittensorStaking.removeStake.selector, validators[i].hotkey, portion)
                );
                require(success, "Emergency removeStake failed");
                validators[i].staked = 0;
                totalStaked -= portion;
                remaining -= portion;
            }
        }
        require(remaining == 0, "Emergency withdrawal failed");

        // Return all TAO to the Farm.
        (bool sent, ) = farm.call{value: address(this).balance}("");
        require(sent, "Emergency transfer failed");
        emit EmergencyWithdrawn(address(this).balance);
    }

    /**
     * @notice Returns the total staked TAO (TVL) in the strategy.
     * @return tvl The total TAO staked.
     */
    function getStrategyTVL() external view override returns (uint256 tvl) {
        tvl = totalStaked;
    }

    /**
     * @notice Returns the pending yield (always 0 in this strategy).
     * @return pendingRewards The pending yield.
     */
    function getPendingRewards() external view override returns (uint256 pendingRewards) {
        pendingRewards = 0;
    }

    // Fallback function to accept TAO (native) transfers.
    receive() external payable {}
}
