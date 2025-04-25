// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "./interfaces/BaseClaimToken.sol"; // Claim token interface.
import "./interfaces/ILiquidityManager.sol"; // For swapping principal yield to DXP.
import "./interfaces/IProtocolCore.sol"; // Protocol master interface.
import "./interfaces/FarmStrategy.sol"; // Interface for the strategy contract.

/// @title IFarmLiquidityPool
/// @notice Minimal interface for a pool associated with the Farm.
///         This pool should provide at least the DXP token address.
interface IFarmLiquidityPool {
    function getDXPToken() external view returns (address);
}

/**
 * @title Farm
 * @notice Base contract for Farms managing LP deposits, yield accrual,
 *         bonus issuance/reversal, and liquidity deployment to an associated Strategy.
 *         Designed for both non‑Root farms and RootFarm.
 */
contract Farm is Ownable, ReentrancyGuard {
    // ======================================================
    // Principal & Liquidity Tracking
    // ======================================================
    /// @notice The principal asset deposited (ERC20; if native, address(0)).
    address public asset;

    address public farmOwner;
    uint256 public farmId;

    /// @notice Total principal deposited by all LPs.
    uint256 public totalLiquidity;

    /// @notice Amount of principal already deployed to the strategy.
    uint256 public deployedLiquidity;

    /// @notice Returns available liquidity held in the Farm.
    function availableLiquidity() public view returns (uint256) {
        return totalLiquidity - deployedLiquidity;
    }

    /// @notice Accumulated principal penalty fees (slash fees) held in reserve.
    uint256 public principalReserve;

    // ======================================================
    // Yield Tracking (Accumulator Model)
    // ======================================================
    /// @notice Global accumulator for yield per share, scaled by 1e18.
    uint256 public accYieldPerShare;

    /// @notice Mapping of each LP’s yield debt.
    mapping(address => uint256) public yieldDebt;

    /// @notice Accumulated yield (in DXP) that has been pulled from the strategy.
    uint256 public farmRevenueDXP;

    // ======================================================
    // LP Position Tracking (Aggregated per LP)
    // ======================================================
    struct Position {
        uint256 principal; // Total principal deposited.
        uint256 weightedMaturity; // Weighted average maturity timestamp.
        uint256 bonus; // Total bonus DXP received.
        uint256 lastUpdate; // Timestamp of the last update.
    }
    mapping(address => Position) public positions;

    uint256 public immutable minimumMaturityPeriod;
    // ======================================================
    // Incentive Splits (Immutable per Farm)
    // ======================================================
    /// @notice Percentage allocated for LPs.
    uint256 public immutable lpIncentiveSplit;

    /// @notice Percentage allocated for verifiers.
    uint256 public immutable verifierIncentiveSplit;

    /// @notice Percentage allocated for yield yodas.
    uint256 public immutable yieldYodaIncentiveSplit;
    // Farm owner's share is implicitly: 100 - (verifierIncentiveSplit + yieldYodaIncentiveSplit).

    // ======================================================
    // External Contract References
    // ======================================================
    /// @notice The claim token contract.
    BaseClaimToken public claimToken;

    /// @notice The strategy contract used to deploy liquidity.
    address public strategy;

    /// @notice The protocol master address.
    IProtocolCore public protocolMaster;

    /// @notice The LiquidityManager used for swapping yield (from principal asset to DXP).
    ILiquidityManager public liquidityManager;

    /// @notice The liquidity pool associated with this Farm (for price discovery).
    address public pool;

    // ======================================================
    // Emergency Pause
    // ======================================================
    bool public paused;
    event Paused(address indexed account);
    event Unpaused(address indexed account);

    modifier whenNotPaused() {
        require(!paused, "Farm: paused");
        _;
    }

    // ======================================================
    // Events
    // ======================================================
    event LiquidityProvided(
        address indexed lp,
        uint256 amount,
        uint256 weightedMaturity
    );
    event PositionUpdated(
        address indexed lp,
        uint256 newPrincipal,
        uint256 newWeightedMaturity
    );
    event PrincipalRedeemed(address indexed lp, uint256 netWithdrawal);
    event YieldClaimed(address indexed lp, uint256 yieldAmount);
    event RevenuePulled(
        address indexed caller,
        uint256 harvestedYield,
        uint256 convertedToDXP
    );
    event DeployedLiquidity(uint256 amount);
    event WithdrawnFromStrategy(uint256 amount);
    event SlashFeeApplied(address indexed lp, uint256 fee);
    event PrincipalReserveUpdated(uint256 feeAmount, uint256 newReserve);
    event BonusDistributionFailed(
        address indexed lp,
        uint256 principal,
        uint256 maturity
    );
    event BonusReversalFailed(address indexed lp, uint256 amount, bool isEarly);
    event FullExitProcessed(
        address indexed lp,
        uint256 principalWithdrawn,
        uint256 bonusReturned,
        uint256 yieldClaimed
    );

    // ======================================================
    // Modifiers
    // ======================================================
    modifier onlyProtocolMaster() {
        require(
            msg.sender == address(protocolMaster),
            "Farm: caller is not protocol master"
        );
        _;
    }

    modifier onlyFarmOwner() {
        require(
            msg.sender == farmOwner || msg.sender == owner(),
            "Farm: caller is not farm owner or protocol"
        );
        _;
    }

    // ======================================================
    // Constructor
    // ======================================================
    /**
     * @notice Constructs a new Farm.
     * @param _asset The principal asset address.
     * @param _maturityPeriod Reference maturity period (each deposit carries its own maturity).
     * @param _verifierIncentiveSplit Percentage for verifiers.
     * @param _yieldYodaIncentiveSplit Percentage for yield yodas.
     * @param _lpIncentiveSplit Percentage for LPs.
     * @param _strategy Address of the strategy contract.
     * @param _protocolMaster Address of the protocol master.
     * @param _claimToken Address of the claim token contract.
     * @param _farmOwner The owner of this Farm.
     */
    constructor(
        uint256 _farmId,
        address _asset,
        uint256 _maturityPeriod,
        uint256 _verifierIncentiveSplit,
        uint256 _yieldYodaIncentiveSplit,
        uint256 _lpIncentiveSplit,
        address _strategy,
        address _protocolMaster,
        address _claimToken,
        address _farmOwner
    ) Ownable(_protocolMaster) {
        farmId = _farmId;

        asset = _asset;
        verifierIncentiveSplit = _verifierIncentiveSplit;
        yieldYodaIncentiveSplit = _yieldYodaIncentiveSplit;
        lpIncentiveSplit = _lpIncentiveSplit;
        strategy = _strategy;
        protocolMaster = IProtocolCore(_protocolMaster);
        claimToken = BaseClaimToken(_claimToken);
        minimumMaturityPeriod = _maturityPeriod;
        totalLiquidity = 0;
        deployedLiquidity = 0;
        principalReserve = 0;
        farmRevenueDXP = 0;
        accYieldPerShare = 0;
        paused = false;

        farmOwner = _farmOwner;
    }

    function updateStrategy(address _strategy) external onlyFarmOwner {
        strategy = _strategy;
    }

    // ======================================================
    // Administrative Functions
    // ======================================================
    /**
     * @notice Allows the farm owner to pause the farm (disables deposits/withdrawals).
     */
    function pause() external onlyFarmOwner {
        paused = true;
        emit Paused(msg.sender);
    }

    /**
     * @notice Allows the farm owner to unpause the farm.
     */
    function unpause() external onlyFarmOwner {
        paused = false;
        emit Unpaused(msg.sender);
    }

    // ======================================================
    // Pool Setter (for Price Swaps)
    // ======================================================
    /**
     * @notice Sets the liquidity pool associated with this Farm.
     * @param _pool The address of the pool.
     */
    function setPool(address _pool) external onlyFarmOwner {
        require(_pool != address(0), "Farm: invalid pool address");
        pool = _pool;
    }

    // ======================================================
    // LP Deposit Functionality
    // ======================================================
    /**
     * @notice Allows an LP to deposit principal into the Farm.
     *         Deposits are aggregated into a single position per LP.
     *         Claim tokens (1:1) are minted.
     *         Deposited funds remain in the Farm until deployed to the strategy.
     * @param amount The deposit amount in principal units.
     * @param maturity The desired maturity timestamp for the deposit.
     */
    function provideLiquidity(
        uint256 amount,
        uint256 maturity
    ) external payable virtual nonReentrant whenNotPaused {
        require(amount > 0, "Farm: deposit must be > 0");
        // Transfer principal into the Farm.
        if (asset != address(0)) {
            require(
                IERC20(asset).transferFrom(msg.sender, address(this), amount),
                "Farm: transfer failed"
            );
        } else {
            require(msg.value == amount, "Farm: native asset mismatch");
        }

        require(maturity >= minimumMaturityPeriod, "Farm: maturity too short");

        totalLiquidity += amount;

        // Update the LP's aggregated position.
        Position storage pos = positions[msg.sender];
        uint256 oldPrincipal = pos.principal;
        uint256 newPrincipal = oldPrincipal + amount;
        if (oldPrincipal == 0) {
            pos.weightedMaturity = maturity;
        } else {
            pos.weightedMaturity =
                ((oldPrincipal * pos.weightedMaturity) + (amount * maturity)) /
                newPrincipal;
        }
        pos.principal = newPrincipal;
        pos.lastUpdate = block.timestamp;

        // Update yield debt so LP does not claim yield accrued before this deposit.
        yieldDebt[msg.sender] = (newPrincipal * accYieldPerShare) / 1e18;

        // Mint claim tokens (1:1).
        claimToken.mint(msg.sender, amount);

        try
            protocolMaster.distributeDepositBonus(
                farmId,
                msg.sender,
                amount,
                maturity
            )
        {
            // Bonus distribution handled in the protocol master.
        } catch {
            // Handle any errors from the protocol master.
            emit BonusDistributionFailed(msg.sender, amount, maturity);
        }

        emit LiquidityProvided(msg.sender, amount, pos.weightedMaturity);
    }

    // ======================================================
    // LP Withdrawal & Position Closure
    // ======================================================
    /**
     * @notice Allows an LP to withdraw principal from their position.
     *         If withdrawing before maturity, a 0.5% slash fee is applied.
     *         Optionally, the LP may choose to return bonus tokens for full yield.
     *         Claim tokens corresponding to withdrawn principal are burned.
     * @param amount The amount of principal to withdraw.
     * @param returnBonus True if the LP opts to return bonus tokens.
     */
    function withdrawLiquidity(
        uint256 amount,
        bool returnBonus
    ) external virtual nonReentrant whenNotPaused {
        Position storage pos = positions[msg.sender];
        require(
            amount > 0 && amount <= pos.principal,
            "Farm: invalid withdrawal amount"
        );

        // Determine if withdrawal is early.
        bool isEarly = (block.timestamp < pos.weightedMaturity);
        uint256 slashFee;
        if (isEarly) {
            slashFee = (amount * 5) / 1000; // 0.5% slash fee.
            principalReserve += slashFee;
            emit SlashFeeApplied(msg.sender, slashFee);
        }
        uint256 netWithdrawal = amount - slashFee;

        // If LP opts to return bonus, reduce bonus proportionally.
        if (returnBonus && pos.bonus > 0) {
            uint256 bonusToReturn = (pos.bonus * amount) / pos.principal;
            pos.bonus -= bonusToReturn;
            // (Bonus return processing can be handled externally.)
        }

        // Update LP position.
        pos.principal -= amount;
        pos.lastUpdate = block.timestamp;
        emit PositionUpdated(msg.sender, pos.principal, pos.weightedMaturity);

        // Update yield debt.
        if (pos.principal > 0) {
            yieldDebt[msg.sender] = (pos.principal * accYieldPerShare) / 1e18;
        } else {
            yieldDebt[msg.sender] = 0;
        }

        // Burn claim tokens corresponding to the withdrawn amount.
        claimToken.burn(msg.sender, amount);
        if (isEarly || returnBonus) {
            // Try/catch for any external revert
            try
                protocolMaster.reverseDepositBonus(
                    farmId,
                    msg.sender,
                    amount,
                    isEarly
                )
            {
                // success
            } catch {
                emit BonusReversalFailed(msg.sender, amount, isEarly);
            }
        }

        // Transfer principal back to LP.
        uint256 available = availableLiquidity();
        if (available >= netWithdrawal) {
            if (asset != address(0)) {
                require(
                    IERC20(asset).transfer(msg.sender, netWithdrawal),
                    "Farm: transfer failed"
                );

                _claimYield(msg.sender);
            } else {
                (bool success, ) = msg.sender.call{value: netWithdrawal}("");
                require(success, "Farm: native transfer failed");
            }
        } else {
            uint256 needed = netWithdrawal - available;
            if (available > 0) {
                if (asset != address(0)) {
                    require(
                        IERC20(asset).transfer(msg.sender, available),
                        "Farm: transfer failed"
                    );
                } else {
                    (bool success, ) = msg.sender.call{value: available}("");
                    require(success, "Farm: native transfer failed");
                }
            }
            FarmStrategy(strategy).withdrawLiquidity(needed);
            if (asset != address(0)) {
                require(
                    IERC20(asset).transfer(msg.sender, needed),
                    "Farm: post-withdraw transfer failed"
                );
                _claimYield(msg.sender);
            } else {
                (bool success, ) = msg.sender.call{value: needed}("");
                require(success, "Farm: native post-withdraw transfer failed");
            }
        }

        emit PrincipalRedeemed(msg.sender, netWithdrawal);
    }

    /**
     * @notice Allows an LP to fully exit their position.
     *         This function withdraws all principal, forces bonus return, and claims any pending yield.
     */
    function fullExit() external nonReentrant whenNotPaused {
        Position storage pos = positions[msg.sender];
        uint256 amount = pos.principal;
        require(amount > 0, "Farm: no position to exit");

        // Force bonus return (i.e. treat as if LP opts to return bonus).
        if (pos.bonus > 0) {
            // Here, bonus return processing can be handled—e.g., invoking protocol functions.
            pos.bonus = 0;
        }

        // Withdraw entire position (this will apply slash fee if early).
        this.withdrawLiquidity(amount, true);

        // After withdrawal, claim any pending yield.
        _claimYield(msg.sender);

        emit FullExitProcessed(msg.sender, amount, pos.bonus, 0);
    }

    // ======================================================
    // Yield Claim Functionality
    // ======================================================
    /**
     * @notice Returns the pending yield (in DXP) for an LP.
     * @param lp The address of the LP.
     * @return pendingYieldVal The amount of DXP pending as yield.
     */
    function pendingYield(
        address lp
    ) external view returns (uint256 pendingYieldVal) {
        Position storage pos = positions[lp];
        if (pos.principal == 0) return 0;
        uint256 accumulated = (pos.principal * accYieldPerShare) / 1e18;
        if (accumulated < yieldDebt[lp]) return 0;
        pendingYieldVal = accumulated - yieldDebt[lp];
    }

    /**
     * @notice Allows an LP to claim their pending yield in DXP.
     *         Pending yield is computed as:
     *           (LP principal * accYieldPerShare / 1e18) - yieldDebt.
     *         After claiming, yieldDebt is updated.
     */
    function claimYield() external nonReentrant {
        _claimYield(msg.sender);
    }

    function _claimYield(address user) internal {
        Position storage pos = positions[user];
        require(pos.principal > 0, "Farm: no active position");

        uint256 principal = pos.principal;
        if (principal == 0) {
            return;
        }
        uint256 accumulated = (principal * accYieldPerShare) / 1e18;
        require(
            accumulated >= yieldDebt[msg.sender],
            "Farm: yield calculation error"
        );

        uint256 pending = accumulated - yieldDebt[msg.sender];
        if (pending == 0) {
            return;
        }

        // Update yield debt.

        yieldDebt[user] = accumulated;

        // Transfer DXP from farm to user
        // The farm presumably holds the DXP that belongs to local yield
        // (the portion from `_addLocalLPYield(...)`).
        address dxpTokenAddr = IFarmLiquidityPool(pool).getDXPToken();
        IERC20(dxpTokenAddr).transfer(user, pending);

        emit YieldClaimed(user, pending);
    }

    // ======================================================
    // Liquidity Deployment & Withdrawal by Farm Owner
    // ======================================================
    /**
     * @notice Allows the Farm owner to deploy available liquidity to the strategy.
     *         Moves funds from the Farm's available pool to deployedLiquidity.
     * @param amount The amount of principal to deploy.
     */
    function deployLiquidity(
        uint256 amount
    ) external onlyFarmOwner nonReentrant whenNotPaused {
        require(
            amount > 0 && amount <= availableLiquidity(),
            "Farm: insufficient liquidity"
        );
        deployedLiquidity += amount;
        if (asset != address(0)) {
            IERC20(asset).approve(strategy, amount);
            FarmStrategy(strategy).deployLiquidity(amount);
        } else {
            FarmStrategy(strategy).deployLiquidity{value: amount}(amount);
        }
        emit DeployedLiquidity(amount);
    }

    /**
     * @notice Allows the Farm owner to withdraw liquidity from the strategy back into the Farm.
     * @param amount The amount to withdraw.
     */
    function withdrawFromStrategy(
        uint256 amount
    ) external onlyFarmOwner nonReentrant whenNotPaused {
        require(
            amount > 0 && amount <= deployedLiquidity,
            "Farm: insufficient deployed liquidity"
        );
        deployedLiquidity -= amount;
        FarmStrategy(strategy).withdrawLiquidity(amount);
        emit WithdrawnFromStrategy(amount);
    }

    // ======================================================
    // Yield / Revenue Pull Mechanism
    // ======================================================
    /**
     * @notice Pulls yield from the strategy, converts it to DXP (if needed) using the LiquidityManager,
     *         and updates the global yield accumulator (accYieldPerShare).
     *         This function should be called periodically by the protocol.
     *         If the LiquidityManager fails to return a valid swap price, a fallback price of 1e18 is used (TESTNET ONLY).
     * @return revenue The net yield in DXP pulled from the strategy.
     */
    function pullFarmRevenue() external virtual nonReentrant returns (uint256) {
        require(
            msg.sender == address(protocolMaster),
            "Only Protocol can pull revenue"
        );

        // 1) Gather slash reserves from principalReserve

        // 2) Harvest the normal yield from the strategy (still in principal).
        uint256 harvested = FarmStrategy(strategy).harvestRewards();

        // 3) Combine slash + normal harvested principal
        uint256 totalPrincipal = harvested + principalReserve;
        principalReserve = 0; //reset
        if (totalPrincipal == 0) {
            // No new yield => return 0
            return 0;
        }

        // 4) Convert the entire `totalPrincipal` into DXP
        //    using your LiquidityManager swap if `asset != dxpToken`.
        address dxp = IFarmLiquidityPool(pool).getDXPToken();
        uint256 yieldInDXP;

        if (asset == dxp) {
            // If the farm's principal *is* DXP, we skip swaps
            yieldInDXP = totalPrincipal;
        } else {
            // e.g. call liquidityManager to do the swap
            (uint256 bestOut, ) = liquidityManager.getBestSwapAmountOut(
                asset,
                dxp,
                totalPrincipal
            );
            if (bestOut == 0) {
                // fallback if no route => assume 1:1 on testnets if you like
                bestOut = totalPrincipal;
            }
            yieldInDXP = bestOut;

            // Actually execute the swap so the farm receives DXP
            liquidityManager.swap(asset, dxp, totalPrincipal, address(this));
        }

        // 5) Save it as farmRevenueDXP, then clear for the return
        uint256 lpShare = (yieldInDXP * lpIncentiveSplit) / 100;
        uint256 remainder = yieldInDXP - lpShare;

        _addLocalLPYield(lpShare);

        farmRevenueDXP += remainder;
        uint256 revenue = farmRevenueDXP;
        farmRevenueDXP = 0;

        IERC20(dxp).transfer(msg.sender, revenue);
        return revenue;
    }

    function _addLocalLPYield(uint256 dxpAmount) internal {
        if (totalLiquidity == 0) {
            // No depositors exist right now, so either do nothing
            // or store it in a leftover bucket
            return;
        }
        // Increase the accumulator
        // This means each user principal will have “more yield” to claim.
        accYieldPerShare += (dxpAmount * 1e18) / totalLiquidity;
    }

    // ======================================================
    // Update Principal Reserve Called by Claim Token
    // ======================================================
    /**
     * @notice Called by the associated claim token when a transfer fee is deducted.
     *         Updates the principal reserve by adding the fee amount.
     * @param fee The fee amount.
     */
    function updatePrincipalReserve(uint256 fee) external {
        require(
            msg.sender == address(claimToken),
            "Farm: caller is not associated claim token"
        );
        principalReserve += fee;
        emit PrincipalReserveUpdated(fee, principalReserve);
    }
}
