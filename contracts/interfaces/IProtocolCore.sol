// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title IProtocolCore
 * @notice External interface for the Dexponent ProtocolCore contract.
 *         Manages core protocol operations including emissions, bonuses,
 *         revenue distribution, and governance.  Provides getter/view
 *         functions for on-chain data and state-changing functions for
 *         protocol actions.
 */
interface IProtocolCore {
    /**
     * @notice Returns the current protocol fee rate applied to revenue.
     * @dev Fee rate is expressed as an integer percentage (0 to 100).
     * @return The protocol fee rate percentage.
     */
    function getProtocolFeeRate() external view returns (uint256);


    /**
     * @notice Returns the current DXP token balance held in reserve by the protocol.
     * @dev Protocol reserves accrue from fees and can be redeemed or reallocated.
     * @return The DXP token reserve amount.
     */
    function getProtocolReserves() external view returns (uint256);

    /**
     * @notice Returns the current emission reserve for mintable DXP tokens.
     * @dev Emission reserve tracks DXP tokens set aside for distribution to farms and other incentives.
     * @return The DXP token emission reserve amount.
     */
    function getEmissionReserve() external view returns (uint256);

    /**
     * @notice Mints and issues new DXP tokens according to the emission schedule.
     * @dev Throttled to at most one call per 20 seconds to prevent rate abuse.
     *      Updates internal emission and protocol reserves accordingly.
     */
    function triggerEmission() external;

    /**
     * @notice Synchronizes the stored protocol reserve value with the actual DXP token balance.
     * @dev Ensures that internal accounting matches the on-chain token balance after transfers.
     */
    function syncProtocolReserves() external;

    /**
     * @notice Issues a deposit bonus in DXP tokens to a liquidity provider.
     * @dev Uses TWAP or fallback pricing to convert expected yield into DXP.
     *      Deducts the bonus from protocol reserves.
     * @param farmId The identifier of the farm receiving the deposit.
     * @param lp The address of the liquidity provider.
     * @param principal The amount of principal deposited by the LP.
     * @param depositMaturity The Unix timestamp at which maturity occurs.
     */
    function distributeDepositBonus(
        uint256 farmId,
        address lp,
        uint256 principal,
        uint256 depositMaturity
    ) external;

    /**
     * @notice Reverses or reclaims a previously issued deposit bonus when an LP withdraws early.
     * @dev Returned bonus tokens are queued for cooldown and then recycled back into reserves.
     * @param farmId The identifier of the farm associated with the withdrawal.
     * @param lp The address of the liquidity provider.
     * @param amountWithdrawn The principal amount being withdrawn.
     * @param isEarly True if withdrawal occurs before maturity, false otherwise.
     */
    function reverseDepositBonus(
        uint256 farmId,
        address lp,
        uint256 amountWithdrawn,
        bool isEarly
    ) external;

    /**
     * @notice Finalizes a bonus position by preventing any future reversal.
     * @dev Marks the bonus as "unpinne­d" once maturity conditions are met.
     * @param farmId The identifier of the farm.
     * @param lp The address of the liquidity provider.
     */
    function unpinPosition(uint256 farmId, address lp) external;

    /**
     * @notice Updates the stored benchmark yield rate for a farm.
     * @dev Benchmark yield is used in bonus calculations for new deposits.
     * @param farmId The identifier of the farm.
     * @param newYield The new benchmark APY expressed as an integer percentage.
     */
    function setFarmBenchmarkYield(uint256 farmId, uint256 newYield) external;

    /**
     * @notice Creates a new Farm and deploys its associated Claim token.
     * @dev Only approved farm owners may call this.  Uses CREATE2 with provided salt.
     * @param salt A user-provided 32-byte salt for deterministic deployment.
     * @param asset The ERC-20 token used as principal in the farm.
     * @param maturityPeriod The lockup period in seconds before maturity.
     * @param verifierIncentiveSplit Percentage of revenue allocated to verifiers.
     * @param yieldYodaIncentiveSplit Percentage allocated to yield yodas (optional compute providers).
     * @param lpIncentiveSplit Percentage allocated to liquidity providers.
     * @param strategy The address of the strategy contract to deploy liquidity.
     * @param claimName The human-readable name of the farm's claim token.
     * @param claimSymbol The ticker symbol for the claim token.
     * @return farmId The unique numeric identifier of the newly created farm.
     * @return farmAddr The on-chain address of the deployed Farm contract.
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
     * @notice Proposes an update to the protocol fee rate.
     * @dev Caller must satisfy any existing cooldown/voting requirements.
     * @param newFee The proposed fee rate (0 to 100).
     * @param votingPeriod Duration in seconds during which votes may be cast.
     * @return proposalId Numeric identifier of the new fee proposal.
     */
    function proposeProtocolFeeUpdate(
        uint256 newFee,
        uint256 votingPeriod
    ) external returns (uint256 proposalId);

    /**
     * @notice Casts a vote on an existing fee update proposal.
     * @param proposalId The identifier of the proposal to vote on.
     * @param support True to support the proposal, false to oppose.
     */
    function voteOnFeeUpdate(uint256 proposalId, bool support) external;

    /**
     * @notice Executes a fee update proposal if quorum and vote thresholds are met.
     * @param proposalId The identifier of the proposal.
     */
    function executeFeeUpdate(uint256 proposalId) external;

    /**
     * @notice Sends a governance update to another chain via the bridge adaptor.
     * @dev Requires msg.value to cover cross-chain gas fees.
     * @param destChainId The target chain ID for the governance message.
     * @param targetContract The contract address on the destination chain.
     * @param data ABI-encoded governance payload (e.g. parameter updates).
     */
    function sendGovernanceUpdate(
        uint256 destChainId,
        address targetContract,
        bytes calldata data
    ) external payable;

    /**
     * @notice Checks if an address is an approved verifier for a given farm.
     * @param farmId The identifier of the farm.
     * @param who The address to check.
     * @return True if the address is an active, approved verifier; false otherwise.
     */
    function isApprovedVerifier(
        uint256 farmId,
        address who
    ) external view returns (bool);

    /**
     * @notice Returns the list of approved verifier addresses for a farm.
     * @param farmId The identifier of the farm.
     * @return An array of addresses currently registered as verifiers.
     */
    function getApprovedVerifiers(
        uint256 farmId
    ) external view returns (address[] memory);

    /**
     * @notice Records the consensus result (score & benchmark) from a round in Consensus.sol.
     * @dev Called by the Consensus module after finalizing a round.
     * @param farmId The identifier of the farm.
     * @param roundId The numeric round identifier.
     * @param score The averaged score value (basis points) to record.
     * @param benchmark The averaged benchmark value (basis points) to record.
     */
    function recordConsensus(
        uint256 farmId,
        uint256 roundId,
        uint256 score,
        uint256 benchmark
    ) external;

    function getTransferFeeRate() external view returns (uint256);

    function scalePeriod(
        uint256 secondsPeriod
    ) external view returns (uint256 scaledPeriod);
}
