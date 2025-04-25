// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import our abstract FarmStrategy interface
import "../../interfaces/FarmStrategy.sol";

// Minimal interface for Aave v3 LendingPool (simplified for testnet)
interface ILendingPool {
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;

    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

/// @title LiquidStakingBoostStrategy
/// @notice This strategy accepts ETH from the Farm, stakes it in a Lido-like contract to obtain stETH,
///         then deposits the stETH into an Aave v3 LendingPool to earn yield. Yield is simulated at a fixed
///         combined APY and then sent to the Farm.
/// @dev For testnet purposes, stETH and ETH are assumed to convert at a 1:1 ratio.
contract LiquidStakingBoostStrategy is FarmStrategy {
    using SafeERC20 for IERC20;

    // Addresses for external protocols (set at deployment)
    address public immutable lidoStETH;      // stETH token contract address on testnet
    address public immutable lendingPool;     // Aave v3 LendingPool address for stETH

    // Total stETH deposited into Aave (collateral)
    uint256 public totalDepositedStETH;

    // Yield simulation parameters
    uint256 public lastYieldCheckpoint;
    uint256 public constant COMBINED_APY_BPS = 1000;  // 10% APY in basis points
    uint256 public constant YEAR_IN_SECONDS = 365 days;

    /**
     * @notice Constructor.
     * @param _farm The Farm contract that owns this strategy.
     * @param _lidoStETH The Lido-like stETH token contract address.
     * @param _lendingPool The Aave v3 LendingPool contract address for stETH.
     *
     * Note: The principal asset is ETH, so we pass address(0) to FarmStrategy.
     */
    constructor(
        address _farm,
        address _asset,
        address _lidoStETH,
        address _lendingPool
    ) FarmStrategy(_farm, _asset) Ownable(msg.sender) {
        require(_lidoStETH != address(0), "Invalid stETH address");
        require(_lendingPool != address(0), "Invalid lending pool address");
        lidoStETH = _lidoStETH;
        lendingPool = _lendingPool;
        lastYieldCheckpoint = block.timestamp;
    }

    /**
     * @notice Deploys liquidity by staking ETH in the Lido-like contract and depositing stETH into Aave.
     * @param amount The amount of ETH (in wei) to deploy.
     * @dev The function is payable; the caller (Farm) must send exactly 'amount' ETH.
     */
    function deployLiquidity(uint256 amount)
        external
        payable
        override
        onlyFarm
        nonReentrant
    {
        require(msg.value == amount, "Mismatch: msg.value != amount");
        require(amount > 0, "Amount must be > 0");

        // Step 1: Stake ETH in Lido-like contract by calling submit(referral)
        (bool success, ) = lidoStETH.call{value: amount}(
            abi.encodeWithSignature("submit(address)", address(0))
        );
        require(success, "Lido submit failed");

        // Step 2: Assume stETH is received; deposit all stETH into Aave lending pool
        uint256 stETHBalance = IERC20(lidoStETH).balanceOf(address(this));
        require(stETHBalance > 0, "No stETH received");

        IERC20(lidoStETH).forceApprove(lendingPool, stETHBalance);
        ILendingPool(lendingPool).deposit(lidoStETH, stETHBalance, address(this), 0);
        totalDepositedStETH += stETHBalance;
        lastYieldCheckpoint = block.timestamp;

        emit LiquidityDeployed(amount);
    }

    /**
     * @notice Withdraws a specified amount of stETH from Aave and converts it to ETH.
     * @param amount The amount of stETH (in wei) to withdraw.
     */
    function withdrawLiquidity(uint256 amount)
        external
        override
        onlyFarm
        nonReentrant
    {
        require(amount > 0, "Withdraw: amount must be > 0");
        // Withdraw stETH from Aave lending pool
        uint256 withdrawn = ILendingPool(lendingPool).withdraw(lidoStETH, amount, address(this));
        require(withdrawn >= amount, "Withdrawal failed");
        if (totalDepositedStETH >= amount) {
            totalDepositedStETH -= amount;
        } else {
            totalDepositedStETH = 0;
        }
        // For simulation on testnet, assume 1 stETH = 1 ETH. Transfer ETH to Farm.
        // In a real implementation, you might need to swap stETH for ETH.
        (bool sent, ) = farm.call{value: amount}("");
        require(sent, "ETH transfer to Farm failed");
        emit LiquidityWithdrawn(amount);
    }

    /**
     * @notice Harvests yield from the Aave deposit based on simulated APY.
     * @dev Yield is calculated on the net stETH deposit using a fixed APY.
     * @return harvested The simulated yield (in wei, as ETH) sent to the Farm.
     */
    function harvestRewards()
        external
        override
        onlyFarm
        nonReentrant
        returns (uint256 harvested)
    {
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0 || totalDepositedStETH == 0) {
            return 0;
        }
        // Simulate yield: yield = totalDepositedStETH * (APY in BPS) * (timeElapsed / YEAR_IN_SECONDS) / 10000
        harvested = (totalDepositedStETH * COMBINED_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
        if (harvested > 0) {
            _sendRewardsToFarm(harvested);
            lastYieldCheckpoint = block.timestamp;
            emit RewardsHarvested(harvested);
        }
    }

    /**
     * @notice Rebalances the position. For testnet simulation, this is a no-op.
     */
    function rebalance() external override onlyFarm nonReentrant {
        emit StrategyRebalanced();
    }

    /**
     * @notice Emergency withdraws all funds from Aave and returns them to the Farm.
     */
    function emergencyWithdraw() external override onlyFarm nonReentrant {
        uint256 totalAssets = _emergencyWithdrawImpl();
        emit EmergencyWithdrawn(totalAssets);
    }

    /**
     * @dev Internal function to withdraw all stETH from Aave.
     * @return totalAssets The total amount of stETH (assumed convertible 1:1 to ETH) withdrawn.
     */
    function _emergencyWithdrawImpl() internal override returns (uint256 totalAssets) {
        totalAssets = ILendingPool(lendingPool).withdraw(lidoStETH, type(uint256).max, address(this));
        totalDepositedStETH = 0;
        (bool sent, ) = farm.call{value: totalAssets}("");
        require(sent, "Emergency transfer failed");
        return totalAssets;
    }

    /**
     * @notice Returns the total value locked (TVL) in the strategy (in wei, as ETH).
     * @return tvl The current TVL, approximated as the total stETH deposit.
     */
    function getStrategyTVL() external view override returns (uint256 tvl) {
        tvl = totalDepositedStETH;
    }

    /**
     * @notice Returns the pending rewards based on simulated yield since the last checkpoint.
     * @return pendingRewards The simulated yield (in wei, as ETH).
     */
    function getPendingRewards() external view override returns (uint256 pendingRewards) {
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0 || totalDepositedStETH == 0) return 0;
        pendingRewards = (totalDepositedStETH * COMBINED_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
    }

    /**
     * @notice Internal helper to send harvested rewards (as ETH) to the Farm.
     * @param amount The amount of rewards in wei to send.
     */
    function _sendRewardsToFarm(uint256 amount) internal override {
        (bool success, ) = farm.call{value: amount}("");
        require(success, "Reward transfer failed");
        emit RewardsHarvested(amount);
    }

    // Fallback to accept ETH from withdrawals or WETH unwrapping (if any)
    receive() external payable {}
}
