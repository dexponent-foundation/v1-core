// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title  ProtocolCore (Test-net v1)
 * @author Dexponent
 *
 * @notice
 * Central registry and accounting contract for the Dexponent protocol.
 * Responsibilities ­include
 *
 *  ▸ emitting & reserving DXP,
 *  ▸ managing farms (Root Farm + user farms) and their benchmark yields,
 *  ▸ computing / issuing / reversing LP deposit bonuses,
 *  ▸ pulling farm revenue & splitting it among verifiers, yield-yodas and farm owner,
 *  ▸ holding verifier stakes and exposing the canonical verifier list,
 *  ▸ storing consensus round results (score + benchmark) supplied by an external
 *    `Consensus` module,
 *  ▸ supporting fast-track “time-scaling” on test-nets, and
 *  ▸ stubbing out governance/hooks for future main-net upgrades.
 *
 * NOTE: Governance (fee proposals, cross-chain updates) is intentionally left
 *       un-implemented in test-net v1; related methods are NO-OP placeholders.
 *
 * SECURITY MODEL
 * ──────────────
 *  • Only farms created via this contract (or the special Root Farm) may call
 *    sensitive reward / bonus functions (enforced by `onlyApprovedFarm`).
 *  • Verifier registration requires an on-chain DXP stake ≥ `minVerifierStake`.
 *  • All external setters are `onlyOwner`, delegated to the protocol DAO on
 *    main-net but keyed to the deployer for test-nets.
 *
 * All critical state is declared at the top of the file so auditors can track
 * storage layout with the original deployment.
 */

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import "./libraries/BonusCalculationLib.sol";
import "./ClaimToken.sol";
import "./interfaces/IDXPToken.sol";
import "./vDXPToken.sol";
import "./interfaces/IRootFarm.sol";
import "./interfaces/IConsensus.sol";
import "./interfaces/IFarmFactory.sol";
import "./interfaces/ILiquidityManager.sol";
import "./interfaces/IBridgeAdapter.sol";

// local farm interface (only the fns we actually call)
interface IFarmMinimal {
    function pullFarmRevenue() external returns (uint256);

    function verifierIncentiveSplit() external view returns (uint256);

    function yieldYodaIncentiveSplit() external view returns (uint256);
}

