// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IProtocolCore
 * @notice This interface defines the external functions of ProtocolCore,
 * which manages core protocol logic including token emissions, bonus issuance,
 * revenue distribution, and governance. It allows approved farms to have their
 * deposit bonuses and reversals processed, while also exposing governance functionality.
 */
interface IProtocolCore {
    /**
     * @notice Returns the current protocol fee rate.
     * @return The fee rate as a percentage (0 to 100).
     */
    function getProtocolFeeRate() external view returns (uint256);

    /**
     * @notice Returns the current protocol reserves (in DXP tokens).
     * @return The amount of DXP tokens held as reserves.
     */
    function getProtocolReserves() external view returns (uint256);

    /**
     * @notice Returns the current emission reserve (in DXP tokens).
     * @return The amount of DXP tokens held for emissions.
     */
    function getEmissionReserve() external view returns (uint256);

    /**
     * @notice Triggers a DXP token emission.
     * Mints new DXP tokens by calling the DXP token contract, updates the protocol
     * and emission reserves, and emits relevant events. The call is throttled to occur
     * at most every 20 seconds.
     */
    function triggerEmission() external;

    /**
     * @notice Synchronizes the protocol reserves with the current DXP token balance.
     * This function updates the internal protocolReserves variable to match the
     * actual DXP balance held by the protocol contract.
     */
    function syncProtocolReserves() external;

    /**
     * @notice Distributes a deposit bonus to a liquidity provider (LP).
     * The LP receives bonus DXP tokens based on their deposit amount and the expected yield.
     * Pricing data (via a TWAP) is used to convert expected yield (in principal) to DXP.
     * A fallback price is used if the pricing data is unavailable.
     * The bonus is deducted from the protocol reserves.
     *
     * @param farmId The identifier for the farm.
     * @param lp The address of the liquidity provider.
     * @param principal The principal deposit amount.
     * @param depositMaturity The desired maturity timestamp for the deposit.
     */
    function distributeDepositBonus(
        uint256 farmId,
        address lp,
        uint256 principal,
        uint256 depositMaturity
    ) external;

    /**
     * @notice Reverses an issued deposit bonus for an LP that withdraws early.
     * The LP returns the bonus DXP tokens, which are then queued for cooldown and recycled.
     *
     * @param farmId The identifier for the farm.
     * @param lp The address of the liquidity provider.
     * @param amountWithdrawn The principal amount being withdrawn.
     * @param isEarly A boolean indicating if the withdrawal is early.
     */
    function reverseDepositBonus(
        uint256 farmId,
        address lp,
        uint256 amountWithdrawn,
        bool isEarly
    ) external;

    /**
     * @notice Unpins a bonus for an LP without reversing it.
     * This function finalizes a bonus (i.e. prevents later reversal) once conditions are met.
     *
     * @param farmId The identifier for the farm.
     * @param lp The address of the liquidity provider.
     */
    function unpinPosition(uint256 farmId, address lp) external;

    /**
     * @notice Sets or updates the benchmark yield for a specific farm.
     * Benchmark yield is used as part of the bonus calculation for deposits.
     *
     * @param farmId The identifier for the farm.
     * @param newYield The new annual benchmark yield percentage.
     */
    function setFarmBenchmarkYield(uint256 farmId, uint256 newYield) external;

    /**
     * @notice Creates a new approved farm.
     * Only addresses that have been approved as farm owners can call this function.
     * A new claim token is deployed for the farm, and the farm is created via the FarmFactory.
     *
     * @param salt A user-supplied salt for CREATE2 deployment.
     * @param asset The principal asset for the farm.
     * @param maturityPeriod The deposit maturity period (in seconds).
     * @param verifierIncentiveSplit Percentage share for verifiers.
     * @param yieldYodaIncentiveSplit Percentage share for yield yodas.
     * @param lpIncentiveSplit Percentage share for liquidity providers.
     * @param strategy The strategy contract address used to deploy liquidity.
     * @param claimName The name for the claim token.
     * @param claimSymbol The symbol for the claim token.
     * @return farmId The unique identifier for the new farm.
     * @return farmAddr The deployed Farm contract address.
     */
    function createApprovedFarm(
        bytes32 salt,
        address asset,
        uint256 maturityPeriod,
        uint256 verifierIncentiveSplit,
        uint256 yieldYodaIncentiveSplit,
        uint256 lpIncentiveSplit,
        address strategy,
        string calldata claimName,
        string calldata claimSymbol
    ) external returns (uint256 farmId, address farmAddr);

    /**
     * @notice Proposes a new protocol fee update.
     * Only protocol participants that satisfy the cooling period requirement can propose fee updates.
     *
     * @param newFee The proposed new fee rate (as a percentage).
     * @param votingPeriod The duration in seconds for which the proposal remains open for voting.
     * @return proposalId The unique identifier for the fee update proposal.
     */
    function proposeProtocolFeeUpdate(uint256 newFee, uint256 votingPeriod)
        external
        returns (uint256 proposalId);

    /**
     * @notice Casts a vote for or against a protocol fee update proposal.
     *
     * @param proposalId The unique identifier for the proposal.
     * @param support A boolean indicating whether the vote is in support (true) or against (false).
     */
    function voteOnFeeUpdate(uint256 proposalId, bool support) external;

    /**
     * @notice Executes a fee update proposal if the required voting conditions are met.
     *
     * @param proposalId The unique identifier for the proposal.
     */
    function executeFeeUpdate(uint256 proposalId) external;

    /**
     * @notice Sends a governance update message via the cross-chain bridging adaptor.
     * This can be used to propagate governance decisions to contracts on other chains.
     *
     * @param destChainId The destination chain ID.
     * @param targetContract The target contract address on the destination chain.
     * @param data The encoded update message.
     */
    function sendGovernanceUpdate(
        uint256 destChainId,
        address targetContract,
        bytes calldata data
    ) external payable;
}
