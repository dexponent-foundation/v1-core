// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../../interfaces/FarmStrategy.sol";
import "../../interfaces/ILiquidityManager.sol";

/**
 * @title LidoStETHStrategy
 * @notice A Dexponent Protocol strategy that stakes WETH into Lido's stETH contract on Sepolia.
 *         Because Lido stETH on Sepolia does not automatically yield, we simulate ~4% APY.
 *
 *         Key Flow:
 *           - The Farm calls deployLiquidity(amountInWETH) => We unwrap WETH to ETH => stETH.submit(...) => strategy receives stETH.
 *           - We track stETH balance and simulate yield in harvestRewards() or partial calls to "simulateAPY()".
 *           - For withdrawals, we attempt stETH->WETH swap via ILiquidityManager if a test aggregator/DEX is available.
 *
 *         IMPORTANT: On real mainnet, stETH automatically rebases. Here on Sepolia we must do a manual simulation of yield.
 */
contract LidoStETHStrategy is FarmStrategy {
    using SafeERC20 for IERC20;

    // ------------------------------------------------
    // Immutable References
    // ------------------------------------------------

    /// @notice The Lido stETH contract on Sepolia (proxy).
    address public immutable lidoStETH;

    /// @notice The WETH token address on Sepolia (the principal asset).
    address public immutable weth;

    /// @notice Optional aggregator or LiquidityManager for stETH↔WETH swaps.
    ILiquidityManager public immutable liquidityManager;

    // ------------------------------------------------
    // State for Simulating Yield
    // ------------------------------------------------

    /// @dev Last stETH balance recorded, used to detect new yield after simulation.
    uint256 public lastStETHBalance;

    /// @dev The timestamp of the last yield checkpoint (for 4% APY calculation).
    uint256 public lastYieldCheckpoint;

    /// @dev Annual APY in basis points (4.00% = 400 bps).
    uint256 public constant ANNUAL_APY_BPS = 400;

    /// @dev Approx seconds in a year for the APY calculation.
    uint256 public constant YEAR_IN_SECONDS = 365 days;

    // ------------------------------------------------
    // Events
    // ------------------------------------------------
    event SimulatedYield(uint256 mintedStETH);

    /**
     * @notice Constructor
     * @param _farm The Farm contract that owns this strategy.
     * @param _asset The principal asset: WETH address on Sepolia.
     * @param _lidoStETH The Lido stETH contract on Sepolia.
     * @param _liquidityManager An aggregator or LiquidityManager for test swaps, can be address(0) if none.
     */
    constructor(
        address _farm,
        address _asset,
        address _lidoStETH,
        address _liquidityManager
    ) FarmStrategy(_farm, _asset) Ownable(msg.sender) {
        require(_asset != address(0), "Invalid WETH address");
        require(_lidoStETH != address(0), "Invalid stETH address");

        weth = _asset;
        lidoStETH = _lidoStETH;
        liquidityManager = ILiquidityManager(_liquidityManager);

        lastYieldCheckpoint = block.timestamp;
    }

    // ------------------------------------------------
    // FarmStrategy Overrides
    // ------------------------------------------------

    /**
     * @notice Deploys WETH into Lido's stETH on Sepolia by unwrapping to ETH and calling stETH.submit(0).
     * @param amount The amount of WETH to stake.
     */
    function deployLiquidity(uint256 amount)
        external
        payable
        override
        onlyFarm
        nonReentrant
    {
        require(amount > 0, "Deploy: amount=0");

        // Step 1: Transfer WETH from Farm to this strategy
        IERC20(weth).safeTransferFrom(msg.sender, address(this), amount);

        // Step 2: Unwrap WETH -> ETH
        _unwrapWETH(amount);

        // Step 3: Stake ETH into Lido: stETH.submit(referral=0)
        (bool success, ) = lidoStETH.call{value: amount}(
            abi.encodeWithSignature("submit(address)", address(0))
        );
        require(success, "Lido submit failed");

        // Update stETH balance state
        uint256 stBalance = IERC20(lidoStETH).balanceOf(address(this));
        lastStETHBalance = stBalance;

        emit LiquidityDeployed(amount);
    }

    /**
     * @notice Withdraws a specified 'stETH portion' from the strategy, converting stETH -> WETH.
     * @param amount The amount of stETH to withdraw.
     */
    function withdrawLiquidity(uint256 amount)
        external
        override
        onlyFarm
        nonReentrant
    {
        require(amount > 0, "Withdraw=0");

        // 1) Simulate yield to sync stETH balances.
        _simulateAPY();

        uint256 stBal = IERC20(lidoStETH).balanceOf(address(this));
        require(amount <= stBal, "Not enough stETH");

        // 2) Swap stETH -> WETH using aggregator if available
        uint256 swappedWeth = 0;
        if (address(liquidityManager) != address(0)) {
            // Approve aggregator
            IERC20(lidoStETH).safeIncreaseAllowance(address(liquidityManager), amount);

            // Attempt swap: stETH => WETH
            liquidityManager.swap(lidoStETH, weth, amount, address(this));

            // Revoke approval
            IERC20(lidoStETH).forceApprove(address(liquidityManager), 0);

            // Now we hold the result in WETH
            swappedWeth = IERC20(weth).balanceOf(address(this));
            require(swappedWeth > 0, "No aggregator route stETH->WETH?");
        } else {
            revert("No aggregator set, stETH->WETH impossible on testnet");
        }

        // 3) Transfer the WETH back to the Farm
        IERC20(weth).safeTransfer(msg.sender, swappedWeth);

        // 4) Update local stETH balance
        uint256 newStBalance = IERC20(lidoStETH).balanceOf(address(this));
        lastStETHBalance = newStBalance;

        emit LiquidityWithdrawn(amount);
    }

    /**
     * @notice Harvests yield from stETH. 
     *         On Sepolia, stETH does not auto-rebase, so we do a manual 4% APY simulation for demonstration.
     * @return harvested The amount of yield converted to WETH and sent to the Farm.
     */
    function harvestRewards() 
        external
        override
        onlyFarm
        nonReentrant
        returns (uint256 harvested)
    {
        // 1) Simulate new yield => adjust stETH balance
        _simulateAPY();

        // 2) Check how much stETH in excess over lastStETHBalance
        uint256 stBal = IERC20(lidoStETH).balanceOf(address(this));
        uint256 stExcess = (stBal > lastStETHBalance) 
            ? (stBal - lastStETHBalance)
            : 0;
        if (stExcess == 0) {
            return 0; // no new stETH to harvest
        }

        // 3) Convert stExcess -> WETH via aggregator
        if (address(liquidityManager) != address(0)) {
            IERC20(lidoStETH).safeIncreaseAllowance(address(liquidityManager), stExcess);
            liquidityManager.swap(lidoStETH, weth, stExcess, address(this));
            IERC20(lidoStETH).forceApprove(address(liquidityManager), 0);

            harvested = IERC20(weth).balanceOf(address(this));
            if (harvested > 0) {
                // 4) Send the harvested WETH to the Farm
                _sendRewardsToFarm(harvested);
            }
        } else {
            // If no aggregator, we skip the partial harvest approach
            harvested = 0;
        }

        // 5) Update lastStETHBalance
        uint256 newStBal = IERC20(lidoStETH).balanceOf(address(this));
        lastStETHBalance = newStBal;

        return harvested;
    }

    /**
     * @notice Rebalances stETH position. On testnet Lido, there's no real rebalancing.
     */
    function rebalance() external override onlyFarm nonReentrant {
        // No advanced logic for stETH on testnet
        emit StrategyRebalanced();
    }

    /**
     * @notice Emergency withdraw: tries to swap all stETH -> WETH and sends to Farm.
     */
    function emergencyWithdraw()
        external
        override
        onlyFarm
        nonReentrant
    {
        uint256 totalWithdrawn = _emergencyWithdrawImpl();
        emit EmergencyWithdrawn(totalWithdrawn);
    }

    /**
     * @dev Internal function that forcibly pulls all stETH back to WETH (if aggregator) and sends to Farm.
     * @return totalAssets The amount of WETH returned to the Farm.
     */
    function _emergencyWithdrawImpl() internal override returns (uint256 totalAssets) {
        // 1) Attempt stETH->WETH swap for entire stETH balance
        uint256 stBal = IERC20(lidoStETH).balanceOf(address(this));
        if (stBal > 0 && address(liquidityManager) != address(0)) {
            IERC20(lidoStETH).safeIncreaseAllowance(address(liquidityManager), stBal);
            liquidityManager.swap(lidoStETH, weth, stBal, address(this));
            IERC20(lidoStETH).forceApprove(address(liquidityManager), 0);
        }
        // 2) All WETH is now in this contract
        totalAssets = IERC20(weth).balanceOf(address(this));
        if (totalAssets > 0) {
            // Send it to the Farm
            IERC20(weth).safeTransfer(farm, totalAssets);
        }
        // 3) Reset stETHBalance
        lastStETHBalance = IERC20(lidoStETH).balanceOf(address(this));
        return totalAssets;
    }

    /**
     * @notice Returns the total value locked in stETH, in WETH terms. 
     * @return tvl The strategy’s approximate TVL in WETH.
     */
    function getStrategyTVL() external view override returns (uint256 tvl) {
        // stETH on testnet is ~1:1 with ETH. A real aggregator might refine the ratio.
        uint256 stBal = IERC20(lidoStETH).balanceOf(address(this));
        tvl = stBal; // approximate 1:1 ratio
    }

    /**
     * @notice Returns the pending yield (in WETH terms) if we do a stETH->WETH swap for the simulated APY.
     * @return pendingRewards The approximate yield since last checkpoint.
     */
    function getPendingRewards() external view override returns (uint256 pendingRewards) {
        // We do a viewpoint of how much stETH would have minted from 4% APY since last checkpoint.
        // Then consider that as stExcess in stETH, and treat 1 stETH = 1 WETH for an approximate.
        uint256 stBal = IERC20(lidoStETH).balanceOf(address(this));
        if (stBal == 0) return 0;

        // Time since last yield checkpoint
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0) return 0;

        // yield = stBal * (annualRateBPS / 10000) * (timeElapsed / YEAR_IN_SECONDS)
        uint256 stSim = (stBal * ANNUAL_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
        pendingRewards = stSim; // approximate 1:1 WETH ratio
    }

    // ------------------------------------------------
    // Internal Helpers
    // ------------------------------------------------

    /**
     * @notice Internal function to send harvested WETH to the Farm using ERC20 transfer.
     * @param amount The amount of WETH to send.
     */
    function _sendRewardsToFarm(uint256 amount) internal override {
        require(IERC20(weth).transfer(farm, amount), "FarmStrategy: ERC20 transfer failed");
        emit RewardsHarvested(amount);
    }

    /**
     * @notice Internal function to unwrap WETH -> ETH.
     */
    function _unwrapWETH(uint256 amount) internal {
        // WETH: function withdraw(uint wad) public
        (bool success, ) = weth.call(abi.encodeWithSignature("withdraw(uint256)", amount));
        require(success, "WETH unwrap failed");
    }

    /**
     * @notice Simulates ~4% APY growth of stETH by tracking time and indicating how much new stETH is "minted."
     *         On real mainnet, stETH rebase is automatic. On Sepolia, there's no real rebase => we do a test approach.
     */
    function _simulateAPY() internal {
        uint256 stBal = IERC20(lidoStETH).balanceOf(address(this));
        if (stBal == 0) {
            lastYieldCheckpoint = block.timestamp; 
            return;
        }
        uint256 timeElapsed = block.timestamp - lastYieldCheckpoint;
        if (timeElapsed == 0) return;

        // yield = stBal * (ANNUAL_APY_BPS/10000) * (timeElapsed / YEAR_IN_SECONDS).
        uint256 stNew = (stBal * ANNUAL_APY_BPS * timeElapsed) / (10000 * YEAR_IN_SECONDS);
        if (stNew == 0) {
            lastYieldCheckpoint = block.timestamp;
            return;
        }

        // We can't actually mint stETH from the real contract on Sepolia. 
        // So we just emit an event indicating how much stETH we "pretend" to have minted.
        // If you want actual stETH to appear, you must do an external script that calls stETH.transfer(...) 
        // from a dev account. This is purely a demonstration for your strategy logic.
        emit SimulatedYield(stNew);

        // Update the checkpoint
        lastYieldCheckpoint = block.timestamp;
    }

    // fallback to accept any ETH from WETH unwrapping, etc.
    receive() external payable {}
}
