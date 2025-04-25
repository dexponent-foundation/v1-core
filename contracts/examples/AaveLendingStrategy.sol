// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/FarmStrategy.sol";

/**
 * @title AaveLendingStrategy
 * @dev An example implementation of FarmStrategy for an Aave lending strategy using ETH.
 *      This strategy simulates depositing ETH into Aave, accruing rewards over time,
 *      and returning those rewards to the Farm contract.
 *
 * Note: In a real implementation, the contract would interact with Aave's WETHGateway
 * and LendingPool contracts to deposit and withdraw ETH. Here, for demonstration, we simulate
 * the deposit and reward accrual.
 */
abstract contract AaveLendingStrategy is FarmStrategy {
    // Total ETH deposited into Aave via this strategy (simulated)
    uint256 public deposited;
    // Accumulated rewards (simulated yield) in wei
    uint256 public simulatedRewards;
    // Timestamp of the last reward update
    uint256 public lastRewardTimestamp;
    // Simulated reward rate: For example, 1% per day per ETH deposited.
    // For 1 ETH (1e18 wei) deposited, in one day (86400 seconds), the reward should be 0.01 ETH (1e16 wei).
    // Thus, rewardRate = 1e16 / 86400 ≈ 115740740 wei per second per ETH deposited.
    uint256 public constant rewardRate = 115740740;

    /**
     * @dev Initializes the strategy.
     * @param _farm The address of the Farm contract using this strategy.
     *
     * Since the principal asset is ETH, we pass address(0) for the asset.
     */
    constructor(address _farm) FarmStrategy(_farm, address(0)) Ownable(msg.sender) {
        lastRewardTimestamp = block.timestamp;
    }

    /**
     * @dev Internal function to update simulated rewards based on the time elapsed.
     */
    function updateRewards() internal {
        uint256 timeElapsed = block.timestamp - lastRewardTimestamp;
        if (timeElapsed > 0 && deposited > 0) {
            uint256 rewards = (deposited * rewardRate * timeElapsed) / 1e18;
            simulatedRewards += rewards;
            lastRewardTimestamp = block.timestamp;
        }
    }

    /**
     * @notice Deploy liquidity into the Aave lending strategy.
     * @dev This function is payable and expects ETH to be sent along with the call.
     *      In a real implementation, this function would interact with Aave's WETHGateway.
     * @param amount The amount of ETH (in wei) to deposit.
     */
    function deployLiquidity(uint256 amount) external payable override onlyFarm nonReentrant {
        require(msg.value == amount, "Incorrect ETH amount sent");
        updateRewards();
        deposited += amount;
        emit LiquidityDeployed(amount);
        // Real implementation: Call Aave's deposit function via WETHGateway here.
    }

    /**
     * @notice Withdraw liquidity from the Aave lending strategy.
     * @dev Withdraws the specified amount (simulated) and transfers ETH back to the Farm.
     *      In a real implementation, this function would interact with Aave's withdrawal mechanism.
     * @param amount The amount of ETH (in wei) to withdraw.
     */
    function withdrawLiquidity(uint256 amount) external override onlyFarm nonReentrant {
        require(deposited >= amount, "Insufficient deposited funds");
        updateRewards();
        deposited -= amount;
        // Simulate withdrawal by sending ETH back to the Farm.
        (bool success, ) = farm.call{value: amount}("");
        require(success, "ETH transfer failed");
        emit LiquidityWithdrawn(amount);
    }

    /**
     * @notice Harvest rewards accrued from the Aave lending strategy.
     * @dev Updates the simulated rewards, resets the reward accumulator, and sends the rewards back to the Farm.
     * @return harvested The amount of ETH (in wei) harvested as rewards.
     */
    function harvestRewards() external override onlyFarm nonReentrant returns (uint256 harvested) {
        updateRewards();
        harvested = simulatedRewards;
        simulatedRewards = 0;
        _sendRewardsToFarm(harvested);
        return harvested;
    }

    // Allow the contract to receive ETH.
    receive() external payable {}
}