contract ProtocolCore is Ownable, ReentrancyGuard {
    // ───────────────────────────────────────────────────────────
    //                        CONSTANTS
    // ───────────────────────────────────────────────────────────
    uint256 public constant COOLDOWN_PERIOD = 1 days; // LP-bonus cooldown

    // ───────────────────────────────────────────────────────────
    //                        DATA-MODELS
    // ───────────────────────────────────────────────────────────

    /// Farm registry entry
    struct FarmDetails {
        address farmAddress; // on-chain Farm contract
        address owner; // farm-owner (EOA or multisig)
        address asset; // principal ERC-20
        uint256 farmId; // global farmId
    }

    /// LP-bonus bookkeeping
    struct BonusRecord {
        uint256 bonusPaid; // DXP sent to LP
        bool pinned; // true = still claw-back-able
        uint256 depositTime; // timestamp issued
    }

    /// Returned DXP queued for recycling
    struct CooldownRecord {
        uint256 amount;
        uint256 releaseTime;
    }

    /// Averaged verifier result for a consensus round
    struct ConsensusResult {
        uint256 score; // basis-points risk / performance score
        uint256 benchmark; // APY % used for next period’s bonuses
    }

    /// Governance (stub)
    struct FeeUpdateProposal {
        uint256 id;
        address proposer;
        uint256 newFee; // %
        uint256 voteEndTime;
        uint256 forVotes;
        uint256 againstVotes;
        bool executed;
    }

    // ───────────────────────────────────────────────────────────
    //                 REGISTRY - FARMS & OWNERS
    // ───────────────────────────────────────────────────────────
    mapping(address => FarmDetails) public farms; // farmAddr ➜ details
    mapping(uint256 => address) public farmAddressOf; // farmId   ➜ farmAddr
    mapping(address => bool) public approvedFarmOwners;
    IRootFarm public rootFarm; // id 0

    // ───────────────────────────────────────────────────────────
    //                     YIELDS & CONSENSUS
    // ───────────────────────────────────────────────────────────
    mapping(uint256 => uint256) public farmBenchmarkYields; // farmId ➜ APY %
    mapping(uint256 => mapping(uint256 => ConsensusResult))
        public consensusResults; // farmId ➜ roundId ➜ result

    // ───────────────────────────────────────────────────────────
    //                  BONUS / COOLDOWN DATA
    // ───────────────────────────────────────────────────────────
    mapping(uint256 => mapping(address => BonusRecord)) public bonusRecords;
    CooldownRecord[] public cooldownQueue;

    // ───────────────────────────────────────────────────────────
    //                  VERIFIERS & YIELD-YODAS
    // ───────────────────────────────────────────────────────────
    mapping(uint256 => address[]) public approvedVerifiersList; // farmId ➜ verifiers
    mapping(uint256 => address[]) public approvedYieldYodaList; // farmId ➜ yodas
    mapping(uint256 => mapping(address => uint256)) public verifierStakes; // farmId ➜ verifier ➜ stake
    uint256 public minVerifierStake = 100e18; // mutable parameter

    // ───────────────────────────────────────────────────────────
    //              PROTOCOL-WIDE FINANCIAL STATE
    // ───────────────────────────────────────────────────────────
    uint256 internal protocolFeeRate; // % of farmOwner share
    uint256 internal transferFeeRate;
    uint256 internal reserveRatio; // % of fee retained in reserves
    uint256 internal lastEmissionCall; // timestamp
    uint256 internal protocolReserves; // DXP
    uint256 internal emissionReserve; // DXP earmarked for emissions
    uint256 public depositBonusRatio; // % of expected yield paid as bonus

    // ───────────────────────────────────────────────────────────
    //                 EXTERNAL MODULE REFERENCES
    // ───────────────────────────────────────────────────────────
    ILiquidityManager public liquidityManager;
    IFarmFactory public farmFactory;
    IBridgeAdapter public bridgeAdapter;
    IConsensus public consensus; // pulls verifier rounds

    // immutable tokens
    IDXPToken public immutable dxpToken;
    vDXPToken public immutable vdxpToken;

    // ───────────────────────────────────────────────────────────
    //                        TIME-SCALING
    // ───────────────────────────────────────────────────────────
    uint256 public timeScaleNumerator = 1; // main-net = 1
    uint256 public timeScaleDenominator = 1;

    // ───────────────────────────────────────────────────────────
    //                           EVENTS
    // ───────────────────────────────────────────────────────────
    event FarmCreated(
        uint256 indexed farmId,
        address indexed farm,
        address indexed owner
    );
    event FarmOwnerApproved(address indexed farmOwner, bool approved);

    event BenchmarkYieldUpdated(uint256 indexed farmId, uint256 newYield);
    event ConsensusModuleUpdated(address indexed consensusAddr);
    event ConsensusRecorded(
        uint256 indexed farmId,
        uint256 indexed roundId,
        uint256 score,
        uint256 benchmark
    );

    event DepositBonusDistributed(
        uint256 indexed farmId,
        address indexed lp,
        uint256 bonusDXP
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

    event CooldownTokensQueued(uint256 amount, uint256 releaseTime);
    event CooldownTokensRecycled(uint256 total);
    event EmissionTriggered(uint256 minted);
    event EmissionReserveUpdated(uint256 newReserve);

    event ReservesDistributed(uint256 totalOut, uint256 toFarmOwner);
    event TransferFeeRateUpdated(uint256 oldFeeRate, uint256 newFeeRate);

    event VerifierRegistered(
        uint256 indexed farmId,
        address indexed verifier,
        uint256 stake
    );
    event VerifierUnregistered(
        uint256 indexed farmId,
        address indexed verifier
    );
    event MinVerifierStakeUpdated(uint256 oldStake, uint256 newStake);

    event YieldYodaUpdated(
        uint256 indexed farmId,
        address indexed yoda,
        bool approved
    );

    event TimeScaleUpdated(uint256 num, uint256 den);

    // ───────────────────────────────────────────────────────────
    //                           MODIFIERS
    // ───────────────────────────────────────────────────────────
    /**
     * @dev Restricts caller to a whitelisted Farm created by this contract
     *      or the special RootFarm (id 0).
     */
    modifier onlyApprovedFarm() {
        require(
            farms[msg.sender].farmAddress == msg.sender ||
                msg.sender == address(rootFarm),
            "ProtocolCore: not farm"
        );
        _;
    }

    // ───────────────────────────────────────────────────────────
    //                       CONSTRUCTOR
    // ───────────────────────────────────────────────────────────
    /**
     * @param _dxpToken         Pre-deployed ERC-20 DXP address
     * @param fallbackRatio     Default bonus ratio (e.g. 70 = 70 %)
     * @param _protocolFeeRate  % fee on farm-owner slice of revenue
     * @param _reserveRatio     % of fee kept in reserves (rest sent to RootFarm)
     * @param _farmFactory      Factory that deploys farms & claim-tokens
     */
    constructor(
        address _dxpToken,
        uint256 fallbackRatio,
        uint256 _protocolFeeRate,
        uint256 _reserveRatio,
        address _farmFactory
    ) Ownable(msg.sender) {
        require(_dxpToken != address(0), "DXP=0");
        dxpToken = IDXPToken(_dxpToken);
        farmFactory = IFarmFactory(_farmFactory);

        depositBonusRatio = fallbackRatio;
        protocolFeeRate = _protocolFeeRate;
        transferFeeRate = 50; // 0.5% default
        reserveRatio = _reserveRatio;
        lastEmissionCall = block.timestamp;

        // deploy governance/vote token (vDXP) and leave minter with this core
        vdxpToken = new vDXPToken("vDXP Token", "vDXP", address(this), 0);
    }

    // ───────────────────────────────────────────────────────────
    //              TIME-SCALING (test-net convenience)
    // ───────────────────────────────────────────────────────────

    /**
     * @notice Convert a real-world period into an on-chain period according
     *         to the current scale (e.g. 1 year ⇒ 12 days on Base-Sepolia).
     */
    function scalePeriod(
        uint256 secondsPeriod
    ) external view returns (uint256) {
        return (secondsPeriod * timeScaleNumerator) / timeScaleDenominator;
    }

    /** @dev Owner-only helper to change test-net scale. */
    function setTimeScale(uint256 num, uint256 den) external onlyOwner {
        require(den != 0, "den=0");
        timeScaleNumerator = num;
        timeScaleDenominator = den;
        emit TimeScaleUpdated(num, den);
    }

    // ───────────────────────────────────────────────────────────
    //                FARM-OWNER REGISTRY HELPERS
    // ───────────────────────────────────────────────────────────
    function setApprovedFarmOwner(
        address who,
        bool approved
    ) external onlyOwner {
        approvedFarmOwners[who] = approved;
        emit FarmOwnerApproved(who, approved);
    }

    // ───────────────────────────────────────────────────────────
    //                       ROOT FARM
    // ───────────────────────────────────────────────────────────

    /**
     * @notice One-shot creation of the Root Farm (farmId 0).  Uses DXP as both
     *         principal and reward asset; receives all protocol fees.
     */
    /**
     * @notice Point ProtocolCore at an already-deployed RootFarm.
     * @param _root The RootFarm address.
     */
    function setRootFarm(address _root) external onlyOwner {
        require(address(rootFarm) == address(0), "RootFarm: already set");
        require(_root != address(0), "rootFarm address cant be zero");
        rootFarm = IRootFarm(_root);
        uint256 farmId = 0;
        // 3) Record in ProtocolCore’s registry
        farmAddressOf[farmId] = _root;
        farms[_root] = FarmDetails({
            farmAddress: _root,
            owner: msg.sender,
            asset: address(dxpToken),
            farmId: farmId
        });

        // 4) Hand off claim-token control to the farm
        vdxpToken.setMinter(_root);
        vdxpToken.setAssociatedFarm(_root);
        vdxpToken.transferOwnership(_root);

        emit FarmCreated(farmId, _root, msg.sender);
    }

    // ───────────────────────────────────────────────────────────
    //                       FARM FACTORY
    // ───────────────────────────────────────────────────────────
    /**
     * @notice Create a new Farm (standard or restake) via the FarmFactory.
     * @param salt                 User-supplied salt for deterministic CREATE2.
     * @param asset                Principal asset for deposits.
     * @param maturityPeriod       Deposit maturity period (seconds).
     * @param verifierIncentiveSplit  % of yield to verifiers (0–100).
     * @param yieldYodaIncentiveSplit % of yield to yield-yodas (0–100).
     * @param lpIncentiveSplit        % of yield to LPs (0–100).
     * @param strategy             Address of the strategy contract.
     * @param claimName            Name for the farm’s claim token.
     * @param claimSymbol          Symbol for the farm’s claim token.
     * @param isRestaked           If true, deploys a RestakeFarm; otherwise a standard Farm.
     * @param rootFarmAddress      Required if isRestaked=true; links back to your RootFarm.
     * @return farmId              The auto-incremented farm identifier.
     * @return farmAddr            The address of the newly created farm contract.
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
        string memory claimSymbol,
        bool isRestaked,
        address rootFarmAddress
    ) external nonReentrant returns (uint256 farmId, address farmAddr) {
        require(approvedFarmOwners[msg.sender], "Not an approved farm owner");
        require(
            verifierIncentiveSplit +
                yieldYodaIncentiveSplit +
                lpIncentiveSplit ==
                100,
            "Incentive split must equal 100"
        );

        // 1) Deploy the claim token for this farm
        FarmClaimToken farmClaimToken = new FarmClaimToken(
            claimName,
            claimSymbol,
            address(this)
        );

        // 2) Branch on restake vs. standard
        if (isRestaked) {
            (farmId, farmAddr) = farmFactory.createRestakeFarm(
                salt,
                asset,
                maturityPeriod,
                verifierIncentiveSplit,
                yieldYodaIncentiveSplit,
                lpIncentiveSplit,
                strategy,
                address(farmClaimToken),
                msg.sender,
                rootFarmAddress
            );
        } else {
            (farmId, farmAddr) = farmFactory.createFarm(
                salt,
                asset,
                maturityPeriod,
                verifierIncentiveSplit,
                yieldYodaIncentiveSplit,
                lpIncentiveSplit,
                strategy,
                address(farmClaimToken),
                msg.sender
            );
        }

        // 3) Record in ProtocolCore’s registry
        farmAddressOf[farmId] = farmAddr;
        farms[farmAddr] = FarmDetails({
            farmAddress: farmAddr,
            owner: msg.sender,
            asset: asset,
            farmId: farmId
        });

        // 4) Hand off claim-token control to the farm
        farmClaimToken.setMinter(farmAddr);
        farmClaimToken.setAssociatedFarm(farmAddr);
        farmClaimToken.transferOwnership(farmAddr);

        emit FarmCreated(farmId, farmAddr, msg.sender);
    }

    // ───────────────────────────────────────────────────────────
    //                    VERIFIER STAKING LOGIC
    // ───────────────────────────────────────────────────────────
    /**
     * @notice Update the minimum DXP stake required to become a verifier.
     *         Main-net governance can raise this; lowers spam risk on test-nets.
     */
    function setMinVerifierStake(uint256 stake) external onlyOwner {
        require(stake > 0, "stake=0");
        emit MinVerifierStakeUpdated(minVerifierStake, stake);
        minVerifierStake = stake;
    }

    /**
     * @notice Stake DXP and register as an approved verifier for `farmId`.
     * @param farmId  Farm identifier
     * @param amount  Amount of DXP to lock (must be ≥ `minVerifierStake`)
     */
    function registerAsVerifier(
        uint256 farmId,
        uint256 amount
    ) external nonReentrant {
        require(amount >= minVerifierStake, "stake<min");
        require(farmAddressOf[farmId] != address(0), "bad farmId");

        dxpToken.transferFrom(msg.sender, address(this), amount);

        if (verifierStakes[farmId][msg.sender] == 0) {
            approvedVerifiersList[farmId].push(msg.sender);
        }
        verifierStakes[farmId][msg.sender] += amount;
        emit VerifierRegistered(farmId, msg.sender, amount);
    }

    /**
     * @notice Withdraw part/all stake.  If balance hits zero the verifier is
     *         automatically removed from the approved list.
     */
    function withdrawVerifierStake(
        uint256 farmId,
        uint256 amount
    ) external nonReentrant {
        uint256 st = verifierStakes[farmId][msg.sender];
        require(st >= amount && amount > 0, "bad amount");

        verifierStakes[farmId][msg.sender] = st - amount;

        if (verifierStakes[farmId][msg.sender] == 0) {
            address[] storage lst = approvedVerifiersList[farmId];
            for (uint256 i; i < lst.length; i++) {
                if (lst[i] == msg.sender) {
                    lst[i] = lst[lst.length - 1];
                    lst.pop();
                    break;
                }
            }
            emit VerifierUnregistered(farmId, msg.sender);
        }
        dxpToken.transfer(msg.sender, amount);
    }

    /// Simple views for the Consensus module / UIs
    function isApprovedVerifier(
        uint256 farmId,
        address who
    ) external view returns (bool) {
        address[] storage lst = approvedVerifiersList[farmId];
        for (uint256 i; i < lst.length; i++) if (lst[i] == who) return true;
        return false;
    }

    function getApprovedVerifiers(
        uint256 farmId
    ) external view returns (address[] memory) {
        return approvedVerifiersList[farmId];
    }

    function getApprovedYieldYodas(
        uint256 farmId
    ) external view returns (address[] memory) {
        return approvedYieldYodaList[farmId];
    }

    // ───────────────────────────────────────────────────────────
    //                   CONSENSUS MODULE CALLBACK
    // ───────────────────────────────────────────────────────────
    function setConsensusModule(address c) external onlyOwner {
        require(c != address(0), "zero address");
        consensus = IConsensus(c);
        emit ConsensusModuleUpdated(c);
    }

    /**
     * @notice Called by the active Consensus module after each round.
     * @dev    Stores result and immediately updates `farmBenchmarkYields` so
     *         future deposit bonuses reference the fresh value.
     */
    function recordConsensus(
        uint256 farmId,
        uint256 roundId,
        uint256 score,
        uint256 benchmark
    ) external {
        require(msg.sender == address(consensus), "!consensus");
        consensusResults[farmId][roundId] = ConsensusResult(score, benchmark);
        farmBenchmarkYields[farmId] = benchmark;
        emit ConsensusRecorded(farmId, roundId, score, benchmark);
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
        emit EmissionTriggered(minted);
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
        require(
            address(liquidityManager) != address(0),
            "No LiquidityManager set"
        );
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
        cooldownQueue.push(
            CooldownRecord({amount: amount, releaseTime: release})
        );
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

        uint256 revenueDXP = IFarm(farmDetail.farmAddress).pullFarmRevenue();
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

        uint256 verifierSplit = Farm(farmDetail.farmAddress)
            .verifierIncentiveSplit();
        uint256 yieldYodaSplit = Farm(farmDetail.farmAddress)
            .yieldYodaIncentiveSplit();
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


        // ─── CLAIM TOKEN FEE ──────────────────────────────────────────────────────
    /**
     * @notice Update the basis-points fee charged on claimToken transfers.
     * @param _newFeeRate Fee in bp (max 2000 = 20%).
     */
    function setTransferFeeRate(uint256 _newFeeRate) external onlyOwner {
        require(_newFeeRate <= 2000, "fee too high");
        emit TransferFeeRateUpdated(transferFeeRate, _newFeeRate);
        transferFeeRate = _newFeeRate;
    }

    // ─── GOVERNANCE STUBS ─────────────────────────────────────────────────────
    function proposeProtocolFeeUpdate(uint256, uint256)
        external nonReentrant returns (uint256)
    { revert("unimplemented"); }
    function voteOnFeeUpdate(uint256, bool) external nonReentrant { revert("unimplemented"); }
    function executeFeeUpdate(uint256)  external nonReentrant         { revert("unimplemented"); }
    function sendGovernanceUpdate(
        uint256, address, bytes calldata
    ) external payable onlyOwner { revert("unimplemented"); }

    /**
     * @notice Returns the current protocol fee rate.
     */
    function getProtocolFeeRate() external view returns (uint256) {
        return protocolFeeRate;
    }

    function getTransferFeeRate() external view returns (uint256) {
        return transferFeeRate;
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
