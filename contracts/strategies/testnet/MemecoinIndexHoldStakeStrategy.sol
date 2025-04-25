// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/FarmStrategy.sol";

/**
 * @title MemecoinIndexHoldStakeStrategy
 * @notice A testnet strategy for holding a memecoin and simulating yield.
 * Liquidity providers deposit a memecoin (an ERC20 token) that is simply held
 * by the strategy. Yield is simulated at a fixed APY (15% APY in this example)
 * based on the total principal held. When yield is harvested, the accrued
 * rewards are sent to the Farm for distribution.
 */
contract MemecoinIndexHoldStakeStrategy is FarmStrategy {
    using SafeERC20 for IERC20;

    /// @notice Simulated APY in basis points (e.g., 1500 bps = 15% APY)
    uint256 public constant SIMULATED_APY_BPS = 1500;
    /// @notice Approximate number of seconds in a year.
    uint256 public constant YEAR_IN_SECONDS = 365 days;

    /// @notice Timestamp of the last yield checkpoint.
    uint256 public lastYieldCheckpoint;
    /// @notice Total principal (memecoin amount) held by the strategy.
    uint256 public totalPrincipal;

    /**
     * @notice Constructor.
     * @param _farm The Farm contract that owns this strategy.
     * @param _asset The address of the memecoin (ERC20) to be held.
     */
    constructor(address _farm, address _asset) FarmStrategy(_farm, _asset) Ownable(msg.sender) {
        require(_asset != address(0), "Invalid asset address");
        lastYieldCheckpoint = block.timestamp;
    }

    /**
     * @notice Deposits the memecoin into the strategy.
     * @dev Called by the associated Farm. Transfers tokens from the Farm
     * into the strategy and updates the total principal and yield checkpoint.
     * @param amount The amount of memecoin to deposit.
     */
    function deployLiquidity(uint256 amount)
        external
        override
        onlyFarm
        payable
        nonReentrant
    {
        require(amount > 0, "Amount must be > 0");
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        totalPrincipal += amount;
        lastYieldCheckpoint = block.timestamp;
        emit LiquidityDeployed(amount);
    }

    /**
     * @notice Withdraws a specified amount of the memecoin from the strategy.
     * @dev Called by the associated Farm. The strategy transfers the requested
     * amount of tokens back to the Farm.
     * @param amount The amount of memecoin to withdraw.
     */
    function withdrawLiquidity(uint256 amount)
        external
        override
        onlyFarm
        nonReentrant
    {
        require(amount > 0 && amount <= totalPrincipal, "Invalid withdrawal amount");
        totalPrincipal -= amount;
        IERC20(asset).safeTransfer(msg.sender, amount);
        emit LiquidityWithdrawn(amount);
    }

    /**
     * @notice Harvests simulated yield accrued on the held memecoin.
     * @dev Yield is calculated based on a fixed APY (15%) on the total principal,
     * proportional to the time elapsed since the last checkpoint.
     * The harvested yield is transferred to the Farm.
     * @return harvested The amount of yield (in memecoin units) sent to the Farm.
     */
    function harvestRewards()
        external
        override
        onlyFarm
        nonReentrant
        returns (uint256 harvested)
    {
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0 || totalPrincipal == 0) return 0;
        harvested = (totalPrincipal * SIMULATED_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
        if (harvested > 0) {
            _sendRewardsToFarm(harvested);
            lastYieldCheckpoint = block.timestamp;
            emit RewardsHarvested(harvested);
        }
    }

    /**
     * @notice Rebalances the strategy's positions.
     * @dev For a hold strategy, no rebalancing is needed; this function emits an event.
     */
    function rebalance() external override onlyFarm nonReentrant {
        emit StrategyRebalanced();
    }

    /**
     * @notice Emergency withdraws all memecoin from the strategy and transfers them to the Farm.
     * @dev Called by the Farm in emergency scenarios.
     */
    function emergencyWithdraw() external override onlyFarm nonReentrant {
        uint256 balance = IERC20(asset).balanceOf(address(this));
        totalPrincipal = 0;
        IERC20(asset).safeTransfer(farm, balance);
        emit EmergencyWithdrawn(balance);
    }

    /**
     * @notice Returns the total value locked (TVL) in the strategy.
     * @return tvl The total memecoin held by the strategy.
     */
    function getStrategyTVL() external view override returns (uint256 tvl) {
        tvl = IERC20(asset).balanceOf(address(this));
    }

    /**
     * @notice Returns the pending simulated yield since the last checkpoint.
     * @return pendingRewards The amount of yield accrued (in memecoin units).
     */
    function getPendingRewards() external view override returns (uint256 pendingRewards) {
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0 || totalPrincipal == 0) return 0;
        pendingRewards = (totalPrincipal * SIMULATED_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
    }

    /**
     * @notice Internal helper to send harvested rewards to the Farm.
     * @dev Transfers the specified amount of memecoin to the Farm.
     * @param amount The yield amount to send.
     */
    function _sendRewardsToFarm(uint256 amount) internal override {
        require(IERC20(asset).transfer(farm, amount), "Reward transfer failed");
        emit RewardsHarvested(amount);
    }
}
