// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./Farm.sol";
import "./interfaces/FarmStrategy.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title RootFarm
 * @notice Specialized Farm for DexponentProtocol where the principal asset is DXP.
 *         LPs deposit DXP and receive vDXP 1:1. Deposited DXP is locked;
 *         any fees incurred via vDXP transfers (handled by vDXP's fee logic) call unlockDXP,
 *         thereby unlocking DXP from the locked pool to be later distributed as yield/revenue.
 *
 *         Note: All deposit bonus logic is handled at the Protocol level for non‑Root farms.
 */
contract RootFarm is Farm {
    /// @notice Tracks the total DXP that is locked in the farm.
    uint256 public lockedDXP;

    /**
     * @notice Constructs the RootFarm.
     * @param _dxpToken The DXP token address (the asset for RootFarm).
     * @param _maturityPeriod A reference maturity period (each deposit can choose its own).
     * @param _verifierIncentiveSplit Percentage share for verifiers.
     * @param _yieldYodaIncentiveSplit Percentage share for yield yodas.
     * @param _lpIncentiveSplit Percentage share for LPs.
     * @param _strategy Address of the attached market-making strategy.
     * @param _protocolMaster Address of the protocol master.
     * @param _claimToken Address of the vDXP claim token.
     * @param _farmOwner The owner of RootFarm (typically the protocol).
     */
    constructor(
        uint256 _farmId,
        address _dxpToken,
        uint256 _maturityPeriod,
        uint256 _verifierIncentiveSplit,
        uint256 _yieldYodaIncentiveSplit,
        uint256 _lpIncentiveSplit,
        address _strategy,
        address _protocolMaster,
        address _claimToken,
        address _farmOwner
    )
        Farm(
            _farmId,
            _dxpToken,              // asset is DXP
            _maturityPeriod,
            _verifierIncentiveSplit,
            _yieldYodaIncentiveSplit,
            _lpIncentiveSplit,
            _strategy,
            _protocolMaster,
            _claimToken,
            _farmOwner
        )
    {
        // Initially, all deposited DXP remains locked.
    }

    /**
     * @notice Allows an LP to deposit DXP into the RootFarm.
     *         In RootFarm, there is no bonus issuance since deposit = DXP → vDXP.
     *         The deposited DXP is added to both totalLiquidity and lockedDXP.
     * @param amount The deposit amount in DXP.
     * @param maturity The desired maturity timestamp for the deposit.
     */
    function provideLiquidity(uint256 amount, uint256 maturity)
        external
        payable
        override
        whenNotPaused
        nonReentrant
    {
        require(amount > 0, "RootFarm: deposit must be > 0");
        require(maturity >= minimumMaturityPeriod, "RootFarm: maturity too short");
        // Transfer DXP from LP to RootFarm.
        require(
            IERC20(asset).transferFrom(msg.sender, address(this), amount),
            "RootFarm: DXP transfer failed"
        );
        totalLiquidity += amount;
        lockedDXP += amount; // All deposited DXP is locked.

        // Update LP's aggregated position.
        Position storage pos = positions[msg.sender];
        uint256 oldPrincipal = pos.principal;
        uint256 newPrincipal = oldPrincipal + amount;
        if (oldPrincipal == 0) {
            pos.weightedMaturity = maturity;
        } else {
            // Weighted average maturity calculation.
            pos.weightedMaturity = ((oldPrincipal * pos.weightedMaturity) + (amount * maturity)) / newPrincipal;
        }
        pos.principal = newPrincipal;
        pos.lastUpdate = block.timestamp;

        // Update yield debt so that yield accrual starts fresh from this deposit.
        yieldDebt[msg.sender] = (newPrincipal * accYieldPerShare) / 1e18;

        // Mint claim token (vDXP) in a 1:1 ratio.
        claimToken.mint(msg.sender, amount);

        emit LiquidityProvided(msg.sender, amount, pos.weightedMaturity);
    }

    /**
     * @notice Allows an LP to withdraw DXP from their position.
     *         Applies a 0.5% slash fee if withdrawn before maturity.
     *         Burns the corresponding claim tokens and unlocks DXP from the locked pool.
     * @param amount The amount of DXP to withdraw.
     * @param returnBonus (Unused in RootFarm; no bonus logic is applied.)
     */
    function withdrawLiquidity(uint256 amount, bool returnBonus)
        external
        override
        whenNotPaused
        nonReentrant
    {
        Position storage pos = positions[msg.sender];
        require(amount > 0 && amount <= pos.principal, "RootFarm: invalid withdrawal amount");

        // Determine if the withdrawal is early.
        bool isEarly = (block.timestamp < pos.weightedMaturity);
        uint256 fee;
        if (isEarly) {
            fee = (amount * 5) / 1000; // 0.5% slash fee.
            // In RootFarm, the slash fee is simply added to revenue.
            farmRevenueDXP += fee;
            emit SlashFeeApplied(msg.sender, fee);
        }
        uint256 netWithdrawal = amount - fee;

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

        // Unlock the withdrawn DXP from the locked pool.
        require(lockedDXP >= amount, "RootFarm: insufficient locked DXP");
        lockedDXP -= amount;

        // Transfer net DXP back to the LP.
        require(IERC20(asset).transfer(msg.sender, netWithdrawal), "RootFarm: transfer failed");

        emit PrincipalRedeemed(msg.sender, netWithdrawal);
    }

    /**
     * @notice Unlocks DXP from the locked pool. Called by the vDXP token (claim token)
     *         when a transfer fee is deducted from vDXP transfers.
     *         The unlocked DXP is added to farmRevenueDXP, making it available for distribution.
     * @param amount The amount of DXP to unlock.
     */
    function unlockDXP(uint256 amount) external nonReentrant {
        // Only callable by the associated claim token (vDXP).
        require(msg.sender == address(claimToken), "RootFarm: caller is not claim token");
        require(lockedDXP >= amount, "RootFarm: insufficient locked DXP");
        lockedDXP -= amount;
        farmRevenueDXP += amount;
    }

    function addRevenueDXP(uint256 amount) external nonReentrant onlyProtocolMaster {
        farmRevenueDXP += amount;
    }
}
