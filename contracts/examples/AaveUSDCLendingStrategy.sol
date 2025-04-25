// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/FarmStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title AaveUSDCStrategy
 * @dev An example implementation of FarmStrategy for an Aave lending strategy using USDC.
 *      This strategy simulates depositing USDC into Aave, accruing rewards over time,
 *      and returning those rewards to the Farm contract.
 *
 * Note: In a real implementation, this contract would interact with Aave’s LendingPool
 *       and related contracts (e.g., USDC gateway). For demonstration, we simulate a constant
 *       reward rate.
 */
abstract contract AaveUSDCStrategy is FarmStrategy {
    using SafeERC20 for IERC20;

    // Total USDC deposited in the strategy (in USDC's smallest units, e.g., 6 decimals).
    uint256 public deposited;
    // Accumulated simulated rewards (in USDC smallest units).
    uint256 public simulatedRewards;
    // Timestamp when rewards were last updated.
    uint256 public lastRewardTimestamp;
    // Simulated reward rate per second per unit deposited.
    // For example, if 1 USDC (1e6 units) deposited earns ~1% per day,
    // then the reward per day is roughly 1e4 units, so per second:
    // rewardRate ≈ (1e4 * 1e6) / 86400 ≈ 115741 (using an appropriate scaling factor).
    uint256 public constant rewardRate = 115741;
    // Scaling factor to maintain precision.
    uint256 public constant factor = 1e12;

    /**
     * @dev Initializes the strategy.
     * @param _farm The address of the Farm contract using this strategy.
     * @param _asset The USDC token address.
     */
    constructor(address _farm, address _asset) FarmStrategy(_farm, _asset) Ownable(msg.sender) {
        require(_asset != address(0), "Asset must be ERC20 for USDC strategy");
        lastRewardTimestamp = block.timestamp;
    }

    /**
     * @dev Internal function to update simulated rewards based on time elapsed.
     */
    function updateRewards() internal {
        uint256 timeElapsed = block.timestamp - lastRewardTimestamp;
        if (timeElapsed > 0 && deposited > 0) {
            uint256 rewards = (deposited * rewardRate * timeElapsed) / factor;
            simulatedRewards += rewards;
            lastRewardTimestamp = block.timestamp;
        }
    }

    /**
     * @notice Deploy liquidity into the Aave lending strategy.
     * @dev Transfers USDC from the Farm contract to this strategy.
     *      The Farm must have approved this contract to pull USDC.
     * @param amount The amount of USDC (in smallest units) to deposit.
     */
    function deployLiquidity(uint256 amount) external payable override onlyFarm nonReentrant {
        IERC20(asset).safeTransferFrom(farm, address(this), amount);
        updateRewards();
        deposited += amount;
        emit LiquidityDeployed(amount);
    }

    /**
     * @notice Withdraw liquidity from the Aave lending strategy.
     * @dev Withdraws the specified amount of USDC and transfers it back to the Farm.
     * @param amount The amount of USDC to withdraw.
     */
    function withdrawLiquidity(uint256 amount) external override onlyFarm nonReentrant {
        require(deposited >= amount, "Insufficient deposited funds");
        updateRewards();
        deposited -= amount;
        IERC20(asset).safeTransfer(farm, amount);
        emit LiquidityWithdrawn(amount);
    }

    /**
     * @notice Harvest rewards accrued from the Aave lending strategy.
     * @dev Updates the simulated rewards, resets the accumulator, and sends rewards back to the Farm.
     * @return harvested The amount of USDC harvested as rewards.
     */
    function harvestRewards() external override onlyFarm nonReentrant returns (uint256 harvested) {
        updateRewards();
        harvested = simulatedRewards;
        simulatedRewards = 0;
        _sendRewardsToFarm(harvested);
        return harvested;
    }
}
