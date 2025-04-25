// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/Strings.sol";
import "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title BridgingAdapter
 * @notice This contract abstracts cross-chain bridging operations for the Dexponent Protocol.
 * It supports bridging ERC20 tokens (and native tokens via wrapping) using Across (default),
 * with fallbacks to Axelar or Connext (via LI.FI) if Across is unavailable for a given token/route.
 * It also supports cross-chain message passing via Axelar or Connext for restricted use (e.g., governance or state sync).
 *
 * Design:
 * - Standalone contract to be called by Dexponent’s protocol contracts on any chain.
 * - Maintains configurable routes (token -> dest chain -> bridge provider).
 * - Owner (governance) can enable/disable tokens, set routes and external bridge addresses.
 * - Uses on-chain logic to choose bridges, minimizing off-chain orchestration.
 * - Separate functions for token bridging vs. message passing to reduce attack surface.
 *
 * Security:
 * - Only owner or authorized contracts can call `withdrawToUser` and messaging functions.
 * - Users (or Dexponent contracts) must approve tokens to this contract before bridging.
 * - Emits events with relevant details (user, origin, dest, tx id) for off-chain relayers.
 * - Follows best practices for safety (e.g., using SafeERC20, clearing approvals).
 */
contract BridgingAdapter is Ownable {
    using SafeERC20 for IERC20;

    // Enum to represent bridging providers
    enum BridgeProvider { None, Across, Axelar, Connext /* via LI.FI aggregator if configured */ }

    // External bridge contract addresses (configurable by owner)
    address public acrossSpokePool;     // Across SpokePool on this chain (for depositV3 calls)
    address public axelarGateway;       // Axelar Gateway contract on this chain
    address public axelarGasService;    // Axelar Gas Service contract (for paying gas fees on dest chain)
    address public connext;             // Connext contract on this chain (for xcall)
    address public lifiDiamond;         // (Optional) LI.FI Diamond contract if using aggregator (not directly used in this implementation)
    address public wrappedNativeToken;  // Wrapped native token (WETH, WMATIC, etc.) on this chain for handling native token bridging

    // Mappings for token bridging configuration
    // token => (destinationChainId => preferred BridgeProvider)
    mapping(address => mapping(uint256 => BridgeProvider)) public bridgeRoute;
    // Tokens allowed for bridging (must be true to bridge, except native token represented by address(0))
    mapping(address => bool) public tokenAllowed;
    // Mapping from token to its Axelar token symbol (needed for Axelar sendToken)
    mapping(address => string) public axelarTokenSymbol;
    // Mapping from chainId to Axelar chain name string (e.g., 1 -> "ethereum")
    mapping(uint256 => string) public axelarChainName;
    // Mapping from chainId to Connext domain ID (needed for Connext xcall)
    mapping(uint256 => uint32) public connextDomainId;
    // Addresses allowed to call restricted functions (e.g., Dexponent core for withdraws or governance)
    mapping(address => bool) public allowedCaller;

    // Events for monitoring cross-chain actions
    event TokenBridgeInitiated(
        address indexed user,
        uint256 indexed originChain,
        uint256 indexed destinationChain,
        address token,
        uint256 amount,
        BridgeProvider bridgeUsed,
        bytes32 bridgeTxId
    );
    event CrossChainMessageSent(
        address indexed sender,
        uint256 indexed destinationChain,
        address indexed targetContract,
        bytes32 messageId
    );
    event BridgeRouteSet(address token, uint256 destinationChain, BridgeProvider provider);
    event TokenAllowed(address token, bool allowed);
    event ExternalAddressesUpdated(
        address acrossSpokePool,
        address axelarGateway,
        address axelarGasService,
        address connext,
        address lifiDiamond,
        address wrappedNativeToken
    );

    // Custom errors for common failure cases
    error TokenNotAllowed(address token);
    error RouteNotConfigured(address token, uint256 destChain);
    error UnsupportedBridgeProvider(BridgeProvider provider);
    error UnauthorizedCaller(address caller);

    /**
     * @dev Constructor to initialize the adapter with the relevant bridge contract addresses.
     * @param initialOwner Address to set as the owner (governance) of this contract.
     * @param _acrossSpokePool Across SpokePool address on this chain.
     * @param _axelarGateway Axelar Gateway contract address on this chain.
     * @param _axelarGasService Axelar Gas Service contract address.
     * @param _connext Connext contract address on this chain.
     * @param _lifiDiamond LiFi Diamond contract address (if using LiFi aggregator for Connext; can be address(0) if not used).
     * @param _wrappedNativeToken Wrapped native token (e.g., WETH) address on this chain.
     */
    constructor(
        address initialOwner,
        address _acrossSpokePool,
        address _axelarGateway,
        address _axelarGasService,
        address _connext,
        address _lifiDiamond,
        address _wrappedNativeToken
    ) Ownable(initialOwner) {
        acrossSpokePool = _acrossSpokePool;
        axelarGateway = _axelarGateway;
        axelarGasService = _axelarGasService;
        connext = _connext;
        lifiDiamond = _lifiDiamond;
        wrappedNativeToken = _wrappedNativeToken;
        // Note: tokenAllowed and bridgeRoute mappings should be configured via owner functions after deployment.
    }

    // ============ Owner Config Functions ============

    /**
     * @notice Set the bridging route (preferred bridge provider) for a given token and destination chain.
     * @param token Token address on this chain.
     * @param destChainId Destination chain ID.
     * @param provider Bridge provider to use (1 = Across, 2 = Axelar, 3 = Connext).
     */
    function setBridgeRoute(address token, uint256 destChainId, BridgeProvider provider) external onlyOwner {
        bridgeRoute[token][destChainId] = provider;
        emit BridgeRouteSet(token, destChainId, provider);
    }

    /**
     * @notice Enable or disable a token for bridging.
     * @param token Token address to update.
     * @param allowed True to allow bridging this token, false to disable.
     */
    function setTokenAllowed(address token, bool allowed) external onlyOwner {
        tokenAllowed[token] = allowed;
        emit TokenAllowed(token, allowed);
    }

    /**
     * @notice Update external bridge contract addresses (Across, Axelar, Connext, LiFi, wrapped native token).
     */
    function setExternalAddresses(
        address _acrossSpokePool,
        address _axelarGateway,
        address _axelarGasService,
        address _connext,
        address _lifiDiamond,
        address _wrappedNativeToken
    ) external onlyOwner {
        acrossSpokePool = _acrossSpokePool;
        axelarGateway = _axelarGateway;
        axelarGasService = _axelarGasService;
        connext = _connext;
        lifiDiamond = _lifiDiamond;
        wrappedNativeToken = _wrappedNativeToken;
        emit ExternalAddressesUpdated(_acrossSpokePool, _axelarGateway, _axelarGasService, _connext, _lifiDiamond, _wrappedNativeToken);
    }

    /**
     * @notice Set the Axelar token symbol for a given token address (for Axelar bridging).
     * @param token Token address on this chain.
     * @param symbol The token symbol as recognized by Axelar (e.g., "axlUSDC", "axlWETH").
     */
    function setAxelarTokenSymbol(address token, string calldata symbol) external onlyOwner {
        axelarTokenSymbol[token] = symbol;
    }

    /**
     * @notice Set the Axelar chain name for a given chain ID (e.g., 1 -> "ethereum").
     * @param chainId EVM chain ID.
     * @param name Axelar chain name string.
     */
    function setAxelarChainName(uint256 chainId, string calldata name) external onlyOwner {
        axelarChainName[chainId] = name;
    }

    /**
     * @notice Set the Connext domain ID for a given chain ID.
     * @param chainId EVM chain ID.
     * @param domainId Connext domain ID corresponding to that chain.
     */
    function setConnextDomainId(uint256 chainId, uint32 domainId) external onlyOwner {
        connextDomainId[chainId] = domainId;
    }

    /**
     * @notice Authorize or revoke an allowed caller (e.g., Dexponent core contract) for restricted functions.
     * @param caller Address to update.
     * @param allowed True to authorize, false to revoke.
     */
    function setAllowedCaller(address caller, bool allowed) external onlyOwner {
        allowedCaller[caller] = allowed;
    }

    // ============ Cross-Chain Bridging Functions ============

    /**
     * @notice Bridge tokens from this chain to another chain as a deposit into Dexponent's protocol.
     * @dev Users or Dexponent contracts on peripheral chains will call this to deposit assets to the core chain (Base).
     * Uses Across by default (if configured), otherwise falls back to Axelar or Connext based on `bridgeRoute`.
     * @param token Token to bridge (address(0) for native token like ETH).
     * @param amount Amount of tokens to bridge.
     * @param destinationChainId Chain ID of the destination chain.
     * @param recipient Recipient address on the destination chain (e.g., Dexponent core contract on Base for deposits).
     * @param outputAmount (Across only) Expected output amount after fees (usually amount minus relayer fee).
     * @param quoteTimestamp (Across only) Timestamp of the fee quote used.
     * @param fillDeadline (Across only) Deadline for a relayer to fill this deposit.
     * @param exclusiveRelayer (Across only) Address of exclusive relayer (or address(0) if not used).
     * @param exclusivityDeadline (Across only) Deadline for exclusive relayer (or 0 if none).
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
    ) external payable {
        // Initiate bridging from msg.sender (could be user EOA or a Dexponent contract on source chain)
        _bridgeTokens(msg.sender, token, amount, destinationChainId, recipient, outputAmount, quoteTimestamp, fillDeadline, exclusiveRelayer, exclusivityDeadline);
    }

    /**
     * @notice Bridge tokens from the core chain (Base) to a user on another chain as a withdrawal.
     * @dev Dexponent's core (Base) contract will call this to send assets to user on their origin chain.
     * Restricted to owner or allowedCaller (Dexponent core) to prevent unauthorized use.
     * @param token Token to bridge (address(0) for native).
     * @param amount Amount to bridge.
     * @param destinationChainId Chain ID of the user's destination chain.
     * @param userRecipient User's address on the destination chain to receive the tokens.
     * @param outputAmount (Across only) Expected output amount after fees.
     * @param quoteTimestamp (Across only) Fee quote timestamp.
     * @param fillDeadline (Across only) Relayer fill deadline.
     * @param exclusiveRelayer (Across only) Exclusive relayer address (or 0).
     * @param exclusivityDeadline (Across only) Exclusive relayer deadline.
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
    ) external payable {
        // Only Dexponent core (allowedCaller) or owner can initiate user withdrawals
        if (!allowedCaller[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedCaller(msg.sender);
        }
        // Initiate bridging from msg.sender (Dexponent core) on behalf of the user
        _bridgeTokens(msg.sender, token, amount, destinationChainId, userRecipient, outputAmount, quoteTimestamp, fillDeadline, exclusiveRelayer, exclusivityDeadline);
    }

    /**
     * @notice Send a cross-chain message (without token transfer) to a contract on another chain.
     * @dev Used for governance or state synchronization. Only callable by owner or allowedCaller for safety.
     * Axelar is used for message passing by default; Connext (xcall without tokens) can be integrated if needed.
     * @param destinationChainId Chain ID of the target chain.
     * @param targetContract Address of the contract on the destination chain to call.
     * @param messageData Encoded data payload to send.
     * @param provider Messaging provider to use (2 = Axelar, 3 = Connext).
     */
    function sendMessageToChain(
        uint256 destinationChainId,
        address targetContract,
        bytes calldata messageData,
        BridgeProvider provider
    ) external payable {
        if (!allowedCaller[msg.sender] && msg.sender != owner()) {
            revert UnauthorizedCaller(msg.sender);
        }
        if (provider == BridgeProvider.Axelar) {
            // Axelar General Message Passing (GMP) for cross-chain call
            require(axelarGateway != address(0) && axelarGasService != address(0), "Axelar not configured");
            string memory destChain = axelarChainName[destinationChainId];
            require(bytes(destChain).length != 0, "Axelar dest name not set");
            string memory destAddress = _addressToString(targetContract);
            // Pay gas for Axelar message execution on destination chain, if native fee provided
            if (msg.value > 0) {
                // Use Axelar Gas Service to pay gas on destination&#8203;:contentReference[oaicite:0]{index=0}
                (bool success, ) = axelarGasService.call{value: msg.value}(
                    abi.encodeWithSignature(
                        "payNativeGasForContractCall(address,string,string,bytes,address)",
                        address(this),
                        destChain,
                        destAddress,
                        messageData,
                        msg.sender  // refund any leftover gas to the caller
                    )
                );
                require(success, "Axelar gas payment failed");
            }
            // Invoke Axelar Gateway to send the cross-chain call&#8203;:contentReference[oaicite:1]{index=1}
            (bool success2, ) = axelarGateway.call(
                abi.encodeWithSignature(
                    "callContract(string,string,bytes)",
                    destChain,
                    destAddress,
                    messageData
                )
            );
            require(success2, "Axelar callContract failed");
            // Axelar will emit an event with a message ID; we emit our event with a placeholder (0) since we cannot get it synchronously
            emit CrossChainMessageSent(msg.sender, destinationChainId, targetContract, bytes32(0));
        } else if (provider == BridgeProvider.Connext) {
            // Connext xcall can also be used for message passing (not implemented here for security reasons)
            require(connext != address(0), "Connext not configured");
            uint32 domain = connextDomainId[destinationChainId];
            require(domain != 0, "Connext domain not set");
            // We do not support arbitrary cross-chain calls via Connext in this adapter to minimize surface area
            revert("Connext message not supported in adapter");
        } else {
            revert UnsupportedBridgeProvider(provider);
        }
    }

    // ============ Internal Functions ============

    /**
     * @dev Internal function to execute the bridging logic. 
     * Based on the configured BridgeProvider, it will route the token transfer through Across, Axelar, or Connext.
     * This function assumes the caller (user or Dexponent core) has already approved this contract for the tokens.
     * @param sender Address of the entity providing tokens (user for deposit, Dexponent core for withdrawal).
     * @param token Token to bridge (address(0) if native).
     * @param amount Amount to bridge.
     * @param destinationChainId Destination chain ID.
     * @param recipient Address on destination chain to receive the tokens.
     * @param outputAmount Across-specific parameter for output amount after fees.
     * @param quoteTimestamp Across-specific fee quote timestamp.
     * @param fillDeadline Across-specific fill deadline.
     * @param exclusiveRelayer Across-specific exclusive relayer address.
     * @param exclusivityDeadline Across-specific exclusivity deadline.
     */
    function _bridgeTokens(
        address sender,
        address token,
        uint256 amount,
        uint256 destinationChainId,
        address recipient,
        uint256 outputAmount,
        uint32 quoteTimestamp,
        uint32 fillDeadline,
        address exclusiveRelayer,
        uint32 exclusivityDeadline
    ) internal {
        if (!tokenAllowed[token] && token != address(0)) {
            // Only proceed if token is explicitly allowed (address(0) for native is handled separately)
            revert TokenNotAllowed(token);
        }
        if (amount == 0) {
            revert("Amount cannot be zero");
        }

        // Determine which bridge provider to use for this token and destination
        BridgeProvider provider = bridgeRoute[token][destinationChainId];
        if (provider == BridgeProvider.None) {
            revert RouteNotConfigured(token, destinationChainId);
        }

        // Handle native token bridging by wrapping it to ERC20
        bool isNative = (token == address(0));
        if (isNative) {
            // Ensure the caller sent enough native currency to cover the amount
            require(msg.value >= amount, "Insufficient native token");
            require(wrappedNativeToken != address(0), "Wrapped native token not set");
            // Wrap native token (e.g., deposit ETH to WETH)
            (bool success, ) = wrappedNativeToken.call{value: amount}(
                abi.encodeWithSignature("deposit()")
            );
            require(success, "Wrap native token failed");
            token = wrappedNativeToken;
        } else {
            // If bridging an ERC20 token, no native value should be attached (except Connext relayer fee which uses msg.value)
            require(msg.value == 0 || provider == BridgeProvider.Connext, "Unexpected native value");
        }

        // Transfer tokens from sender to this contract (sender must have approved this contract)
        if (!isNative) {
            IERC20(token).safeTransferFrom(sender, address(this), amount);
        }

        // Execute bridging via the chosen provider
        bytes32 bridgeTxId;
        if (provider == BridgeProvider.Across) {
            require(acrossSpokePool != address(0), "Across not configured");
            // Approve Across SpokePool to pull the tokens
            // Increase allowance
            IERC20(token).safeIncreaseAllowance(acrossSpokePool, amount);   
            // Call Across SpokePool's depositV3 function&#8203;:contentReference[oaicite:2]{index=2}
            // Note: depositor is set to this contract (since it now holds the tokens), recipient is the destination address.
            (bool ok, ) = acrossSpokePool.call(
                abi.encodeWithSignature(
                    "depositV3(address,address,address,address,uint256,uint256,uint256,address,uint32,uint32,uint32,bytes)",
                    address(this),            // depositor: BridgingAdapter (tokens are from this contract)&#8203;:contentReference[oaicite:3]{index=3}
                    recipient,                // recipient on destination chain
                    token,                    // inputToken
                    address(0),               // outputToken: address(0) to auto-resolve to same token on dest&#8203;:contentReference[oaicite:4]{index=4}
                    amount,
                    outputAmount,
                    destinationChainId,
                    exclusiveRelayer,
                    quoteTimestamp,
                    fillDeadline,
                    exclusivityDeadline,
                    bytes("")                 // message: empty (no cross-chain contract call attached)
                )
            );
            require(ok, "Across depositV3 failed");
            // Clear approval for safety
            IERC20(token).forceApprove(acrossSpokePool, 0);
            
            // Across will emit events for the deposit; we emit our own event below with bridgeTxId as 0 (could use an internal ID if needed)
            bridgeTxId = bytes32(0);
        } else if (provider == BridgeProvider.Axelar) {
            require(axelarGateway != address(0), "Axelar not configured");
            string memory destChain = axelarChainName[destinationChainId];
            require(bytes(destChain).length != 0, "Axelar dest chain name not set");
            string memory symbol = axelarTokenSymbol[token];
            require(bytes(symbol).length != 0, "Axelar token symbol not set");
            // Approve Axelar Gateway to pull tokens for minting on dest chain
            IERC20(token).safeIncreaseAllowance(axelarGateway, amount);
            // Call Axelar Gateway's sendToken function&#8203;:contentReference[oaicite:5]{index=5}
            (bool ok2, ) = axelarGateway.call(
                abi.encodeWithSignature(
                    "sendToken(string,string,string,uint256)",
                    destChain,
                    Strings.toHexString(uint160(recipient), 20),  // destination address in string (hex)
                    symbol,
                    amount
                )
            );
            require(ok2, "Axelar sendToken failed");
            // Clear approval
            IERC20(token).forceApprove(axelarGateway, 0);
            // Axelar sendToken will handle minting on dest. We set bridgeTxId to 0 (Axelar transaction ID can be obtained from Axelar events off-chain).
            bridgeTxId = bytes32(0);
        } else if (provider == BridgeProvider.Connext) {
            require(connext != address(0), "Connext not configured");
            uint32 destDomain = connextDomainId[destinationChainId];
            require(destDomain != 0, "Connext domain not set");
            // Approve Connext contract to pull tokens for bridging
            // Increase allowance
            IERC20(token).safeIncreaseAllowance(connext, amount);
            uint256 relayerFee = msg.value;  // any native value sent is used as Connext relayer fee
            // Call Connext xcall to bridge tokens to the recipient on dest chain&#8203;:contentReference[oaicite:6]{index=6}
            // _destination = destDomain, _to = recipient (dest), _asset = token, _delegate = sender, _amount = amount,
            // _slippage = 10000 (100% in BPS to allow max slippage)&#8203;:contentReference[oaicite:7]{index=7}, _callData = "" (no payload, just transfer)
            (bool ok3, bytes memory returnData) = connext.call{value: relayerFee}(
                abi.encodeWithSignature(
                    "xcall(uint32,address,address,address,uint256,uint256,bytes)",
                    destDomain,
                    recipient,
                    token,
                    sender,       // _delegate: allow sender (user or Dexponent core) to cancel/receive fallback if needed&#8203;:contentReference[oaicite:8]{index=8}
                    amount,
                    10000,        // _slippage: 100% tolerance (in BPS)&#8203;:contentReference[oaicite:9]{index=9}
                    bytes("")     // no additional call on destination (pure token bridge)
                )
            );
            require(ok3, "Connext xcall failed");
            // xcall returns a transfer ID (bytes32) which we can capture from returnData
            if (returnData.length >= 32) {
                bridgeTxId = abi.decode(returnData, (bytes32));
            } else {
                bridgeTxId = bytes32(0);
            }
            // Clear approval
            IERC20(token).forceApprove(connext, 0);
            // Note: Alternatively, one could integrate LiFi by calling the LiFi Diamond contract with appropriate data for Connext.
        } else {
            // Should not happen due to earlier checks
            revert UnsupportedBridgeProvider(provider);
        }

        // Emit event with all details. originChain = current chain (block.chainid), destChain = destinationChainId.
        emit TokenBridgeInitiated(sender, block.chainid, destinationChainId, token, amount, provider, bridgeTxId);
    }

    /**
     * @dev Helper to convert an address to a hex string (0x... format) for Axelar.
     */
    function _addressToString(address _addr) internal pure returns (string memory) {
        return Strings.toHexString(uint160(_addr), 20);
    }

    // Receive function to accept native token (e.g., to receive refunds or Connext relayer fees)
    receive() external payable {}
}
