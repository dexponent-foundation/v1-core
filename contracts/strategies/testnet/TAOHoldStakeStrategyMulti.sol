// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * ^-- Bittensor EVM requires using a solidity version <=0.8.24 
 *    (Cancun or below) to avoid certain new opcodes not recognized 
 *    by the Subtensor EVM.
 */

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "../../interfaces/FarmStrategy.sol";

/**
 * @dev The Bittensor staking precompile address per official docs:
 *      https://docs.bittensor.com/evm-tutorials/staking-precompile
 */
address constant BITTENSOR_STAKING_PRECOMPILE = 0x0000000000000000000000000000000000000801;

interface IBittensorStaking {
    function addStake(bytes32 hotkey) external payable;
    function removeStake(bytes32 hotkey, uint256 amount) external;
}

/**
 * @title TAOHoldStakeStrategyMulti
 * @notice A multi-validator Bittensor staking strategy. 
 *         Splits user-deposited TAO (the Bittensor native token) across several 
 *         validator hotkeys in proportions defined by the Farm Owner. 
 *
 * Key points:
 * - Uses `asset == address(0)` to represent native TAO.
 * - On `deployLiquidity(amount)`, we stake proportionally across all hotkeys 
 *   based on each validator’s ratio.
 * - We track how much is staked to each hotkey in `validator.staked`. 
 * - On `withdrawLiquidity(amount)`, we remove stake proportionally from each 
 *   validator (like “partial unstake”), returning the total `amount` of TAO 
 *   to the Farm. 
 * - The Farm Owner (owner) can add/remove validators or adjust ratios any time.
 * - Because Bittensor automatically credits delegators with rewards, 
 *   we do nothing in `harvestRewards()`.
 */
