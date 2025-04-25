// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title MockBridgeAdapter
 * @notice A minimal, no-op implementation to simulate bridging for Dexponent Protocol on testnet.
 *         - Provides depositToChain, withdrawToUser, sendMessageToChain, etc., 
 *           but doesn't call real bridging providers.
 *         - Always returns success or emits events so Dexponent doesn't revert.
 */
contract MockBridgeAdapter is Ownable {
    // Example event to show deposit
    event MockDepositToChain(
        address indexed token,
        uint256 amount,
        uint256 destinationChainId,
        address recipient
    );
    // Example event to show withdraw
    event MockWithdrawToUser(
        address indexed token,
        uint256 amount,
        uint256 destinationChainId,
        address userRecipient
    );
    // Example event for message passing
    event MockMessageSent(
        uint256 indexed destinationChainId,
        address indexed targetContract,
        bytes messageData
    );

    constructor() Ownable(msg.sender) {
        // optionally set config
    }

    /**
     * @notice depositToChain stub. Just emits an event, no bridging logic.
     */
    function depositToChain(
        address token,
        uint256 amount,
        uint256 destinationChainId,
        address recipient,
        uint256 /*outputAmount*/,
        uint32 /*quoteTimestamp*/,
        uint32 /*fillDeadline*/,
        address /*exclusiveRelayer*/,
        uint32 /*exclusivityDeadline*/
    ) external payable {
        // In a real bridging call, you'd do token transfer logic + call Across/Axelar
        // Here we just emit an event
        emit MockDepositToChain(token, amount, destinationChainId, recipient);
    }

    /**
     * @notice withdrawToUser stub. 
     */
    function withdrawToUser(
        address token,
        uint256 amount,
        uint256 destinationChainId,
        address userRecipient,
        uint256 /*outputAmount*/,
        uint32 /*quoteTimestamp*/,
        uint32 /*fillDeadline*/,
        address /*exclusiveRelayer*/,
        uint32 /*exclusivityDeadline*/
    ) external payable onlyOwner {
        // or require(msg.sender == allowedDexponentContract), up to you
        emit MockWithdrawToUser(token, amount, destinationChainId, userRecipient);
    }

    /**
     * @notice sendMessageToChain stub. 
     */
    function sendMessageToChain(
        uint256 destinationChainId,
        address targetContract,
        bytes calldata messageData,
        uint8 /*bridgeProvider*/
    ) external payable onlyOwner {
        // or require(allowedCaller[msg.sender]) if you want restricted access
        emit MockMessageSent(destinationChainId, targetContract, messageData);
    }

    // Optionally add setBridgeRoute, setTokenAllowed, etc. as no-ops 
    // if Dexponent calls them. Or omit them if Dexponent doesn't rely on them.
}
