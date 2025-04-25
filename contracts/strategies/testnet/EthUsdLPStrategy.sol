// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../../interfaces/FarmStrategy.sol";
import "../../interfaces/ILiquidityManager.sol";

contract EthUsdLPStrategy is FarmStrategy {
    using SafeERC20 for IERC20;

    // External LiquidityManager to handle swaps and liquidity provisioning.
    ILiquidityManager public liquidityManager;
    // USDC token address on Sepolia.
    address public immutable usdc;
    // Uniswap V3 fee tier (e.g., 3000 for 0.3% fee).
    uint24 public constant UNI_FEE = 3000;
    // For Uniswap V3 simulation, we set stable = false.
    bool public constant STABLE = false;

    // Total liquidity deployed (expressed in ETH-equivalent terms).
    uint256 public deployedLiquidity;
    // Timestamp when yield was last harvested.
    uint256 public lastYieldCheckpoint;
    // Simulated APY in basis points (8% APY = 800 basis points).
    uint256 public constant SIMULATED_APY_BPS = 800;
    // Number of seconds in a year.
    uint256 public constant YEAR_IN_SECONDS = 365 days;

    /**
     * @notice Constructor.
     * @param _farm The Farm contract that owns this strategy.
     * @param _liquidityManager The address of the LiquidityManager contract.
     * @param _usdc The USDC token address on Sepolia.
     *
     * Note: The principal asset is native ETH, so we pass address(0) for asset.
     */
    constructor(
        address _farm,
        address _asset,
        address _liquidityManager,
        address _usdc
    ) FarmStrategy(_farm, _asset) Ownable(msg.sender) {
        require(_liquidityManager != address(0), "Invalid LiquidityManager");
        require(_usdc != address(0), "Invalid USDC address");
        liquidityManager = ILiquidityManager(_liquidityManager);
        usdc = _usdc;
        lastYieldCheckpoint = block.timestamp;
    }

    /**
     * @notice Deploys liquidity by splitting the ETH deposit, swapping half to USDC,
     * and adding liquidity to the ETH–USDC Uniswap V3 pool.
     * @param amount The amount of ETH (in wei) to deploy.
     * @dev Called by the Farm. Expects msg.value == amount.
     */
    function deployLiquidity(uint256 amount)
        external
        payable
        override
        onlyFarm
        nonReentrant
    {
        require(msg.value == amount, "Incorrect ETH sent");
        require(amount > 0, "Amount must be > 0");

        // Split the deposit into roughly two halves.
        uint256 half = amount / 2;
        uint256 ethPortion = amount - half; // In case of an odd amount.

        // Swap half of ETH to USDC.
        uint256 usdcReceived = liquidityManager.swap(
            address(0),
            usdc,
            half,
            address(this)
        );
        require(usdcReceived > 0, "Swap failed");

        // Calculate minimal acceptable amounts (e.g., 95% of desired).
        uint256 minEth = (ethPortion * 95) / 100;
        uint256 minUsdc = (usdcReceived * 95) / 100;

        // Add liquidity to the ETH–USDC pool using the LiquidityManager.
        // The call is made with ethPortion sent as native ETH.
        liquidityManager.addLiquidity(
            address(0),
            usdc,
            UNI_FEE,
            STABLE,
            ethPortion,
            usdcReceived,
            minEth,
            minUsdc
        );

        deployedLiquidity += amount;
        lastYieldCheckpoint = block.timestamp;

        emit LiquidityDeployed(amount);
    }

    /**
     * @notice Withdraws liquidity from the ETH–USDC pool and returns ETH to the Farm.
     * @param amount The amount (in ETH-equivalent terms) to withdraw.
     * @dev Called by the Farm.
     */
    function withdrawLiquidity(uint256 amount)
        external
        override
        onlyFarm
        nonReentrant
    {
        require(amount > 0 && amount <= deployedLiquidity, "Invalid withdrawal amount");

        // Remove liquidity from the pool via the LiquidityManager.
        // This returns amounts for ETH and USDC.
        (uint256 ethAmount, uint256 usdcAmount) = liquidityManager.removeLiquidity(
            address(0),
            usdc,
            UNI_FEE,
            amount
        );

        // Swap the withdrawn USDC back to ETH.
        uint256 ethFromUsdc = liquidityManager.swap(
            usdc,
            address(0),
            usdcAmount,
            address(this)
        );

        uint256 totalEth = ethAmount + ethFromUsdc;
        require(totalEth > 0, "Withdrawal produced zero ETH");

        deployedLiquidity -= amount;

        // Transfer the total ETH to the Farm.
        (bool sent, ) = farm.call{value: totalEth}("");
        require(sent, "ETH transfer failed");

        emit LiquidityWithdrawn(totalEth);
    }

    /**
     * @notice Harvests simulated yield from the liquidity position.
     * @dev Yield is calculated based on the time elapsed since the last checkpoint
     * and deployedLiquidity at a fixed APY.
     * @return harvested The yield (in wei) transferred to the Farm.
     */
    function harvestRewards()
        external
        override
        onlyFarm
        nonReentrant
        returns (uint256 harvested)
    {
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0 || deployedLiquidity == 0) return 0;

        harvested = (deployedLiquidity * SIMULATED_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
        if (harvested > 0) {
            _sendRewardsToFarm(harvested);
            lastYieldCheckpoint = block.timestamp;
            emit RewardsHarvested(harvested);
        }
    }

    /**
     * @notice Rebalances the strategy's positions.
     * @dev For simulation, this function simply emits a rebalancing event.
     */
    function rebalance() external override onlyFarm nonReentrant {
        emit StrategyRebalanced();
    }

    /**
     * @notice Emergency withdraws all liquidity and returns ETH to the Farm.
     * @dev Called by the Farm in an emergency.
     */
    function emergencyWithdraw() external override onlyFarm nonReentrant {
        (uint256 ethAmount, uint256 usdcAmount) = liquidityManager.removeLiquidity(
            address(0),
            usdc,
            UNI_FEE,
            type(uint256).max
        );
        uint256 ethFromUsdc = liquidityManager.swap(
            usdc,
            address(0),
            usdcAmount,
            address(this)
        );
        uint256 totalEth = ethAmount + ethFromUsdc;
        deployedLiquidity = 0;
        (bool sent, ) = farm.call{value: totalEth}("");
        require(sent, "Emergency transfer failed");
        emit EmergencyWithdrawn(totalEth);
    }

    /**
     * @notice Returns the total value locked (TVL) in the strategy.
     * @return tvl The total ETH-equivalent liquidity deployed.
     */
    function getStrategyTVL() external view override returns (uint256 tvl) {
        tvl = deployedLiquidity;
    }

    /**
     * @notice Returns the pending simulated yield since the last checkpoint.
     * @return pendingRewards The yield amount (in wei) accrued.
     */
    function getPendingRewards() external view override returns (uint256 pendingRewards) {
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0 || deployedLiquidity == 0) return 0;
        pendingRewards = (deployedLiquidity * SIMULATED_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
    }

    /**
     * @notice Internal helper to send harvested rewards to the Farm.
     * @param amount The yield amount (in wei) to send.
     */
    function _sendRewardsToFarm(uint256 amount) internal override {
        (bool success, ) = farm.call{value: amount}("");
        require(success, "Reward transfer failed");
        emit RewardsHarvested(amount);
    }

    // Accept ETH (for withdrawals, etc.)
    receive() external payable {}
}
