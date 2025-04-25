// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/FarmStrategy.sol";

/**
 * @title EthStakingStrategy
 * @dev An example implementation of FarmStrategy for ETH staking.
 *      This strategy assumes that the Farm using it is designed for ETH (native currency).
 *      When the Farm calls deployLiquidity, it must send ETH along with the call.
 *      Deposited ETH is “staked” (simulated here), and rewards (simulated as 1% of deposited funds)
 *      are later harvested and sent back to the Farm.
 */
abstract contract EthStakingStrategy is FarmStrategy {
    // Total ETH that has been staked/deposited in the strategy.
    uint256 public deposited;
    // A simulated reward pool; in this example, rewards are accumulated here.
    uint256 public rewardPool;

    /**
     * @dev Initializes the strategy.
     * @param _farm The address of the Farm contract using this strategy.
     *
     * Since the principal asset is ETH (native currency), we pass address(0)
     * for the principalAsset parameter.
     */
    constructor(address _farm) FarmStrategy(_farm, address(0)) Ownable(msg.sender) {}

    /**
     * @notice Deploy liquidity into the staking strategy.
     * @dev Expects that the Farm sends ETH along with the call.
     *      Simulates depositing ETH into Ethereum’s staking deposit contract.
     * @param amount The amount of ETH (in wei) to stake.
     */
    function deployLiquidity(uint256 amount) external override onlyFarm nonReentrant payable {
        require(msg.value == amount, "Incorrect ETH amount sent");
        // Simulate deposit: add received ETH to the deposited balance.
        deposited += amount;
        emit LiquidityDeployed(amount);
    }

    /**
     * @notice Withdraw liquidity from the staking strategy.
     * @dev Withdraws the specified amount from the deposited balance and sends ETH back to the Farm.
     * @param amount The amount of ETH (in wei) to withdraw.
     */
    function withdrawLiquidity(uint256 amount) external override onlyFarm nonReentrant {
        require(deposited >= amount, "Insufficient deposited funds");
        deposited -= amount;
        // Send the withdrawn ETH back to the Farm contract.
        (bool success, ) = farm.call{value: amount}("");
        require(success, "ETH transfer failed");
        emit LiquidityWithdrawn(amount);
    }

    /**
     * @notice Harvest rewards from the staking strategy.
     * @dev Simulates rewards as 1% of the currently deposited funds.
     *      The rewards are then sent back to the Farm.
     * @return harvested The amount of ETH (in wei) harvested as rewards.
     */
    function harvestRewards() external override onlyFarm nonReentrant returns (uint256 harvested) {
        // For simulation: reward equals 1% of deposited funds.
        uint256 reward = (deposited * 1) / 100;
        rewardPool += reward;

        // Transfer the accumulated rewards back to the Farm.
        harvested = rewardPool;
        rewardPool = 0;
        (bool success, ) = farm.call{value: harvested}("");
        require(success, "Reward transfer failed");
    }

    // Allow the contract to receive ETH.
    receive() external payable {}
}
