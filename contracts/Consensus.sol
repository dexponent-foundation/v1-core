// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "./interfaces/IProtocolCore.sol";

/**
 * @title Consensus Module for Dexponent
 * @notice Manages ephemeral consensus rounds: collects verifier submissions
 *         of both score and benchmark, computes averages, and reports back
 *         to the central ProtocolCore.
 */
contract Consensus is Ownable {
    /// @notice Reference to the central ProtocolCore registry
    IProtocolCore public protocolCore;

    /// @notice Minimum number of submissions required to finalize a round
    uint256 public minQuorum;

    /// @notice Emitted when a new consensus round is started for a farm
    event RoundStarted(
        uint256 indexed farmId,
        uint256 indexed roundId,
        uint256 startBlock
    );

    /// @notice Emitted when a verifier submits both score and benchmark
    event SubmissionReceived(
        uint256 indexed farmId,
        uint256 indexed roundId,
        address indexed verifier,
        uint256 score,
        uint256 benchmark
    );

    /// @notice Emitted when a round is finalized
    event RoundFinalized(
        uint256 indexed farmId,
        uint256 indexed roundId,
        uint256 consensusScore,
        uint256 consensusBenchmark
    );

    struct Round {
        uint256 id;
        uint256 startBlock;
        bool finalized;
    }

    struct Submission {
        uint256 score;
        uint256 benchmark;
        bool exists;
    }

    // farmId => current Round
    mapping(uint256 => Round) public rounds;
    // farmId => roundId => verifier => submission
    mapping(uint256 => mapping(uint256 => mapping(address => Submission)))
        public submissions;

    /**
     * @param _protocolCore Address of the ProtocolCore contract
     * @param _minQuorum    Minimum number of submissions to finalize
     */
    constructor(address _protocolCore, uint256 _minQuorum) Ownable(msg.sender) {
        require(_protocolCore != address(0), "Invalid core address");
        require(_minQuorum > 0, "Quorum > 0");
        protocolCore = IProtocolCore(_protocolCore);
        minQuorum = _minQuorum;
    }

    /**
     * @notice Update the ProtocolCore reference
     */
    function setProtocolCore(address _core) external onlyOwner {
        require(_core != address(0), "Invalid core");
        protocolCore = IProtocolCore(_core);
    }

    /**
     * @notice Set the minimum quorum for round finalization
     */
    function setMinQuorum(uint256 _minQuorum) external onlyOwner {
        require(_minQuorum > 0, "Quorum > 0");
        minQuorum = _minQuorum;
    }

    /**
     * @notice Starts a new consensus round for a given farm
     * @param farmId Identifier of the farm
     */
    function startRound(uint256 farmId) external onlyOwner {
        Round storage rnd = rounds[farmId];
        require(rnd.finalized || rnd.id == 0, "Round active");

        rnd.id++;
        rnd.startBlock = block.number;
        rnd.finalized = false;

        emit RoundStarted(farmId, rnd.id, rnd.startBlock);
    }

    /**
     * @notice Submit both score and benchmark for the active round
     * @param farmId    Identifier of the farm
     * @param score     Reported performance metric (e.g., yield in basis points)
     * @param benchmark Reported benchmark metric (e.g., protocol benchmark in basis points)
     */
    function submit(uint256 farmId, uint256 score, uint256 benchmark) external {
        Round storage rnd = rounds[farmId];
        require(rnd.id > 0 && !rnd.finalized, "No active round");
        require(
            score <= 10000 && benchmark <= 10000,
            "Values >100% not allowed"
        );

        // Verify caller is approved in ProtocolCore
        require(
            protocolCore.isApprovedVerifier(farmId, msg.sender),
            "Not approved verifier"
        );

        Submission storage sub = submissions[farmId][rnd.id][msg.sender];
        require(!sub.exists, "Already submitted");

        sub.score = score;
        sub.benchmark = benchmark;
        sub.exists = true;

        emit SubmissionReceived(farmId, rnd.id, msg.sender, score, benchmark);
    }

    /**
     * @notice Finalizes the active round, computes average score & benchmark,
     *         and reports back to ProtocolCore
     * @param farmId Identifier of the farm
     */
    function finalizeRound(uint256 farmId) external onlyOwner {
        Round storage rnd = rounds[farmId];
        require(rnd.id > 0 && !rnd.finalized, "No active round");

        // Fetch verifiers list from ProtocolCore
        address[] memory verifiers = protocolCore.getApprovedVerifiers(farmId);
        uint256 totalScore;
        uint256 totalBenchmark;
        uint256 count;

        for (uint256 i = 0; i < verifiers.length; i++) {
            Submission storage sub = submissions[farmId][rnd.id][verifiers[i]];
            if (sub.exists) {
                totalScore += sub.score;
                totalBenchmark += sub.benchmark;
                count++;
            }
        }

        require(count >= minQuorum, "Quorum not met");

        uint256 consensusScore = totalScore / count;
        uint256 consensusBenchmark = totalBenchmark / count;
        rnd.finalized = true;

        // Record results in ProtocolCore
        protocolCore.recordConsensus(
            farmId,
            rnd.id,
            consensusScore,
            consensusBenchmark
        );

        emit RoundFinalized(farmId, rnd.id, consensusScore, consensusBenchmark);
    }
}
