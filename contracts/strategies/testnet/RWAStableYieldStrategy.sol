// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

// Import the abstract FarmStrategy interface.
import "../../interfaces/FarmStrategy.sol";

/// @notice Minimal interface for a lending pool (e.g., Aave v3) used for RWA assets.
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

/// @title RWAStableYieldStrategy
/// @notice A testnet strategy that simulates lending and staking for tokenized Real‑World Assets (RWA).
/// Users deposit RWA tokens, which are supplied into a lending pool. Yield is simulated on the net collateral,
/// and the accrued yield is returned to the Farm for distribution.
contract RWAStableYieldStrategy is FarmStrategy {
    using SafeERC20 for IERC20;

    // External lending pool used for RWA deposits.
    ILendingPool public immutable lendingPool;

    // Total amount of RWA tokens supplied into the lending pool.
    uint256 public totalSupplied;

    // Total amount borrowed (if any); for simplicity, this demo does not implement recursive borrowing.
    uint256 public totalBorrowed;

    // Timestamp for the last yield simulation checkpoint.
    uint256 public lastYieldCheckpoint;

    // Simulated APY in basis points (e.g., 600 bps for 6% APY).
    uint256 public constant SIMULATED_APY_BPS = 600;

    // Seconds per year (approximation)
    uint256 public constant YEAR_IN_SECONDS = 365 days;

    /**
     * @notice Constructor.
     * @param _farm The Farm contract that owns this strategy.
     * @param _asset The tokenized RWA asset address.
     * @param _lendingPool The lending pool contract address for RWA assets.
     */
    constructor(address _farm, address _asset, address _lendingPool)
        FarmStrategy(_farm, _asset) Ownable(msg.sender)
    {
        require(_lendingPool != address(0), "Invalid lending pool");
        lendingPool = ILendingPool(_lendingPool);
        // Initialize the yield checkpoint at deployment.
        lastYieldCheckpoint = block.timestamp;
    }

    /**
     * @notice Deploys liquidity by depositing RWA tokens into the lending pool.
     * @param amount The amount of RWA tokens to deposit.
     * @dev The strategy expects the Farm to transfer RWA tokens before calling this function.
     */
    function deployLiquidity(uint256 amount)
        external
        override
        payable
        onlyFarm
        nonReentrant
    {
        require(amount > 0, "Amount must be > 0");

        // Transfer RWA tokens from the Farm to this strategy.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        // Approve the lending pool and deposit the tokens.
        IERC20(asset).forceApprove(address(lendingPool), amount);
        lendingPool.deposit(asset, amount, address(this), 0);
        totalSupplied += amount;

        // Update yield checkpoint.
        lastYieldCheckpoint = block.timestamp;

        emit LiquidityDeployed(amount);
    }

    /**
     * @notice Withdraws a specified amount of RWA tokens from the lending pool back to the Farm.
     * @param amount The amount of RWA tokens to withdraw.
     */
    function withdrawLiquidity(uint256 amount)
        external
        override
        onlyFarm
        nonReentrant
    {
        require(amount > 0, "Withdraw: amount must be > 0");

        // Withdraw RWA tokens from the lending pool.
        uint256 withdrawn = lendingPool.withdraw(asset, amount, address(this));
        require(withdrawn >= amount, "Withdrawal failed");

        // Update total supplied.
        if (totalSupplied >= amount) {
            totalSupplied -= amount;
        } else {
            totalSupplied = 0;
        }
        // Transfer the withdrawn tokens back to the Farm.
        IERC20(asset).safeTransfer(msg.sender, withdrawn);

        emit LiquidityWithdrawn(amount);
    }

    /**
     * @notice Harvests simulated yield on the net RWA collateral.
     * @dev Yield is simulated on the net collateral (totalSupplied minus totalBorrowed) at a fixed APY.
     * @return harvested The simulated yield (in RWA tokens) transferred to the Farm.
     */
    function harvestRewards()
        external
        override
        onlyFarm
        nonReentrant
        returns (uint256 harvested)
    {
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0 || totalSupplied == 0) {
            return 0;
        }

        // Net collateral for yield calculation.
        uint256 netCollateral = totalSupplied > totalBorrowed ? totalSupplied - totalBorrowed : 0;
        harvested = (netCollateral * SIMULATED_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);

        if (harvested > 0) {
            _sendRewardsToFarm(harvested);
            lastYieldCheckpoint = block.timestamp;
            emit RewardsHarvested(harvested);
        }
    }

    /**
     * @notice Rebalances the strategy.
     * @dev For demonstration purposes, this function simply emits an event.
     */
    function rebalance() external override onlyFarm nonReentrant {
        emit StrategyRebalanced();
    }

    /**
     * @notice Emergency withdraws all RWA tokens from the lending pool and sends them back to the Farm.
     */
    function emergencyWithdraw() external override onlyFarm nonReentrant {
        uint256 totalAssets = _emergencyWithdrawImpl();
        emit EmergencyWithdrawn(totalAssets);
    }

    /**
     * @dev Internal function to perform emergency withdrawal.
     * @return totalAssets The total amount of RWA tokens withdrawn.
     */
    function _emergencyWithdrawImpl() internal override returns (uint256 totalAssets) {
        totalAssets = lendingPool.withdraw(asset, type(uint256).max, address(this));
        totalSupplied = 0;
        IERC20(asset).safeTransfer(farm, totalAssets);
    }

    /**
     * @notice Returns the total value locked (TVL) in the strategy.
     * @return tvl The net collateral (totalSupplied minus totalBorrowed).
     */
    function getStrategyTVL() external view override returns (uint256 tvl) {
        tvl = totalSupplied > totalBorrowed ? totalSupplied - totalBorrowed : 0;
    }

    /**
     * @notice Returns the pending simulated yield since the last checkpoint.
     * @return pendingRewards The simulated yield (in RWA tokens).
     */
    function getPendingRewards() external view override returns (uint256 pendingRewards) {
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0 || totalSupplied == 0) return 0;
        uint256 netCollateral = totalSupplied > totalBorrowed ? totalSupplied - totalBorrowed : 0;
        pendingRewards = (netCollateral * SIMULATED_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
    }

    /**
     * @notice Internal helper to send harvested rewards to the Farm.
     * @param amount The amount of RWA tokens to transfer as yield.
     */
    function _sendRewardsToFarm(uint256 amount) internal override {
        require(IERC20(asset).transfer(farm, amount), "Reward transfer failed");
        emit RewardsHarvested(amount);
    }
}
