// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title ProtocolCore
 * @notice Central contract for protocol core logic. This contract handles:
 *         - Emission of DXP tokens.
 *         - Calculation and distribution (or reversal) of deposit bonuses for liquidity providers.
 *         - Pulling and distributing yield revenue from individual farms.
 *         - Management of protocol fees and reserves.
 *         - Integration with external modules: FarmFactory for creating farms, LiquidityManager for token swaps,
 *           and a bridging adaptor for cross-chain messaging.
 * @dev This contract maintains a registry of farms (including the RootFarm) created via the protocol.
 *      Only farms created by this protocol can invoke bonus or revenue functions. Governance functions are
 *      stubbed and can be implemented later.
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./libraries/BonusCalculationLib.sol";
import "./ClaimToken.sol";
import "./interfaces/IDXPToken.sol";
import "./vDXPToken.sol";
import "./interfaces/IRootFarm.sol";
import "./interfaces/IFarmFactory.sol";
import "./interfaces/ILiquidityManager.sol";
import "./interfaces/IBridgeAdapter.sol";

contract ProtocolCore is Ownable, ReentrancyGuard {
    // ============================================================================
    // Constants and Data Structures
    // ============================================================================

    /// @notice The cooldown period for bonus tokens returned by LPs before being recycled.
    uint256 public constant COOLDOWN_PERIOD = 1 days;

    /// @notice Structure storing details for each deployed farm.
    struct FarmDetails {
        address farmAddress;  // Address of the deployed Farm contract.
        address owner;        // The approved farm owner's address.
        address asset;        // The underlying principal asset of the farm.
        uint256 farmId;       // Unique farm identifier.
    }

    // ============================================================================
    // Farm Registry and Approvals
    // ============================================================================

    // Mapping of farm contract address to its details.
    mapping(address => FarmDetails) public farms;
    // Reverse lookup mapping from farm ID to the corresponding farm contract address.
    mapping(uint256 => address) public farmAddressOf;
    // Tracks addresses approved to create and manage farms.
    mapping(address => bool) public approvedFarmOwners;
    IRootFarm public rootFarm;         // The special RootFarm (farmId = 0).
    // ============================================================================
    // Events for Farm Creation and Approval Management
    // ============================================================================

    /// @notice Emitted when a new farm is created.
    event FarmCreated(
        uint256 indexed farmId,
        address indexed farmAddress,
        address indexed owner
    );
    /// @notice Emitted when a farm owner is approved (or unapproved).
    event FarmOwnerApproved(address indexed farmOwner, bool approved);

    // ============================================================================
    // Benchmark Yield Tracking
    // ============================================================================

    // Mapping of each farm's unique ID to its benchmark yield (used in bonus calculations).
    mapping(uint256 => uint256) public farmBenchmarkYields;

    // ============================================================================
    // Deposit Bonus Records
    // ============================================================================

    /// @notice Structure that records bonus details for an LP’s deposit.
    struct BonusRecord {
        uint256 bonusPaid;   // Amount of bonus DXP paid.
        bool pinned;         // Indicates if bonus is still pinned (active).
        uint256 depositTime; // Timestamp when bonus was issued.
    }
    // Nested mapping: for a given farm (by farmId), record bonus information by LP address.
    mapping(uint256 => mapping(address => BonusRecord)) public bonusRecords;

    // ============================================================================
    // Cooldown Queue for Returned Bonus Tokens
    // ============================================================================

    /// @notice Structure for tokens queued to be recycled after their cooldown period.
    struct CooldownRecord {
        uint256 amount;      // Amount of DXP tokens queued.
        uint256 releaseTime; // Timestamp after which tokens can be recycled.
    }
    // Array holding all cooldown records.
    CooldownRecord[] public cooldownQueue;

    // ============================================================================
    // Stakeholder Lists for Revenue Distribution
    // ============================================================================

    // Constants and mappings for verifiers and yield yodas used in revenue distribution.
    uint256 public constant MIN_VERIFIER_STAKE = 100e18;
    mapping(uint256 => address[]) public approvedVerifiersList;
    mapping(uint256 => address[]) public approvedYieldYodaList;

    // ============================================================================
    // Additional Protocol Parameters and External Interfaces
    // ============================================================================

    uint256 internal protocolFeeRate;   // The current protocol fee rate (percentage).
    uint256 internal reserveRatio;        // The percentage of fees that is kept as reserve.
    uint256 internal lastEmissionCall;    // Timestamp when the last token emission was triggered.
    uint256 internal protocolReserves;    // Accumulated protocol reserves (in DXP).
    uint256 internal emissionReserve;       // DXP tokens reserved for emissions.
    uint256 public depositBonusRatio;     // Ratio used to compute deposit bonuses.

    // External modules:
    ILiquidityManager public liquidityManager; // For fetching TWAP prices and performing token swaps.
    IFarmFactory public farmFactory;           // For creating farms via deterministic CREATE2.
    IBridgeAdapter public bridgeAdapter;       // For bridging messages (not used in this code).

    // Immutable core tokens and the RootFarm.
    IDXPToken public immutable dxpToken;       // The primary DXP token.
    vDXPToken public immutable vdxpToken;        // The governance/claim token.

    // ============================================================================
    // Events for Protocol Operations
    // ============================================================================

    event DepositBonusDistributed(
        uint256 indexed farmId,
        address indexed lp,
        uint256 bonusAmount
    );
    event DepositBonusReversed(
        uint256 indexed farmId,
        address indexed lp,
        uint256 amountReturned
    );
    event PositionUnpinned(
        uint256 indexed farmId,
        address indexed lp,
        uint256 bonusKept
    );
    event EmissionTriggered(uint256 dxpBalance);
    event ReservesDistributed(uint256 totalDistributed, uint256 farmOwnerReceived);
    event EmissionReserveUpdated(uint256 newEmissionReserve);
    event CooldownTokensQueued(uint256 amount, uint256 releaseTime);
    event CooldownTokensRecycled(uint256 totalRecycled);

    // ============================================================================
    // Governance: Fee Update Proposals & Voting Structures (Stubs)
    // ============================================================================

    struct FeeUpdateProposal {
        uint256 id;
        address proposer;
        uint256 newFee;
        uint256 voteEndTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
    }

    uint256 public feeProposalCount;
    mapping(uint256 => FeeUpdateProposal) public feeProposals;
    mapping(uint256 => mapping(address => bool)) public feeVotesCast;
    mapping(uint256 => mapping(address => uint256)) public feeVoteWeights;

    event ProtocolFeeUpdated(uint256 proposalId, uint256 newFee);
    event YieldYodaRegistered(address indexed yoda);
    event BenchmarkYieldUpdated(uint256 indexed farmId, uint256 newYield);

    // ============================================================================
    // Modifiers
    // ============================================================================

    /**
     * @notice Restricts access to functions so that only farms created by the protocol (or the RootFarm)
     *         can execute them. This prevents external contracts from mimicking farm behavior and
     *         capturing deposit bonuses or revenue.
     */
    modifier onlyApprovedFarm() {
        require(
            farms[msg.sender].farmAddress == msg.sender || msg.sender == address(rootFarm),
            "Caller is not an approved farm"
        );
        _;
    }

    // ============================================================================
    // Constructor
    // ============================================================================

    /**
     * @notice Initializes the protocol core by setting key parameters, deploying the governance token,
     *         and creating the RootFarm through the FarmFactory.
     * @param _dxpToken The address of the already deployed DXP token.
     * @param fallbackRatio The fallback bonus ratio (e.g., 70).
     * @param _protocolFeeRate The initial protocol fee rate (percentage).
     * @param _reserveRatio The percentage of fees retained as reserves.
     * @param _farmFactory The address of the FarmFactory contract.
     */
    constructor(
        address _dxpToken,
        uint256 fallbackRatio,
        uint256 _protocolFeeRate,
        uint256 _reserveRatio,
        address _farmFactory
    ) Ownable(msg.sender) {
        require(_dxpToken != address(0), "DXP token=0");
        
        dxpToken = IDXPToken(_dxpToken);
        farmFactory = IFarmFactory(_farmFactory);

        depositBonusRatio = fallbackRatio;
        protocolFeeRate = _protocolFeeRate;
        reserveRatio = _reserveRatio;
        lastEmissionCall = block.timestamp;
        protocolReserves = 0;
        emissionReserve = 0;

        // Deploy vDXPToken with this protocol as the initial minter.
        vDXPToken _vdxp = new vDXPToken("vDXP Token", "vDXP", address(this), 0);
        vdxpToken = _vdxp;

    }


    function setApprovedFarmOwner(
        address farmOwner,
        bool approved
    ) external onlyOwner {
        approvedFarmOwners[farmOwner] = approved;
        emit FarmOwnerApproved(farmOwner, approved);
    }

    function setApprovedVerifier(
        uint256 farmId,
        address verifier,
        bool approved
    ) external onlyOwner {
        if (approved) {
            approvedVerifiersList[farmId].push(verifier);
        } else {
            // Remove verifier from the list.
            address[] storage verifiers = approvedVerifiersList[farmId];
            for (uint256 i = 0; i < verifiers.length; i++) {
                if (verifiers[i] == verifier) {
                    verifiers[i] = verifiers[verifiers.length - 1];
                    verifiers.pop();
                    break;
                }
            }
        }
    }

    function setApprovedYieldYoda(
        uint256 farmId,
        address yieldYoda,
        bool approved
    ) external onlyOwner {
        if (approved) {
            approvedYieldYodaList[farmId].push(yieldYoda);
        } else {
            // Remove yield yoda from the list.
            address[] storage yieldYodas = approvedYieldYodaList[farmId];
            for (uint256 i = 0; i < yieldYodas.length; i++) {
                if (yieldYodas[i] == yieldYoda) {
                    yieldYodas[i] = yieldYodas[yieldYodas.length - 1];
                    yieldYodas.pop();
                    break;
                }
            }
        }
    }
    
    // ============================================================================
    // RootFarm Creation
    // ============================================================================

    // Create the RootFarm using the FarmFactory.
    function createRootFarm(bytes32 salt) external onlyOwner {
        require(address(rootFarm) == address(0), "RootFarm already created");
        // Create the RootFarm using the FarmFactory. The RootFarm is special (farmId = 0)
        // and uses DXP as the underlying asset with vDXP as the claim token.
        (uint256 rootFarmId, address rootFarmAddr) = farmFactory.createRootFarm(
            salt,
            address(dxpToken),    // For RootFarm, the principal asset is DXP.
            address(vdxpToken),    // Claim token is vDXP.
            msg.sender             // The protocol owner (deployer) is initially set as the farm owner.
        );
        farmAddressOf[rootFarmId] = rootFarmAddr;
        farms[rootFarmAddr] = FarmDetails({
            farmAddress: rootFarmAddr,
            owner: msg.sender,
            asset: address(dxpToken),
            farmId: rootFarmId
        });
        rootFarm = IRootFarm(rootFarmAddr);

        // Transfer control of the vDXPToken to the RootFarm: set associated farm, minter, and transfer ownership.
        vdxpToken.setAssociatedFarm(rootFarmAddr);
        vdxpToken.setMinter(rootFarmAddr);
        vdxpToken.transferOwnership(rootFarmAddr);

        emit FarmCreated(rootFarmId, rootFarmAddr, msg.sender);
    }

    // ============================================================================
    // Farm Creation via FarmFactory
    // ============================================================================

    /**
     * @notice Allows an approved farm owner to create a new farm via the FarmFactory.
     * @dev A new claim token is deployed for the farm and later transferred to the farm.
     *      The caller must be approved as a farm owner.
     * @param salt A user-supplied salt used as part of the CREATE2 derivation.
     * @param asset The principal asset for this farm.
     * @param maturityPeriod The minimum maturity period allowed for deposits.
     * @param verifierIncentiveSplit Percentage of yield allocated to verifiers.
     * @param yieldYodaIncentiveSplit Percentage of yield allocated to yield yodas.
     * @param lpIncentiveSplit Percentage of yield allocated to liquidity providers (LPs).
     * @param strategy The strategy contract address that deploys the farm's liquidity.
     * @param claimName The name for the farm's claim token.
     * @param claimSymbol The symbol for the farm's claim token.
     * @return farmId The unique farm identifier.
     * @return farmAddr The deployed farm contract address.
     */
    function createApprovedFarm(
        bytes32 salt,
        address asset,
        uint256 maturityPeriod,
        uint256 verifierIncentiveSplit,
        uint256 yieldYodaIncentiveSplit,
        uint256 lpIncentiveSplit,
        address strategy,
        string memory claimName,
        string memory claimSymbol
    ) external nonReentrant returns (uint256 farmId, address farmAddr) {
        require(approvedFarmOwners[msg.sender], "Not an approved farm owner");
        require(
            verifierIncentiveSplit + yieldYodaIncentiveSplit + lpIncentiveSplit == 100,
            "Incentive split must equal 100"
        );
        address farmOwner = msg.sender;

        // Deploy a new claim token instance for tracking LP positions (1:1 minting with deposits).
        FarmClaimToken farmClaimToken = new FarmClaimToken(claimName, claimSymbol, address(this));

        // Create the farm via the FarmFactory. The factory assigns a new, unique farm ID.
        (farmId, farmAddr) = farmFactory.createFarm(
            salt,
            asset,
            maturityPeriod,
            verifierIncentiveSplit,
            yieldYodaIncentiveSplit,
            lpIncentiveSplit,
            strategy,
            address(farmClaimToken),
            farmOwner
        );

        // Record the new farm's details in the registry mappings.
        farmAddressOf[farmId] = farmAddr;
        farms[farmAddr] = FarmDetails({
            farmAddress: farmAddr,
            owner: farmOwner,
            asset: asset,
            farmId: farmId
        });

        // Transfer control of the claim token to the farm by setting the minter and associated farm,
        // and transferring its ownership.
        farmClaimToken.setMinter(farmAddr);
        farmClaimToken.setAssociatedFarm(farmAddr);
        farmClaimToken.transferOwnership(farmAddr);

        emit FarmCreated(farmId, farmAddr, farmOwner);
    }

    // ============================================================================
    // Benchmark Yield Management
    // ============================================================================

    /**
     * @notice Sets the annual benchmark yield for a given farm.
     * @dev Benchmark yield values are used in bonus calculations.
     * @param farmId The unique identifier of the farm.
     * @param newYield The new benchmark yield value.
     */
    function setFarmBenchmarkYield(
        uint256 farmId,
        uint256 newYield
    ) external onlyOwner {
        farmBenchmarkYields[farmId] = newYield;
        emit BenchmarkYieldUpdated(farmId, newYield);
    }

    // ============================================================================
    // Emission Functions
    // ============================================================================

    /**
     * @notice Triggers emission of DXP tokens.
     * @dev Emission can only be triggered if at least 20 seconds have passed since the last call.
     *      The newly minted tokens are added to both the emission reserve and protocol reserves.
     */
    function triggerEmission() external onlyOwner nonReentrant {
        require(block.timestamp >= lastEmissionCall + 20, "Wait 20s");
        uint256 balanceBefore = dxpToken.balanceOf(address(this));
        lastEmissionCall = block.timestamp;
        dxpToken.emitTokens();
        uint256 balanceAfter = dxpToken.balanceOf(address(this));
        uint256 minted = balanceAfter - balanceBefore;
        emissionReserve += minted;
        protocolReserves += minted;
        emit EmissionTriggered(dxpToken.balanceOf(address(dxpToken)));
        emit EmissionReserveUpdated(emissionReserve);
    }

    /**
     * @notice Synchronizes the protocol reserves with the actual DXP balance held by this contract.
     */
    function syncProtocolReserves() external onlyOwner {
        protocolReserves = dxpToken.balanceOf(address(this));
    }

    // ============================================================================
    // Deposit Bonus & Reversal Functions
    // ============================================================================

    /**
     * @notice Distributes a deposit bonus to an LP based on their deposit's expected yield.
     * @dev The function calculates expected yield in principal terms using a benchmark yield,
     *      converts it to DXP using current pricing from the LiquidityManager, and computes a bonus
     *      based on the deposit bonus ratio. The bonus is deducted from protocol reserves.
     *      This function can only be called by an approved farm (created via the protocol).
     * @param farmId The unique farm identifier.
     * @param lp The liquidity provider’s address.
     * @param principal The deposit amount.
     * @param depositMaturity The desired maturity timestamp for the deposit.
     */
    function distributeDepositBonus(
        uint256 farmId,
        address lp,
        uint256 principal,
        uint256 depositMaturity
    ) external nonReentrant onlyApprovedFarm {
        require(lp != address(0), "Invalid lp");
        // Retrieve details of the calling farm.
        FarmDetails memory farmDetails = farms[msg.sender];

        // Calculate the expected yield (in principal) based on the benchmark yield.
        uint256 benchYield = farmBenchmarkYields[farmId];
        uint256 expectedYield = BonusCalculationLib.computeExpectedYield(
            principal,
            benchYield,
            depositMaturity
        );
        require(expectedYield > 0, "No yield => no bonus");

        // Ensure the LiquidityManager is set to obtain a TWAP price for conversion.
        require(address(liquidityManager) != address(0), "No LiquidityManager set");
        uint256 dxpPriceScaled = liquidityManager.getTwapPrice(
            address(dxpToken),
            farmDetails.asset,
            10000,
            300
        );
        // Fallback to 1:1 pricing if no valid TWAP is available.
        if (dxpPriceScaled == 0) {
            dxpPriceScaled = 1e18;
        }

        // Convert the expected principal yield to DXP and compute the bonus using the depositBonusRatio.
        uint256 yieldInDXP = BonusCalculationLib.convertYieldToDXP(
            expectedYield,
            dxpPriceScaled
        );
        uint256 bonusDXP = BonusCalculationLib.computeDepositBonus(
            yieldInDXP,
            depositBonusRatio
        );
        require(bonusDXP > 0, "Calculated bonus=0");
        require(protocolReserves >= bonusDXP, "Insufficient protocolReserves");

        // Deduct the bonus from protocol reserves and transfer bonus DXP to the LP.
        protocolReserves -= bonusDXP;
        dxpToken.transfer(lp, bonusDXP);

        // Record the bonus issuance so that it can later be reversed if needed.
        bonusRecords[farmId][lp] = BonusRecord({
            bonusPaid: bonusDXP,
            pinned: true,
            depositTime: block.timestamp
        });
        emit DepositBonusDistributed(farmId, lp, bonusDXP);
    }

    /**
     * @notice Reverses an issued deposit bonus when an LP withdraws before the deposit matures.
     * @dev The LP must return the bonus DXP tokens, which are then added to a cooldown queue.
     *      This function can only be called by an approved farm.
     * @param farmId The unique farm identifier.
     * @param lp The liquidity provider’s address.
     * @param amountWithdrawn The withdrawn principal amount.
     * @param isEarly True if the withdrawal is before the weighted maturity.
     */
    function reverseDepositBonus(
        uint256 farmId,
        address lp,
        uint256 amountWithdrawn,
        bool isEarly
    ) external nonReentrant onlyApprovedFarm {
        BonusRecord storage rec = bonusRecords[farmId][lp];
        require(rec.pinned, "No pinned bonus or already unpinned");

        uint256 bonus = rec.bonusPaid;
        if (bonus > 0) {
            require(
                dxpToken.transferFrom(lp, address(this), bonus),
                "User didn't return DXP"
            );
            _queueCooldown(bonus);
        }
        rec.bonusPaid = 0;
        rec.pinned = false;
        emit DepositBonusReversed(farmId, lp, bonus);
    }

    /**
     * @notice Unpins an LP's bonus without forcing a reversal.
     * @dev This allows the LP to retain the bonus under certain conditions.
     * @param farmId The unique farm identifier.
     * @param lp The liquidity provider’s address.
     */
    function unpinPosition(
        uint256 farmId,
        address lp
    ) external nonReentrant onlyApprovedFarm {
        BonusRecord storage rec = bonusRecords[farmId][lp];
        require(rec.pinned, "No pinned bonus or already unpinned");
        rec.pinned = false;
        emit PositionUnpinned(farmId, lp, rec.bonusPaid);
    }

    // ============================================================================
    // Cooldown Queue Management
    // ============================================================================

    /**
     * @notice Internal function to queue bonus tokens for cooldown before they are recycled.
     * @param amount The amount of bonus DXP tokens to queue.
     */
    function _queueCooldown(uint256 amount) internal {
        uint256 release = block.timestamp + COOLDOWN_PERIOD;
        cooldownQueue.push(CooldownRecord({ amount: amount, releaseTime: release }));
        emit CooldownTokensQueued(amount, release);
    }

    /**
     * @notice Recycles bonus tokens from the cooldown queue once the cooldown period has expired.
     *         The recycled tokens are credited back to protocol reserves via dxpToken.recycleTokens().
     */
    function recycleCooldownTokens() external nonReentrant {
        uint256 totalRecycled = 0;
        uint256 i = 0;
        while (i < cooldownQueue.length) {
            if (cooldownQueue[i].releaseTime <= block.timestamp) {
                totalRecycled += cooldownQueue[i].amount;
                // Replace the processed element with the last element and remove the last element.
                cooldownQueue[i] = cooldownQueue[cooldownQueue.length - 1];
                cooldownQueue.pop();
            } else {
                i++;
            }
        }
        if (totalRecycled > 0) {
            dxpToken.recycleTokens(totalRecycled);
            emit CooldownTokensRecycled(totalRecycled);
        }
    }

    // ============================================================================
    // Revenue Pull & Distribution Mechanism
    // ============================================================================

    /**
     * @notice Pulls the net revenue (in DXP) from a specified farm and distributes it among stakeholders.
     * @dev The net revenue is retrieved from the farm’s pullFarmRevenue() function, which returns yield
     *      (already minus the LP's share). The revenue is split among verifiers, yield yodas, and the farm owner,
     *      and then protocol fees are applied. The remaining fee is credited to the RootFarm.
     *      This function can only be called by the protocol owner.
     * @param farmId The unique identifier of the farm.
     */
    function pullFarmRevenue(uint256 farmId) external nonReentrant onlyOwner {
        address farmAddress = farmAddressOf[farmId];
        require(farmAddress != address(0), "Invalid farmId");
        FarmDetails memory farmDetail = farms[farmAddress];

        uint256 revenueDXP = Farm(farmDetail.farmAddress).pullFarmRevenue();
        require(revenueDXP > 0, "No revenue to pull");

        _distributeRevenue(farmId, revenueDXP);
    }

    /**
     * @dev Internal function that calculates and distributes the net revenue from a farm.
     *      Shares are computed for verifiers, yield yodas, and the farm owner. A protocol fee is
     *      applied to the farm owner's share; part of it is stored in reserves and the remainder is
     *      credited to the RootFarm.
     * @param farmId The unique identifier of the farm.
     * @param netRevenue The net revenue in DXP to be distributed.
     */
    function _distributeRevenue(uint256 farmId, uint256 netRevenue) internal {
        address farmAddress = farmAddressOf[farmId];
        FarmDetails memory farmDetail = farms[farmAddress];

        uint256 verifierSplit = Farm(farmDetail.farmAddress).verifierIncentiveSplit();
        uint256 yieldYodaSplit = Farm(farmDetail.farmAddress).yieldYodaIncentiveSplit();
        uint256 farmOwnerSplit = 100 - verifierSplit - yieldYodaSplit;

        uint256 verifierAmount = (netRevenue * verifierSplit) / 100;
        uint256 yieldYodaAmount = (netRevenue * yieldYodaSplit) / 100;
        uint256 farmOwnerAmount = (netRevenue * farmOwnerSplit) / 100;

        // Apply protocol fee to the farm owner's share.
        uint256 protocolFee = (farmOwnerAmount * protocolFeeRate) / 100;
        uint256 reservePortion = (protocolFee * reserveRatio) / 100;
        protocolReserves += reservePortion;
        uint256 rootFarmPortion = protocolFee - reservePortion;
        uint256 finalFarmOwnerAmount = farmOwnerAmount - protocolFee;

        // Distribute verifier share equally; if none exist, add the share to reserves.
        address[] memory verifiers = approvedVerifiersList[farmId];
        if (verifiers.length > 0) {
            uint256 sharePerVerifier = verifierAmount / verifiers.length;
            for (uint256 i = 0; i < verifiers.length; i++) {
                dxpToken.transfer(verifiers[i], sharePerVerifier);
            }
        } else {
            protocolReserves += verifierAmount;
        }

        // Distribute yield yoda share equally; if none exist, add the share to reserves.
        address[] memory yieldYodas = approvedYieldYodaList[farmId];
        if (yieldYodas.length > 0) {
            uint256 sharePerYieldYoda = yieldYodaAmount / yieldYodas.length;
            for (uint256 i = 0; i < yieldYodas.length; i++) {
                dxpToken.transfer(yieldYodas[i], sharePerYieldYoda);
            }
        } else {
            protocolReserves += yieldYodaAmount;
        }

        // Transfer the final farm owner share to the farm owner.
        dxpToken.transfer(farmDetail.owner, finalFarmOwnerAmount);

        // Credit any remaining portion to the RootFarm.
        if (rootFarmPortion > 0) {
            dxpToken.transfer(address(rootFarm), rootFarmPortion);
            rootFarm.addRevenueDXP(rootFarmPortion);
        }

        emit ReservesDistributed(
            verifierAmount + yieldYodaAmount + finalFarmOwnerAmount,
            finalFarmOwnerAmount
        );
    }

    // ============================================================================
    // Governance: Fee Update Proposals & Voting (Stubs for Future Implementation)
    // ============================================================================

    /**
     * @notice Proposes a new protocol fee rate.
     * @param newFee New fee rate (must be ≤ 100).
     * @param votingPeriod Voting duration in seconds.
     * @return proposalId The unique identifier for this fee proposal.
     */
    function proposeProtocolFeeUpdate(
        uint256 newFee,
        uint256 votingPeriod
    ) external nonReentrant returns (uint256 proposalId) {
        require(newFee <= 100, "Fee>100%");
        require(vdxpToken.isCooledDown(msg.sender), "Not cooled down for voting");
        // Implementation omitted for brevity.
    }

    /**
     * @notice Casts a vote on a protocol fee update proposal.
     * @param proposalId The proposal identifier.
     * @param support True for supporting the proposal, false otherwise.
     */
    function voteOnFeeUpdate(
        uint256 proposalId,
        bool support
    ) external nonReentrant {
        
    }

    /**
     * @notice Executes a fee update proposal if it passes.
     * @param proposalId The identifier of the proposal.
     */
    function executeFeeUpdate(uint256 proposalId) external nonReentrant {
        
    }

    /**
     * @notice Sends a cross-chain governance update via the bridging adaptor.
     * @param destChainId Destination chain ID.
     * @param targetContract Target contract address on the destination chain.
     * @param data Encoded governance update message.
     */
    function sendGovernanceUpdate(
        uint256 destChainId,
        address targetContract,
        bytes calldata data
    ) external payable onlyOwner {
        require(address(bridgeAdapter) != address(0), "No bridge adapter set");
        // implementation pending.
    }

    // ============================================================================
    // External Setters and Public Getters
    // ============================================================================

    /**
     * @notice Sets the bridging adaptor address.
     * @param _adaptor The address of the bridging adaptor.
     */
    function setBridgingAdaptor(address _adaptor) external onlyOwner {
        bridgeAdapter = IBridgeAdapter(_adaptor);
    }

    /**
     * @notice Sets the address of the LiquidityManager.
     * @param _lm The LiquidityManager address.
     */
    function setLiquidityManager(address _lm) external onlyOwner {
        liquidityManager = ILiquidityManager(_lm);
    }

    /**
     * @notice Updates the deposit bonus ratio used in bonus calculations.
     * @param ratio The new deposit bonus ratio.
     */
    function setDepositBonusRatio(uint256 ratio) external onlyOwner {
        depositBonusRatio = ratio;
    }

    /**
     * @notice Updates the protocol fee rate.
     * @param newFee The new protocol fee rate (must be ≤ 100).
     */
    function setProtocolFeeRate(uint256 newFee) external onlyOwner {
        require(newFee <= 100, "Fee>100%");
        protocolFeeRate = newFee;
    }

    /**
     * @notice Returns the current protocol fee rate.
     */
    function getProtocolFeeRate() external view returns (uint256) {
        return protocolFeeRate;
    }

    /**
     * @notice Returns the current DXP reserves held by the protocol.
     */
    function getProtocolReserves() external view returns (uint256) {
        return protocolReserves;
    }

    /**
     * @notice Returns the amount of DXP tokens reserved for emission.
     */
    function getEmissionReserve() external view returns (uint256) {
        return emissionReserve;
    }
}