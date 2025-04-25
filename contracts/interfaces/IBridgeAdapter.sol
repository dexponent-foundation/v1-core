// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

/**
 * @title IBridgeAdapter
 * @notice Interface for the Dexponent Bridging Adapter.
 * This abstracts cross-chain token bridging and optional cross-chain message passing.
 * Should be implemented by a contract that supports multiple bridge providers (e.g. Across, Axelar, Connext).
 */
interface IBridgeAdapter {
    /// @notice Enum of supported bridge providers.
    enum BridgeProvider {
        None,
        Across,
        Axelar,
        Connext
    }

    /// @notice Emitted when a token bridge is initiated.
    event TokenBridgeInitiated(
        address indexed user,
        uint256 indexed originChain,
        uint256 indexed destinationChain,
        address token,
        uint256 amount,
        BridgeProvider bridgeUsed,
        bytes32 bridgeTxId
    );

    /// @notice Emitted when a cross-chain message is sent.
    event CrossChainMessageSent(
        address indexed sender,
        uint256 indexed destinationChain,
        address indexed targetContract,
        bytes32 messageId
    );

    /**
     * @notice Initiates a deposit from the current chain to another chain into Dexponent.
     * @param token The token to bridge (use address(0) for native).
     * @param amount The amount to bridge.
     * @param destinationChainId Destination EVM chain ID.
     * @param recipient Address that will receive the funds on the destination chain.
     * @param outputAmount Expected output amount (Across only).
     * @param quoteTimestamp Fee quote timestamp (Across only).
     * @param fillDeadline Deadline for relayer to fill the transfer (Across only).
     * @param exclusiveRelayer Optional relayer to fill (Across only).
     * @param exclusivityDeadline Deadline for exclusive relayer (Across only).
     */
    function depositToChain(
        address token,
        uint256 amount,
        uint256 destinationChainId,
        address recipient,
        uint256 outputAmount,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        address exclusiveRelayer,
        uint32 exclusivityDeadline
    ) external payable;

    /**
     * @notice Initiates a withdrawal to a user from the core chain (Base) to another chain.
     * @param token The token to bridge (use address(0) for native).
     * @param amount The amount to bridge.
     * @param destinationChainId Destination EVM chain ID.
     * @param userRecipient User’s address to receive funds on destination chain.
     * @param outputAmount Expected output amount (Across only).
     * @param quoteTimestamp Fee quote timestamp (Across only).
     * @param fillDeadline Deadline for relayer to fill (Across only).
     * @param exclusiveRelayer Optional relayer to fill (Across only).
     * @param exclusivityDeadline Deadline for exclusive relayer (Across only).
     */
    function withdrawToUser(
        address token,
        uint256 amount,
        uint256 destinationChainId,
        address userRecipient,
        uint256 outputAmount,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        address exclusiveRelayer,
        uint32 exclusivityDeadline
    ) external payable;

    /**
     * @notice Sends a cross-chain message (no token transfer) for governance/state sync.
     * @dev Use with caution. Only callable by authorized contracts.
     * @param destinationChainId Chain ID of the target chain.
     * @param targetContract Address on the destination chain to call.
     * @param messageData Encoded calldata for the target contract.
     * @param provider The bridge provider to use for message delivery.
     */
    function sendMessageToChain(
        uint256 destinationChainId,
        address targetContract,
        bytes calldata messageData,
        BridgeProvider provider
    ) external payable;
}
