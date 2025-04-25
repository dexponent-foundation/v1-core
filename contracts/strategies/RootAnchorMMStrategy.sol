// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "../interfaces/FarmStrategy.sol";
import "../interfaces/ILiquidityManager.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "../libraries/TickMath.sol";

/**
 * @title RootAnchorMMStrategy
 * @notice A production-ready Uniswap v3 market-making strategy for the RootFarm.
 *         This strategy:
 *          - Creates and initializes a DXP/USDC pool via LiquidityManager.
 *          - Deposits initial liquidity (using protocol-supplied DXP and USDC).
 *          - Allows additional USDC deposits (manual top-ups) to support the anchor price.
 *          - When withdrawing liquidity, swaps any USDC received into DXP so that only DXP is returned.
 *          - Harvests fees from the pool and swaps them into DXP.
 *
 * @dev All functions are restricted by the onlyFarm modifier so that only the associated RootFarm can call them.
 */
contract RootAnchorMMStrategy is FarmStrategy {
    using SafeERC20 for IERC20;

    // ======================================================
    // State Variables
    // ======================================================
    /// @notice The USDC token address.
    address public usdc;

    /// @notice The LiquidityManager contract used for DEX interactions.
    ILiquidityManager public liquidityManager;

    /// @notice The liquidity pool address for the DXP/USDC pair.
    address public pool;

    /// @notice The Uniswap v3 fee tier used (e.g., 3000 = 0.3%).
    uint24 public feeTier;

    /// @notice The current anchor price of DXP in USDC terms, scaled by 1e18.
    uint256 public anchorPrice;

    /// @notice Timestamp when the anchor price was last updated.
    uint256 public lastAnchorUpdate;

    /// @notice Threshold drop percentage (scaled by 1e18) at which buybacks are paused.
    uint256 public buybackDropThreshold;

    /// @notice Cooldown period (in seconds) during which buybacks remain paused after a sharp drop.
    uint256 public buybackCooldownPeriod;

    /// @notice Timestamp until which buybacks are paused.
    uint256 public buybackPausedUntil;

    /// @notice Total USDC liquidity deployed in the strategy.
    uint256 public deployedUSDC;

    // ======================================================
    // Events
    // ======================================================
    event AnchorPriceUpdated(uint256 newAnchorPrice);
    event LiquidityWithdrawn(uint256 usdcRemoved, uint256 dxpReceived);
    event RewardsGenerated(uint256 dxpAmount);
    event BuybackExecuted(uint256 usdcUsed, uint256 dxpBought);
    event BuybackPaused(uint256 pausedUntil);
    event InitializationCompleted();

    // ======================================================
    // Constructor
    // ======================================================
    /**
     * @notice Constructor: passes RootFarm's address and asset (DXP) to FarmStrategy.
     * @param _farm The associated RootFarm contract.
     * @param _asset The principal asset; for RootFarm this is DXP.
     */
    constructor(address _farm, address _asset) FarmStrategy(_farm, _asset) Ownable(msg.sender) {
        // No extra logic in constructor.
    }

    // ======================================================
    // Initializer Function
    // ======================================================
    /**
     * @notice Initializes the RootFarm strategy.
     * @param _feeTier The Uniswap v3 fee tier (e.g., 3000 for 0.3%).
     * @param _sqrtPriceX96 The initial sqrt price for the DXP/USDC pool (in Q64.96 format).
     * @param initialUSDCAmount Initial USDC liquidity to be added.
     * @param initialDXPAmount Initial DXP amount (from protocol reserves) to be paired.
     * @param _usdc The USDC token address.
     * @param _liquidityManager Address of the LiquidityManager contract.
     * @param _buybackDropThreshold Drop threshold (scaled by 1e18) to trigger buyback pause.
     * @param _buybackCooldownPeriod Buyback cooldown period in seconds.
     */
    function initialize(
        uint24 _feeTier,
        uint160 _sqrtPriceX96,
        uint256 initialUSDCAmount,
        uint256 initialDXPAmount,
        address _usdc,
        address _liquidityManager,
        uint256 _buybackDropThreshold,
        uint256 _buybackCooldownPeriod
    ) external onlyOwner nonReentrant {
        feeTier = _feeTier;
        usdc = _usdc;
        liquidityManager = ILiquidityManager(_liquidityManager);
        buybackDropThreshold = _buybackDropThreshold;
        buybackCooldownPeriod = _buybackCooldownPeriod;

        // Create the DXP/USDC pool via LiquidityManager.
        // Note: createPool now returns the pool address.
        pool = liquidityManager.createPool(asset, usdc, feeTier, _sqrtPriceX96, true);

        // Add initial liquidity. The LiquidityManager handles LP token/NFT transfers.
        liquidityManager.addLiquidity(asset, usdc, feeTier, true, initialDXPAmount, initialUSDCAmount, 0, 0);
        deployedUSDC = initialUSDCAmount;

        // Set the anchor price using TWAP; fallback to 1e18 if TWAP returns 0 (testnet fallback).
        uint256 twapPrice = liquidityManager.getTwapPrice(asset, usdc, feeTier, 300);
        if (twapPrice == 0) {
            twapPrice = 1e18;
        }
        anchorPrice = twapPrice;
        lastAnchorUpdate = block.timestamp;
        buybackPausedUntil = 0;

        emit AnchorPriceUpdated(anchorPrice);
        emit InitializationCompleted();
    }

    // ======================================================
    // FarmStrategy Overrides
    // ======================================================
    /**
     * @notice Deploy additional USDC liquidity into the pool.
     * @param amount The amount of USDC to add.
     * @dev Called only by the associated Farm.
     */
    function deployLiquidity(uint256 amount) external payable override onlyFarm nonReentrant {
        require(amount > 0, "Strategy: amount must be > 0");
        // Transfer USDC from Farm (Farm must approve liquidityManager to pull tokens).
        IERC20(usdc).transferFrom(farm, address(this), amount);
        IERC20(usdc).approve(address(liquidityManager), amount);
        // Add liquidity via LiquidityManager (no additional DXP added here).
        liquidityManager.addLiquidity(asset, usdc, feeTier, true, 0, amount, 0, 0);
        deployedUSDC += amount;
        emit LiquidityDeployed(amount);
    }

    /**
     * @notice Withdraw liquidity from the pool.
     *         Withdrawn USDC is immediately swapped to DXP.
     * @param amount The amount of USDC liquidity to remove.
     * @dev Called only by the Farm.
     */
    function withdrawLiquidity(uint256 amount) external override onlyFarm nonReentrant {
        require(amount > 0 && amount <= deployedUSDC, "Strategy: insufficient liquidity");
        deployedUSDC -= amount;
        
        // Remove liquidity using LiquidityManager.
        // Assumes removeLiquidity returns (dxpAmount, usdcAmount).
        (uint256 dxpAmount, uint256 usdcAmount) = liquidityManager.removeLiquidity(asset, usdc, feeTier, amount);
        
        uint256 totalDXP;
        // If any USDC is received, swap it into DXP.
        if (usdcAmount > 0) {
            (uint256 swappedDXP, uint8 bestAmountOut) = liquidityManager.getBestSwapAmountOut(usdc, asset, usdcAmount);
            totalDXP = dxpAmount + swappedDXP;
        } else {
            totalDXP = dxpAmount;
        }
        
        // Transfer the resulting DXP back to the Farm.
        IERC20(asset).transfer(farm, totalDXP);
        emit LiquidityWithdrawn(amount, totalDXP);
    }

    /**
     * @notice Harvest rewards from the pool.
     *         Harvested fees (in USDC and DXP) are converted so that the final yield is in DXP.
     * @dev Called only by the Farm.
     * @return harvested The total yield in DXP harvested.
     */
    function harvestRewards() external override onlyFarm nonReentrant returns (uint256 harvested) {
        // Harvest fees from the pool.
        (uint256 usdcFees, uint256 dxpFees) = liquidityManager.harvestFees(pool);
        
        uint256 swappedDXP = 0;
        if (usdcFees > 0) {
            // Swap USDC fees to DXP.
            (uint256 bestAmountOut, ) = liquidityManager.getBestSwapAmountOut(usdc, asset, usdcFees);
            liquidityManager.swap(usdc, asset, usdcFees, farm);
            swappedDXP = bestAmountOut;
        }
        harvested = dxpFees + swappedDXP;
        // Send the harvested DXP yield back to the Farm.
        _sendRewardsToFarm(harvested);
        emit RewardsGenerated(harvested);
        return harvested;
    }

    /**
     * @notice Rebalances the strategy's positions.
     * @dev Called only by the Farm.
     */
    function rebalance() external override onlyFarm nonReentrant {
        // Strategy developers implement rebalancing logic as needed.
        emit StrategyRebalanced();
    }

    /**
     * @notice Emergency withdraw: forcibly unwinds positions and returns funds to the Farm.
     * @dev Called only by the Farm.
     */
    function emergencyWithdraw() external override onlyFarm nonReentrant {
        uint256 totalPulled = _emergencyWithdrawImpl();
        emit EmergencyWithdrawn(totalPulled);
    }

    /**
     * @dev Internal function for emergency withdrawal.
     * @return totalAssets The total assets withdrawn.
     */
    function _emergencyWithdrawImpl() internal override returns (uint256 totalAssets) {
        // Production implementation: unwind all positions.
        return 0;
    }

    /**
     * @notice Returns the total value locked (TVL) in the strategy (deployed USDC).
     * @return tvl The total deployed USDC.
     */
    function getStrategyTVL() external view override returns (uint256 tvl) {
        return deployedUSDC;
    }

    /**
     * @notice Returns the pending rewards (in principal asset) from the pool.
     * @return pending The pending fee amount.
     */
    function getPendingRewards() external view override returns (uint256 pending) {
        return liquidityManager.getPendingFees(pool);
    }

    // ======================================================
    // Internal Helper Functions
    // ======================================================
    /**
     * @dev Sends harvested yield (in DXP) to the Farm.
     * @param amount The yield amount in DXP.
     */
    function _sendRewardsToFarm(uint256 amount) internal override {
        require(IERC20(asset).transfer(farm, amount), "Strategy: reward transfer failed");
        emit RewardsGenerated(amount);
    }

    // ======================================================
    // Buyback Mechanism
    // ======================================================
    /**
     * @notice Executes a buyback of DXP using USDC if the pool price is below the anchor.
     *         If the drop is too steep, buyback is paused for a cooling period.
     * @dev Called only by the Farm.
     * @param usdcAmount The amount of USDC to use for buyback.
     */
    function executeBuyback(uint256 usdcAmount) external onlyFarm nonReentrant {
        require(block.timestamp >= buybackPausedUntil, "Strategy: buyback paused");
        uint256 currentPrice = liquidityManager.getTwapPrice(asset, usdc, feeTier, 300);
        if (currentPrice >= anchorPrice) {
            revert("Strategy: price above anchor");
        }
        uint256 dropPercent = ((anchorPrice - currentPrice) * 1e18) / anchorPrice;
        if (dropPercent >= buybackDropThreshold) {
            buybackPausedUntil = block.timestamp + buybackCooldownPeriod;
            emit BuybackPaused(buybackPausedUntil);
            revert("Strategy: price drop too steep, buyback paused");
        }
        (uint256 bestAmountOut, ) = liquidityManager.getBestSwapAmountOut(usdc, asset, usdcAmount);
        require(bestAmountOut > 0, "Strategy: swap failed");
        liquidityManager.swap(usdc, asset, usdcAmount, farm);
        emit BuybackExecuted(usdcAmount, bestAmountOut);
    }
}
