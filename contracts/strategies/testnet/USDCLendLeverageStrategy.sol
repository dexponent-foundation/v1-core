// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../../interfaces/FarmStrategy.sol";

interface ILendingPool {
    function deposit(
        address asset,
        uint256 amount,
        address onBehalfOf,
        uint16 referralCode
    ) external;
    
    function borrow(
        address asset,
        uint256 amount,
        uint256 interestRateMode,
        uint16 referralCode,
        address onBehalfOf
    ) external;
    
    function withdraw(
        address asset,
        uint256 amount,
        address to
    ) external returns (uint256);
}

/// @title StablecoinLendLeverageStrategy
/// @notice A FarmStrategy implementation that recursively deposits USDC into Aave v3 on testnet.
/// It leverages the deposit up to 3 levels by borrowing 50% of the deposit each time.
/// Yield is simulated at a fixed 8% APY on the net collateral.
contract USDCLendLeverageStrategy is FarmStrategy {
    using SafeERC20 for IERC20;

    /// @notice Aave v3 Lending Pool address (set at deployment)
    ILendingPool public immutable lendingPool;

    /// @notice Maximum recursion levels for leverage (3 levels).
    uint8 public constant MAX_LEVEL = 3;

    /// @notice Borrow factor in basis points; here 50% (i.e. 5000 out of 10000).
    uint256 public constant BORROW_FACTOR_BPS = 5000;

    /// @notice Total amount deposited (supplied) into Aave.
    uint256 public totalSupplied;

    /// @notice Total amount borrowed from Aave.
    uint256 public totalBorrowed;

    /// @notice Timestamp of the last yield simulation checkpoint.
    uint256 public lastYieldCheckpoint;

    /// @notice Simulated APY in basis points (e.g., 8% APY = 800 bps).
    uint256 public constant SIMULATED_APY_BPS = 800;

    /// @notice Number of seconds in a year.
    uint256 public constant YEAR_IN_SECONDS = 365 days;
    /**
     * @notice Constructor
     * @param _farm The Farm contract that owns this strategy.
     * @param _asset The principal asset (USDC) address on testnet.
     * @param _lendingPool The Aave v3 LendingPool address on testnet.
     */
    constructor(address _farm, address _asset, address _lendingPool)
        FarmStrategy(_farm, _asset) Ownable(msg.sender)
    {
        require(_lendingPool != address(0), "Invalid lending pool address");
        lendingPool = ILendingPool(_lendingPool);
        lastYieldCheckpoint = block.timestamp;
    }

    /**
     * @notice Deploys liquidity into Aave v3 recursively.
     * @dev The strategy receives USDC from the Farm and deposits it into Aave.
     * It then borrows 50% of the deposited amount and re-deposits that,
     * up to 3 levels, increasing leverage.
     * @param amount The amount of USDC to deploy.
     */
    function deployLiquidity(uint256 amount)
        external
        payable
        override
        onlyFarm
        nonReentrant
    {
        require(amount > 0, "Deploy: amount=0");

        // Transfer USDC from the Farm to this contract.
        IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);

        uint256 depositAmount = amount;
        uint8 level = 0;
        while (level < MAX_LEVEL && depositAmount > 0) {
            // Approve Aave lending pool to pull depositAmount.
            IERC20(asset).forceApprove(address(lendingPool), depositAmount);
            lendingPool.deposit(asset, depositAmount, address(this), 0);
            totalSupplied += depositAmount;

            // Borrow 50% of the current deposit.
            uint256 borrowAmount = (depositAmount * BORROW_FACTOR_BPS) / 10000;
            if (borrowAmount > 0) {
                lendingPool.borrow(asset, borrowAmount, 2, 0, address(this));
                totalBorrowed += borrowAmount;
                depositAmount = borrowAmount;
            } else {
                depositAmount = 0;
            }
            level++;
        }
        // Reset allowance
        IERC20(asset).forceApprove(address(lendingPool), 0);

        emit LiquidityDeployed(amount);
    }

    /**
     * @notice Withdraws a specified amount of USDC from the Aave position.
     * @dev For demonstration purposes, we simply call Aave's withdraw function.
     * In a real recursive lending setup, unwinding is more complex.
     * @param amount The amount of USDC to withdraw.
     */
    function withdrawLiquidity(uint256 amount)
        external
        override
        onlyFarm
        nonReentrant
    {
        require(amount > 0, "Withdraw: amount=0");

        uint256 withdrawn = lendingPool.withdraw(asset, amount, address(this));
        require(withdrawn >= amount, "Withdraw failed");
        // Update tracking (for demo, we subtract linearly)
        if (totalSupplied >= amount) {
            totalSupplied -= amount;
        } else {
            totalSupplied = 0;
        }
        // Note: In practice, one should also unwind borrow positions.
        IERC20(asset).safeTransfer(msg.sender, withdrawn);
        emit LiquidityWithdrawn(amount);
    }

    /**
     * @notice Harvests yield (interest) accrued on the net collateral.
     * @dev Since testnet Aave may not yield real interest, we simulate yield using a fixed APY.
     * @return harvested The simulated yield in USDC transferred to the Farm.
     */
    function harvestRewards() external override onlyFarm nonReentrant returns (uint256 harvested) {
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0) return 0;

        // Net collateral is totalSupplied minus totalBorrowed.
        uint256 netCollateral = totalSupplied > totalBorrowed ? totalSupplied - totalBorrowed : 0;
        harvested = (netCollateral * SIMULATED_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
        if (harvested > 0) {
            _sendRewardsToFarm(harvested);
            lastYieldCheckpoint = block.timestamp;
            emit RewardsHarvested(harvested);
        }
    }

    /**
     * @notice Rebalances the leveraged position.
     * @dev For demonstration, we simply emit an event.
     */
    function rebalance() external override onlyFarm nonReentrant {
        emit StrategyRebalanced();
    }

    /**
     * @notice Emergency withdraws all funds from Aave back to the strategy and then to the Farm.
     */
    function emergencyWithdraw() external override onlyFarm nonReentrant {
        uint256 totalAssets = _emergencyWithdrawImpl();
        emit EmergencyWithdrawn(totalAssets);
    }

    /**
     * @dev Internal function to withdraw all USDC from Aave.
     * @return totalAssets The total USDC withdrawn.
     */
    function _emergencyWithdrawImpl() internal override returns (uint256 totalAssets) {
        totalAssets = lendingPool.withdraw(asset, type(uint256).max, address(this));
        IERC20(asset).safeTransfer(farm, totalAssets);
    }

    /**
     * @notice Returns the net deposited USDC (net collateral).
     * @return tvl The total value locked.
     */
    function getStrategyTVL() external view override returns (uint256 tvl) {
        tvl = totalSupplied > totalBorrowed ? totalSupplied - totalBorrowed : 0;
    }

    /**
     * @notice Returns the simulated pending yield in USDC.
     * @return pendingRewards The yield accrued since the last checkpoint.
     */
    function getPendingRewards() external view override returns (uint256 pendingRewards) {
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        uint256 netCollateral = totalSupplied > totalBorrowed ? totalSupplied - totalBorrowed : 0;
        pendingRewards = (netCollateral * SIMULATED_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
    }

    /**
     * @notice Sends harvested USDC yield to the Farm.
     * @param amount The yield amount in USDC.
     */
    function _sendRewardsToFarm(uint256 amount) internal override {
        require(IERC20(asset).transfer(farm, amount), "Strategy: ERC20 transfer failed");
        emit RewardsHarvested(amount);
    }
}