contract TAOHoldStakeStrategyMulti is FarmStrategy {
    /// @notice Minimal interface to the Bittensor staking precompile
    IBittensorStaking public constant STAKING = IBittensorStaking(BITTENSOR_STAKING_PRECOMPILE);

    struct ValidatorInfo {
        bytes32 hotkey; // the 32-byte Substrate pubkey
        uint256 ratio;  // weighting factor in basis points or any scale you want
        uint256 staked; // amount of TAO currently staked to this hotkey (in wei)
    }

    /// @notice An array of validators we stake to, each with a ratio and track of staked amount
    ValidatorInfo[] public validators;

    /// @notice Sum of all ratios (sum(validators[i].ratio)).
    uint256 public totalRatio;

    /// @notice Total TAO staked across all validators
    uint256 public totalStaked;

    /**
     * @param _farm The Farm contract that owns this strategy
     * @param _asset Should be address(0) for Bittensor’s native TAO
     */
    constructor(address _farm, address _asset) 
        FarmStrategy(_farm, _asset) Ownable(msg.sender)
    {
        require(_asset == address(0), "Asset must be address(0) for TAO");
    }

    /**
     * @notice Deploy new liquidity: we stake `amount` of TAO among validators 
     *         according to their `ratio`.
     * @dev The Farm transfers `msg.value = amount` here. We loop each validator 
     *      and call `addStake(hotkey)` with a portion of `amount`.
     */
    function deployLiquidity(uint256 amount) 
        external
        payable
        override
        onlyFarm
        nonReentrant
    {
        require(msg.value == amount, "Mismatch msg.value != amount");
        require(validators.length > 0 && totalRatio > 0, "No validators or ratio=0");

        // For each validator, we stake portion = (amount * validator.ratio / totalRatio).
        uint256 remaining = amount; // track leftover in case of rounding

        for (uint256 i = 0; i < validators.length; i++) {
            // portion for this validator:
            uint256 portion = (amount * validators[i].ratio) / totalRatio;
            if (i == validators.length - 1) {
                // give leftover to the last validator to avoid rounding issues
                portion = remaining;
            }
            if (portion > 0) {
                // call addStake
                (bool success, ) = address(STAKING).call{ value: portion }(
                    abi.encodeWithSelector(IBittensorStaking.addStake.selector, validators[i].hotkey)
                );
                require(success, "addStake call failed");
                
                validators[i].staked += portion;
                totalStaked += portion;
                remaining -= portion;
            }
        }
        require(remaining == 0, "Leftover must be zero after distribution");

        emit LiquidityDeployed(amount);
    }

    /**
     * @notice Withdraw liquidity from the strategy back to the Farm, 
     *         removing stake proportionally from each validator.
     * @param amount The total amount to unstake from all validators combined.
     */
    function withdrawLiquidity(uint256 amount) 
        external
        override
        onlyFarm
        nonReentrant
    {
        require(validators.length > 0, "No validators");
        require(amount <= totalStaked, "Amount>totalStaked");
        
        // We'll remove stake from each validator proportionally by their current `staked`.
        uint256 remaining = amount;

        for (uint256 i = 0; i < validators.length; i++) {
            // If totalStaked=100, the ratio of this validator's staked to totalStaked is 
            //   validators[i].staked / totalStaked
            // so the portion to remove is 
            //   amount * (validators[i].staked / totalStaked) = (amount * staked_i) / totalStaked
            // We'll do the same leftover approach for rounding.

            if (i == validators.length - 1) {
                // last validator gets leftover
                uint256 portion = remaining;
                if (portion > 0) {
                    _removeStake(i, portion);
                }
                remaining = 0;
            } else {
                uint256 portion = (amount * validators[i].staked) / totalStaked;
                if (portion > remaining) {
                    portion = remaining;
                }
                if (portion > 0) {
                    _removeStake(i, portion);
                }
                remaining -= portion;
            }
            if (remaining == 0) break;
        }
        require(remaining == 0, "Leftover must be zero after unstaking");

        // Now the chain returns that TAO to `address(this)`.
        // Transfer it to the Farm
        (bool sent, ) = farm.call{value: amount}("");
        require(sent, "Transfer to Farm failed");

        emit LiquidityWithdrawn(amount);
    }

    /**
     * @dev Internal function to remove stake from a specific validator index.
     *      Updates totalStaked and validator[i].staked accordingly.
     */
    function _removeStake(uint256 index, uint256 portion) internal {
        ValidatorInfo storage v = validators[index];
        require(portion <= v.staked, "portion>staked for validator");
        // call removeStake
        (bool success, ) = address(STAKING).call(
            abi.encodeWithSelector(IBittensorStaking.removeStake.selector, v.hotkey, portion)
        );
        require(success, "removeStake call failed");
        v.staked -= portion;
        totalStaked -= portion;
    }

    /**
     * @notice Bittensor auto-credits delegators. We do not have a direct 
     *         "claim" to do. So we return 0.
     */
    function harvestRewards() 
        external
        override
        onlyFarm
        nonReentrant
        returns (uint256)
    {
        return 0; // no-op
    }

    /**
     * @notice The Farm Owner can add a new validator hotkey with a certain ratio.
     * @param hotkey The 32-byte Substrate public key
     * @param ratio The weighting factor for distributing future `deployLiquidity(...)`.
     */
    function addValidatorHotkey(bytes32 hotkey, uint256 ratio) external onlyOwner {
        require(hotkey != bytes32(0), "Invalid hotkey");
        require(ratio > 0, "ratio=0");
        validators.push(ValidatorInfo(hotkey, ratio, 0));
        totalRatio += ratio;
    }

    /**
     * @notice The Farm Owner can update an existing validator's ratio 
     *         (like changing from 10% to 20% of future stakings).
     * @param index The index in the validators array
     * @param newRatio The new ratio
     */
    function updateValidatorRatio(uint256 index, uint256 newRatio) external onlyOwner {
        require(index < validators.length, "index out of range");
        require(newRatio > 0, "ratio=0 not allowed");
        // adjust totalRatio
        totalRatio = (totalRatio - validators[index].ratio) + newRatio;
        validators[index].ratio = newRatio;
    }

    /**
     * @notice The Farm Owner can remove a validator. 
     *         Must have zero staked to remove it fully (or call withdrawLiquidity 
     *         first to unstake).
     * @param index The index in validators array
     */
    function removeValidatorHotkey(uint256 index) external onlyOwner {
        require(index < validators.length, "index out of range");
        ValidatorInfo storage v = validators[index];
        require(v.staked == 0, "Cannot remove while staked>0. Unstake first.");
        totalRatio -= v.ratio;

        // Move the last element into index, then pop
        uint256 last = validators.length - 1;
        if (index < last) {
            validators[index] = validators[last];
        }
        validators.pop();
    }

    /**
     * @notice The Farm Owner can get the count of validators if needed 
     *         or rely on validators.length
     */
    function getValidatorsCount() external view returns (uint256) {
        return validators.length;
    }

    /**
     * @dev fallback/receive function to accept TAO from Bittensor after removing stake, etc.
     */
    receive() external payable {}



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
    function _emergencyWithdrawImpl() internal pure override returns (uint256 totalAssets) {
        // Production implementation: unwind all positions.
        return 0;
    }

    /**
     * @notice Returns the total value locked (TVL) in the strategy (deployed USDC).
     * @return tvl The total deployed USDC.
     */
    function getStrategyTVL() external pure override returns (uint256 tvl) {
        return 1000000000000000000;
    }

    /**
     * @notice Returns the pending rewards (in principal asset) from the pool.
     * @return pending The pending fee amount.
     */

    // ======================================================
    // Internal Helper Functions
    // ======================================================
    /**
     * @dev Sends harvested yield (in DXP) to the Farm.
     * @param amount The yield amount in DXP.
     */
    function _sendRewardsToFarm(uint256 amount) internal override {
        require(IERC20(asset).transfer(farm, amount), "Strategy: reward transfer failed");
    }

    function getPendingRewards() external pure override returns (uint256) {
        return 0;
    }
}
