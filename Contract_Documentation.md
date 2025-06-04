# Protocol Contracts Documentation

This document provides a consolidated and in-depth overview of all smart contracts within the protocol.

## Table of Contents
1.  [ProtocolCore Contract](#protocolcore-contract)
2.  [DXP Token Contract](#dxp-token-contract)
3.  [Farm Contract](#farm-contract)
4.  [vDXP Token Contract](#vdxp-token-contract)
5.  [FarmFactory Contract](#farmfactory-contract)
6.  [Consensus Contract](#consensus-contract)
7.  [RootFarm Contract](#rootfarm-contract)
8.  [RestakeFarm Contract](#restakefarm-contract)
9.  [Claim Token Contracts (BaseClaimToken & FarmClaimToken)](#claim-token-contracts)
10. [ERC6909 Multi-Token Standard Implementation](#erc6909-multi-token-standard-implementation)
11. [FarmStrategy Interface (`interfaces/FarmStrategy.sol`)](#farmstrategy-interface)
12. [IBridgeAdapter Interface (`interfaces/IBridgeAdapter.sol`)](#ibridgeadapter-interface)
13. [ILiquidityManager Interface (`interfaces/ILiquidityManager.sol`)](#iliquiditymanager-interface)
14. [ERC6909TokenSupply Extension (`interfaces/extensions/ERC6909TokenSupply.sol`)](#erc6909tokensupply-extension)
15. [BonusCalculationLib (`libraries/BonusCalculationLib.sol`)](#bonuscalculationlib)
16. [BridgingAdapter Implementation (`libraries/BridgeAdaptor.sol`)](#bridgingadapter-implementation)
17. [LiquidityManager Implementation (`libraries/LiquidityManager.sol`)](#liquiditymanager-implementation)
18. [TickMath Library (`libraries/TickMath.sol`)](#tickmath-library)
   <!-- Add more contracts here as they are documented -->

---

# ProtocolCore Contract

## Overview
The `ProtocolCore` contract serves as the central hub of the protocol, managing core functionalities and coordinating between different components.

## Key Features
- Manages protocol-wide configurations
- Handles cross-chain operations
- Manages protocol fees and rewards
- Coordinates with the consensus mechanism

## State Variables
```solidity
// Protocol configuration
address public protocolFeeRecipient;
uint256 public protocolFeeBps;

// Contract references
IERC20 public dxpToken;
IConsensus public consensus;
IFarmFactory public farmFactory;

// Protocol state
mapping(uint256 => bool) public supportedChainIds;
mapping(address => bool) public isFarm;
mapping(address => bool) public isStrategy;
```

## Key Functions

### `initialize`
Initializes the protocol with necessary parameters.

### `createFarm`
Creates a new farm with the specified parameters.

### `setProtocolFee`
Sets the protocol fee and fee recipient.

### `updateSupportedChain`
Adds or removes supported chain IDs for cross-chain operations.

## Events
```solidity
event FarmCreated(address indexed farm, address indexed creator, address indexed strategy);
event ProtocolFeeUpdated(address indexed feeRecipient, uint256 feeBps);
event ChainSupportUpdated(uint256 chainId, bool isSupported);
```

## Modifiers
- `onlyGovernance`: Restricts access to governance functions
- `onlyFarm`: Allows only registered farms to call the function
- `onlySupportedChain`: Ensures the operation is on a supported chain

## Security Considerations
- Uses OpenZeppelin's `ReentrancyGuard` for protection against reentrancy attacks
- Implements proper access control using `Ownable` pattern
- Includes emergency withdrawal functions for stuck funds

---

# DXP Token Contract

## Overview
The DXP Token (Dexponent Token) is the native utility token of the Dexponent Protocol. It implements a fixed supply of 21 million tokens with a built-in emission schedule and vesting mechanism.

## Key Features
- Fixed total supply of 21,000,000 DXP tokens
- 60% (12.6M) allocated for emissions with halving every 4 years
- 40% (8.4M) allocated for vested allocations (team, advisors, etc.)
- Built-in vesting wallet factory with cliff and linear vesting
- Emission mechanism that mints tokens over time based on block intervals
- Token recycling functionality for protocol operations

## Tokenomics

### Supply Distribution
```solidity
TOTAL_SUPPLY = 21,000,000 DXP
├── EMISSION_SUPPLY: 12,600,000 DXP (60%) - Gradually minted through emissions
└── VESTED_SUPPLY: 8,400,000 DXP (40%) - Allocated for vested distributions
```

### Emission Schedule
- Initial emission rate: 1 DXP per block (30-second block time)
- Halving interval: Every 4 years (1,261,440,000 seconds)
- Emission continues until the full 12.6M emission supply is distributed

## State Variables

### Core Parameters
```solidity
uint256 public constant TOTAL_SUPPLY = 21_000_000 * 1e18;
uint256 public constant EMISSION_SUPPLY = (TOTAL_SUPPLY * 60) / 100;
uint256 public constant VESTED_SUPPLY = (TOTAL_SUPPLY * 40) / 100;


uint256 public emissionPerBlock = 1 * 1e18;  
uint256 public immutable blockTime = 30;     
uint256 public immutable halvingInterval = 4 * 365 days;


uint256 public totalEmitted;      
uint256 public lastHalvingTime;   
uint256 public lastEmissionTime;  


mapping(address => address) public vestingWallets;  
```

## Key Functions

### emitTokens()
Mints new DXP tokens based on time elapsed since last emission, respecting the halving schedule.
```solidity
function emitTokens() external onlyOwner nonReentrant
```

### recycleTokens(uint256 amount)
Burns tokens from the caller and mints an equivalent amount to the contract address.
```solidity
function recycleTokens(uint256 amount) external
```

### createVestingWallet(address beneficiary, uint64 startTimestamp, uint64 durationSeconds, uint64 cliffSeconds, uint256 amount)
Creates a new vesting wallet for a beneficiary with specified parameters.
```solidity
function createVestingWallet(
    address beneficiary,
    uint64 startTimestamp,
    uint64 durationSeconds,
    uint64 cliffSeconds,
    uint256 amount
) external onlyOwner
```

## Events

### HalvingOccurred
Emitted when the emission rate is halved.
```solidity
event HalvingOccurred(uint256 newEmissionRate);
```

### TokensEmitted
Emitted when new tokens are minted through the emission mechanism.
```solidity
event TokensEmitted(uint256 amount);
```

### TokensRecycled
Emitted when tokens are recycled back to the contract.
```solidity
event TokensRecycled(uint256 amount);
```

### VestingWalletCreated
Emitted when a new vesting wallet is created.
```solidity
event VestingWalletCreated(address indexed beneficiary, address vestingWallet);
```

## Security Considerations
- Uses OpenZeppelin's `ReentrancyGuard` to prevent reentrancy attacks
- Implements `onlyOwner` access control for sensitive functions
- Emission mechanism includes checks to prevent exceeding the total emission supply
- Vesting wallets are deployed as separate contracts for better isolation

## Integration Notes
- The protocol should regularly call `emitTokens()` to maintain the emission schedule
- Vested tokens can be distributed by the owner using `createVestingWallet()`
- The contract implements ERC20Permit for gasless approvals (EIP-2612)

---

# Farm Contract

## Overview
The `Farm` contract is a base contract for managing Liquidity Provider (LP) deposits, yield accrual, bonus DXP issuance and reversal, and the deployment of liquidity to an associated strategy contract. It is designed to be versatile for different types of farms within the protocol, including the RootFarm.

## Key Features
- Manages deposits and withdrawals of a principal asset (ERC20 or native currency).
- Tracks total liquidity provided by LPs and the amount deployed to external strategies.
- Implements an accumulator model (`accYieldPerShare`) for fair yield distribution.
- Manages individual LP positions, including their principal, weighted average maturity, and DXP bonuses.
- Defines immutable incentive splits for LPs, verifiers, and yield yodas.
- Includes an emergency pause mechanism to halt critical operations.
- Interacts with `ClaimToken`, `Strategy`, `ProtocolCore`, and `LiquidityManager` contracts.

## State Variables

### Liquidity & Principal Tracking
```solidity
address public asset; 
address public farmOwner; 
uint256 public farmId; 
uint256 public totalLiquidity; 
uint256 public deployedLiquidity; 
uint256 public principalReserve;
```

### Yield Tracking (Accumulator Model)
```solidity
uint256 public accYieldPerShare; 
mapping(address => uint256) public yieldDebt; 
uint256 public farmRevenueDXP; 
```

### LP Position Tracking
```solidity
struct Position {
    uint256 principal;        
    uint256 weightedMaturity; 
    uint256 bonus;            
    uint256 lastUpdate;       
}
mapping(address => Position) public positions;

uint256 public immutable minimumMaturityPeriod; 
```

### Incentive Splits (Immutable)
```solidity
uint256 public immutable lpIncentiveSplit; 
uint256 public immutable verifierIncentiveSplit; 
uint256 public immutable yieldYodaIncentiveSplit; 

```

### External Contract References
```solidity
BaseClaimToken public claimToken; 
address public strategy; 
IProtocolCore public protocolMaster; // The main protocol core contract
ILiquidityManager public liquidityManager; // For swapping yield to DXP
address public pool; // Associated liquidity pool (e.g., for price discovery)
```

### Emergency Pause
```solidity
bool public paused; // Flag to indicate if the farm is paused
```

## Key Functions (from initial snippet)

### `availableLiquidity()`
Returns the amount of liquidity currently held in the Farm and not deployed to the strategy.
```solidity
function availableLiquidity() public view returns (uint256)
```

### Constructor
Initializes the Farm with its core parameters, including asset type, incentive splits, and external contract addresses.
```solidity
constructor(
    uint256 _farmId,
    address _asset,
    uint256 _maturityPeriod,
    uint256 _verifierIncentiveSplit,
    uint256 _yieldYodaIncentiveSplit,
    uint256 _lpIncentiveSplit,
    address _strategy,
    address _protocolMaster,
    address _claimToken,
    address _farmOwner
) Ownable(_protocolMaster)
```

## Events
```solidity
event LiquidityProvided(address indexed lp, uint256 amount, uint256 weightedMaturity);
event PositionUpdated(address indexed lp, uint256 newPrincipal, uint256 newWeightedMaturity);
event PrincipalRedeemed(address indexed lp, uint256 netWithdrawal);
event YieldClaimed(address indexed lp, uint256 yieldAmount);
event RevenuePulled(address indexed caller, uint256 harvestedYield, uint256 convertedToDXP);
event DeployedLiquidity(uint256 amount);
event WithdrawnFromStrategy(uint256 amount);
event SlashFeeApplied(address indexed lp, uint256 fee);
event PrincipalReserveUpdated(uint256 feeAmount, uint256 newReserve);
event BonusDistributionFailed(address indexed lp, uint256 principal, uint256 maturity);
event BonusReversalFailed(address indexed lp, uint256 amount, bool isEarly);
event FullExitProcessed(address indexed lp, uint256 principalWithdrawn, uint256 bonusReturned, uint256 yieldClaimed);
event Paused(address indexed account);
event Unpaused(address indexed account);
```

## Modifiers
- `whenNotPaused()`: Ensures the contract is not paused before executing a function.
- `onlyProtocolMaster()`: Restricts access to functions callable only by the `ProtocolCore` contract.
- `onlyFarmOwner()`: Restricts access to functions callable only by the `farmOwner` or the protocol's `Ownable` owner (which is `ProtocolCore`).

## Security Considerations
- Inherits `Ownable` for ownership control (delegated to `ProtocolCore`).
- Inherits `ReentrancyGuard` to protect against reentrancy attacks on critical functions.
- Emergency pause functionality (`pause`, `unpause`, `whenNotPaused`) allows for halting operations in critical situations.
- Incentive splits are immutable, preventing unauthorized changes.

## Integration Notes
- The `Farm` contract relies on `ProtocolCore` for governance and certain operational triggers.
- Liquidity is deployed to an external `Strategy` contract, which handles the actual yield generation.
- Yields (potentially in the `asset` token) are converted to `DXP` via an `ILiquidityManager`.
- LPs receive `ClaimToken`s representing their share and accrued yield/bonuses.

---

# vDXP Token Contract

## Overview
The `vDXPToken` contract serves a dual role: it acts as the claim token for the `RootFarm` and as the protocol's primary governance token. It inherits from `BaseClaimToken`, which restricts minting and burning operations, and introduces a cooling period mechanism for governance actions and a transfer fee system that benefits the `RootFarm`.

## Key Features
- **Dual Role**: Functions as both a claim token for `RootFarm` and the protocol's governance token.
- **Cooling Period**: Enforces a delay between token acquisition and the ability to use them for voting or claiming, preventing immediate exploitation after purchase.
- **Transfer Fee Mechanism**: A portion of each token transfer is taken as a fee.
    - This fee is burned from the sender's balance.
    - An equivalent amount of DXP is then unlocked from the `RootFarm`'s locked DXP pool, effectively converting the fee into distributable revenue for `RootFarm` stakers.
- **Restricted Minting/Burning**: Inherits `BaseClaimToken`'s control over mint and burn operations, typically restricted to the `ProtocolCore` or a designated minter.
- **Ownable Administration**: Key parameters like the cooling period can be updated by the contract owner (initially `ProtocolCore`).

## State Variables

### Cooling Logic
```solidity
mapping(address => uint256) public lastAcquireTimestamp; // Tracks the last time an account acquired vDXP tokens.
uint256 public coolingPeriod; // The duration (in seconds) an account must wait after acquiring tokens before they can be used for voting/claiming.
```

## Key Functions

### Constructor
Initializes the token with its name, symbol, the initial minter address (typically `ProtocolCore`), and the initial cooling period.
```solidity
constructor(
    string memory _name,
    string memory _symbol,
    address _minter,
    uint256 _coolingPeriod
) BaseClaimToken(_name, _symbol, _minter) Ownable(msg.sender)
```

### `setCoolingPeriod(uint256 _newPeriod)`
Allows the contract owner to update the global cooling period.
```solidity
function setCoolingPeriod(uint256 _newPeriod) external onlyOwner
```

### `transfer(address recipient, uint256 amount)`
Overrides the standard ERC20 transfer function to implement the fee mechanism. A fee is deducted, burned, and then signaled to `RootFarm` to unlock DXP. The net amount is transferred, and the recipient's `lastAcquireTimestamp` is updated.
```solidity
function transfer(address recipient, uint256 amount) public virtual override returns (bool)
```

### `transferFrom(address sender, address recipient, uint256 amount)`
Overrides the standard ERC20 `transferFrom` function, applying the same fee and cooling period logic as the `transfer` function.
```solidity
function transferFrom(address sender, address recipient, uint256 amount) public virtual override returns (bool)
```

### `isCooledDown(address user)`
Checks if a user has passed the cooling period since their last token acquisition.
```solidity
function isCooledDown(address user) external view returns (bool)
```

### `canVote(address user)`
An alias for `isCooledDown`, specifically for checking voting eligibility.
```solidity
function canVote(address user) external view returns (bool)
```

### `mint(address to, uint256 amount)`
Overrides `BaseClaimToken`'s mint function. Can only be called by the designated minter. Updates `lastAcquireTimestamp` for the recipient.
```solidity
function mint(address to, uint256 amount) external override
```

### `burn(address from, uint256 amount)`
Overrides `BaseClaimToken`'s burn function. Can only be called by the designated minter.
```solidity
function burn(address from, uint256 amount) external override
```

## Events
```solidity
event CoolingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
event RootFarmUpdated(address oldRootFarm, address newRootFarm); // Note: setRootFarm function not shown in snippet, but event exists.
```

## Security Considerations
- **Minter Control**: Minting and burning are strictly controlled by the `minter` address, inherited from `BaseClaimToken` and typically set to `ProtocolCore`.
- **Ownership**: Administrative functions like `setCoolingPeriod` are `onlyOwner`, ensuring that only authorized entities (e.g., `ProtocolCore` or a governance contract) can modify critical parameters.
- **Transfer Fee Logic**: The fee mechanism involves burning tokens and interacting with `RootFarm`. The interaction `RootFarm(associatedFarm).unlockDXP(fee)` assumes `unlockDXP` is properly permissioned to only be called by `vDXPToken` to prevent unauthorized DXP unlocking.
- **Cooling Period**: This mechanism helps mitigate flash loan governance attacks or rapid accumulation and dumping by requiring a waiting period.

## Integration Notes
- `vDXPToken` is tightly coupled with `RootFarm` for its transfer fee mechanism. The `associatedFarm` address in `BaseClaimToken` must be correctly set to the `RootFarm` instance.
- The `protocolCore` address (inherited from `BaseClaimToken`) is used to fetch the `transferFeeRate`.
- The cooling period affects how quickly users can participate in governance after acquiring tokens.
- As a claim token, its supply and distribution are managed by the `RootFarm` (via `ProtocolCore` as the minter).

---

# FarmFactory Contract

## Overview
The `FarmFactory` contract is responsible for deploying new instances of `Farm` and `RestakeFarm` contracts. It utilizes the `CREATE2` opcode via the `new Contract{salt:...}` pattern, allowing for deterministic deployment addresses based on a provided salt. This factory is owned by the protocol (likely `ProtocolCore` or a governance contract) and ensures that farms are created with consistent initial parameters and ownership.

## Key Features
- **Deterministic Farm Deployment**: Uses `CREATE2` (via `new Contract{salt:...}`) to deploy farms, enabling pre-computation of farm addresses.
- **Farm Types**: Capable of deploying standard `Farm` contracts and specialized `RestakeFarm` contracts.
- **Sequential Farm IDs**: Assigns a unique, incrementing `farmId` to each new farm.
- **Ownership**: The factory itself is `Ownable`, and farm creation functions are restricted to the owner.
- **Parameterization**: Allows the owner to specify all necessary parameters for farm initialization during creation.

## State Variables
```solidity
uint256 public currentFarmId; // Counter for assigning unique IDs to new farms, starts at 1.
```

## Key Functions

### Constructor
Initializes the `FarmFactory` and sets the `currentFarmId` to 1. The deployer of the `FarmFactory` becomes its owner.
```solidity
constructor() Ownable(msg.sender)
```

### `createFarm(...)`
Deploys a new standard `Farm` contract using a provided salt and parameters. The `protocolMaster` for the new farm is set to the owner of the `FarmFactory`.
```solidity
function createFarm(
    bytes32 salt,
    address asset,
    uint256 maturityPeriod,
    uint256 verifierIncentiveSplit,
    uint256 yieldYodaIncentiveSplit,
    uint256 lpIncentiveSplit,
    address strategy,
    address claimToken,
    address farmOwner
) external override onlyOwner returns (uint256 farmId, address farmAddress)
```
- `salt`: A user-provided `bytes32` value combined with `msg.sender` to generate the final salt for `CREATE2`.
- `asset`: The asset token for the farm.
- `maturityPeriod`: The maturity period for LP positions.
- `verifierIncentiveSplit`, `yieldYodaIncentiveSplit`, `lpIncentiveSplit`: Incentive splits for various participants.
- `strategy`: The address of the strategy contract associated with this farm.
- `claimToken`: The address of the claim token contract for this farm.
- `farmOwner`: The designated owner of the newly created farm contract.
- Returns the `farmId` and `farmAddress` of the newly deployed farm.

### `createRestakeFarm(...)`
Deploys a new `RestakeFarm` contract, which has additional functionality related to a `RootFarm`. Similar to `createFarm` but includes a `rootFarmAddress` parameter.
```solidity
function createRestakeFarm(
    bytes32 salt,
    address asset,
    uint256 maturityPeriod,
    uint256 verifierIncentiveSplit,
    uint256 yieldYodaIncentiveSplit,
    uint256 lpIncentiveSplit,
    address strategy,
    address claimToken,
    address farmOwner,
    address rootFarmAddress
) external override onlyOwner returns (uint256 farmId, address farmAddress)
```
- Parameters are similar to `createFarm`, with the addition of:
- `rootFarmAddress`: The address of the `RootFarm` this `RestakeFarm` will interact with.
- Returns the `farmId` and `farmAddress` of the newly deployed restake farm.

## Events
The `FarmFactory` itself does not emit specific events upon farm creation in the provided snippet, but the `Farm` and `RestakeFarm` constructors likely emit their own events (e.g., `FarmDeployed` or similar, though not explicitly shown in their snippets either). The `IFarmFactory` interface might define events that implementations are expected to emit.

## Security Considerations
- **Ownership Control**: All farm creation functions are `onlyOwner`, preventing unauthorized farm deployments. The owner of the `FarmFactory` (e.g., `ProtocolCore`) has sole control over creating new farms.
- **Salt Usage**: The use of `CREATE2` with a salt (`keccak256(abi.encodePacked(msg.sender, salt))`) ensures that farm addresses are deterministic but also tied to the factory's owner and the provided salt. This prevents front-running or address squatting if salts are managed properly.
- **Parameter Validation**: The factory relies on the `Farm` and `RestakeFarm` constructors to validate input parameters. It's crucial that these underlying farm contracts perform necessary checks (e.g., non-zero addresses, valid split percentages).
- **Upgradeability**: The factory itself is not upgradeable by default. If new farm types or creation logic are needed, a new factory would typically be deployed.

## Integration Notes
- The `FarmFactory` is a core component for expanding the protocol with new farming opportunities.
- `ProtocolCore` or a governance contract would typically be the owner of the `FarmFactory` and call its creation functions.
- The `protocolMaster` address passed to the `Farm` and `RestakeFarm` constructors is the `owner()` of the `FarmFactory` itself. This means `ProtocolCore` (if it's the factory owner) becomes the `protocolMaster` for the created farms, allowing it to manage them.
- Users or integrators wishing to predict farm addresses can do so if they know the factory address, the owner's address, and the salt that will be used.

---

# Consensus Contract

## Overview
The `Consensus` contract is a module responsible for managing off-chain consensus rounds related to farm performance. Approved verifiers submit performance scores and benchmark data for specific farms. The contract then calculates an average consensus score and benchmark, which is recorded in the `ProtocolCore` contract. This mechanism is crucial for objective performance assessment and reward distribution.

## Key Features
- **Ephemeral Rounds**: Manages distinct consensus rounds for each farm, identified by a `farmId` and an incrementing `roundId`.
- **Verifier Submissions**: Allows only verifiers approved by `ProtocolCore` to submit scores and benchmark data for a farm's active round.
- **Quorum Requirement**: Requires a minimum number of submissions (`minQuorum`) before a round can be finalized with calculated consensus values.
- **Average Calculation**: Computes the simple average of submitted scores and benchmarks to determine the consensus values.
- **Reporting to ProtocolCore**: Reports the finalized consensus score and benchmark back to `ProtocolCore` for a given farm and round.
- **Ownable Administration**: Critical parameters like `protocolCore` address and `minQuorum` can be updated by the contract owner.

## State Variables
```solidity
IProtocolCore public protocolCore; // Reference to the ProtocolCore contract.
uint256 public minQuorum;         // Minimum number of verifier submissions for finalization.

// farmId => current Round details
mapping(uint256 => Round) public rounds;

// farmId => roundId => verifier => Submission details
mapping(uint256 => mapping(uint256 => mapping(address => Submission))) public submissions;

// Constant for score scaling (1.0 = 1e18)
uint256 public constant MAX_SCORE = 1e18;
```

## Data Structures

### `Round`
Stores information about a specific consensus round for a farm.
```solidity
struct Round {
    uint256 id;         // Unique identifier for the round within a farm.
    uint256 startBlock; // Block number when the round was started.
    bool finalized;     // Flag indicating if the round has been finalized.
}
```

### `Submission`
Stores the data submitted by a verifier for a specific round.
```solidity
struct Submission {
    uint256 score;     // Performance score submitted by the verifier (scaled by 1e18).
    uint256 benchmark; // Benchmark value submitted by the verifier (e.g., basis points).
    bool exists;       // Flag indicating if a submission was made by this verifier for this round.
}
```

## Key Functions

### Constructor
Initializes the `Consensus` contract with the `ProtocolCore` address and the minimum quorum.
```solidity
constructor(address _protocolCore, uint256 _minQuorum) Ownable(msg.sender)
```

### `setProtocolCore(address _core)`
Allows the owner to update the `ProtocolCore` contract address.
```solidity
function setProtocolCore(address _core) external onlyOwner
```

### `setMinQuorum(uint256 _minQuorum)`
Allows the owner to update the minimum quorum required for round finalization.
```solidity
function setMinQuorum(uint256 _minQuorum) external onlyOwner
```

### `startRound(uint256 farmId)`
Starts a new consensus round for the specified `farmId`. Can only be called by the owner if the previous round is finalized or no round exists.
```solidity
function startRound(uint256 farmId) external onlyOwner
```

### `submit(uint256 farmId, uint256 score, uint256 benchmark)`
Allows an approved verifier (checked via `protocolCore.isApprovedVerifier`) to submit their `score` and `benchmark` for the active round of a given `farmId`.
- `score` must be <= `MAX_SCORE` (1e18).
- `benchmark` must be <= 10000 (representing up to 100%).
```solidity
function submit(uint256 farmId, uint256 score, uint256 benchmark) external
```

### `finalizeRound(uint256 farmId)`
Finalizes the active consensus round for a `farmId`. It calculates the average score and benchmark from all valid submissions. If the number of submissions meets `minQuorum`, it records these consensus values in `ProtocolCore`. Otherwise, it finalizes the round with zero values.
Can only be called by the owner.
```solidity
function finalizeRound(uint256 farmId) external onlyOwner
```

## Events
```solidity
event RoundStarted(uint256 indexed farmId, uint256 indexed roundId, uint256 startBlock);
event SubmissionReceived(uint256 indexed farmId, uint256 indexed roundId, address indexed verifier, uint256 score, uint256 benchmark);
event RoundFinalized(uint256 indexed farmId, uint256 indexed roundId, uint256 consensusScore, uint256 consensusBenchmark);
```

## Security Considerations
- **Ownership Control**: Critical functions like starting rounds, finalizing rounds, and setting parameters (`protocolCore`, `minQuorum`) are restricted to the `Ownable` contract owner (likely `ProtocolCore` or a governance entity).
- **Verifier Authorization**: The `submit` function relies on `ProtocolCore` to correctly manage and report `isApprovedVerifier`. Unauthorized submissions are prevented.
- **Data Integrity**: Scores are capped at `MAX_SCORE` and benchmarks at 10000 (100%) to prevent extreme values from skewing averages. Each verifier can only submit once per round.
- **Quorum Mechanism**: The `minQuorum` ensures a minimum level of participation before consensus values are considered valid, preventing a single or few verifiers from dominating the outcome. If quorum is not met, the round is finalized with zero values, indicating a failed consensus for that period.
- **Gas Considerations**: The `finalizeRound` function iterates through all approved verifiers for a farm. If the number of verifiers is very large, this loop could consume significant gas. The list of verifiers is fetched from `ProtocolCore`.

## Integration Notes
- The `Consensus` contract is a critical component for the protocol's decentralized performance verification.
- `ProtocolCore` is responsible for managing the list of approved verifiers for each farm and for initiating consensus rounds via the `startRound` function (as owner of `Consensus`).
- Verifiers (off-chain agents) monitor farm performance and submit their findings via the `submit` function.
- After a round duration, `ProtocolCore` (or an authorized agent) calls `finalizeRound` to compute and record the consensus.
- The recorded consensus score and benchmark in `ProtocolCore` can then be used for reward calculations, strategy adjustments, or other protocol mechanisms.

---

# RootFarm Contract

## Overview
The `RootFarm` is a specialized version of the `Farm` contract, designed specifically for DXP, the protocol's native token. Liquidity Providers (LPs) deposit DXP into the `RootFarm` and receive `vDXP` (the protocol's governance and claim token) on a 1:1 basis. A key feature of the `RootFarm` is its `lockedDXP` mechanism: deposited DXP is initially locked. Fees generated from `vDXP` transfers (as handled by the `vDXPToken` contract) trigger the `unlockDXP` function in `RootFarm`, moving DXP from the locked pool to the `farmRevenueDXP` pool, making it available for distribution as yield to `vDXP` holders.

## Key Features
- **DXP as Principal Asset**: The primary asset for deposits and operations is DXP.
- **1:1 vDXP Minting**: LPs receive `vDXP` tokens equivalent to the amount of DXP they deposit.
- **Locked DXP Mechanism**: All deposited DXP is initially added to a `lockedDXP` pool.
- **DXP Unlocking via vDXP Fees**: The `unlockDXP` function, callable only by the `vDXPToken` contract, transfers DXP from `lockedDXP` to `farmRevenueDXP` when `vDXP` transfer fees are processed. This effectively converts `vDXP` transaction fees into yield for `RootFarm` stakers.
- **No Bonus Logic**: Unlike standard farms, `RootFarm` does not implement DXP bonus issuance or reversal mechanics for deposits/withdrawals, as the primary interaction is DXP for `vDXP`.
- **Early Withdrawal Slash**: A 0.5% slash fee is applied if LPs withdraw DXP before their chosen maturity period. This fee contributes to `farmRevenueDXP`.
- **Inherits Farm Functionality**: Retains core `Farm` features like yield accrual (`accYieldPerShare`), position management, and strategy interaction, but with DXP-specific behavior.

## State Variables
Inherits all state variables from `Farm.sol`, plus:
```solidity
/// @notice Tracks the total DXP that is locked in the farm.
uint256 public lockedDXP;
```
- `farmRevenueDXP` (inherited from `Farm`): Accumulates DXP from unlocked fees and slash fees, available for distribution.

## Key Functions

### Constructor
Initializes the `RootFarm` by calling the base `Farm` constructor with DXP as the asset.
```solidity
constructor(
    uint256 _farmId,
    address _dxpToken, // DXP token address
    uint256 _maturityPeriod,
    uint256 _verifierIncentiveSplit,
    uint256 _yieldYodaIncentiveSplit,
    uint256 _lpIncentiveSplit,
    address _strategy,
    address _protocolMaster,
    address _claimToken, // vDXP token address
    address _farmOwner
) Farm(...)
```

### `provideLiquidity(uint256 amount, uint256 maturity)`
Overrides the base `Farm` function. LPs deposit DXP.
- Transfers DXP from the LP to the `RootFarm`.
- Increases `totalLiquidity` and `lockedDXP` by the deposited amount.
- Updates the LP's position (principal, weighted maturity).
- Mints `vDXP` (the `claimToken`) to the LP in a 1:1 ratio to the DXP deposited.
```solidity
function provideLiquidity(uint256 amount, uint256 maturity) external payable override whenNotPaused nonReentrant
```

### `withdrawLiquidity(uint256 amount, bool returnBonus)`
Overrides the base `Farm` function. LPs withdraw DXP.
- `returnBonus` parameter is unused as `RootFarm` doesn't handle DXP bonuses directly.
- Applies a 0.5% slash fee if withdrawal is before `pos.weightedMaturity`. Slashed DXP is added to `farmRevenueDXP`.
- Updates LP's position and yield debt.
- Burns the corresponding amount of `vDXP` from the LP.
- Decreases `lockedDXP` by the withdrawn principal amount.
- Transfers the net DXP (after any slash fee) back to the LP.
```solidity
function withdrawLiquidity(uint256 amount, bool returnBonus) external override whenNotPaused nonReentrant
```

### `unlockDXP(uint256 amount)`
Callable only by the `claimToken` (i.e., `vDXPToken` contract). This function is triggered by the `vDXPToken` when it processes transfer fees.
- Decreases `lockedDXP` by `amount`.
- Increases `farmRevenueDXP` by `amount`, making these DXP tokens available for yield distribution.
```solidity
function unlockDXP(uint256 amount) external nonReentrant
```

### `addRevenueDXP(uint256 amount)`
Allows the `protocolMaster` to directly add DXP to the `farmRevenueDXP` pool. This can be used for manual revenue injections or other protocol-level distributions.
```solidity
function addRevenueDXP(uint256 amount) external nonReentrant onlyProtocolMaster
```

## Events
Inherits all events from `Farm.sol` such as `LiquidityProvided`, `PrincipalRedeemed`, `SlashFeeApplied`, `PositionUpdated`.
No new events specific to `RootFarm` are defined in the provided snippet, but existing events will reflect DXP-specific operations.

## Security Considerations
- **Inherited Security**: Relies on the security measures implemented in the base `Farm` contract (e.g., `ReentrancyGuard`, access controls).
- **`unlockDXP` Access Control**: Crucially, `unlockDXP` is restricted to `msg.sender == address(claimToken)`. This ensures only the `vDXPToken` contract can trigger the unlocking of DXP, preventing unauthorized draining of the `lockedDXP` pool.
- **DXP Token Integrity**: Assumes the DXP token (`asset`) is a standard, secure ERC20 token.
- **Slash Logic**: The 0.5% slash fee for early withdrawals is a fixed parameter. Changes would require a contract upgrade.

## Integration Notes
- `RootFarm` is central to the protocol's staking and governance mechanism, as `vDXP` (its claim token) is the governance token.
- The `vDXPToken` contract must be correctly configured to call `RootFarm.unlockDXP()` with the fee amounts collected from `vDXP` transfers.
- The `strategy` associated with `RootFarm` would typically involve deploying the locked DXP into productive activities (e.g., market making, lending) to generate underlying yield, which complements the yield from `vDXP` transfer fees.
- Revenue distribution from `farmRevenueDXP` follows the standard `Farm` mechanisms (e.g., `updateYieldAndDistribute`).

---

# RestakeFarm Contract

## Overview
The `RestakeFarm` is a specialized type of `Farm` designed to automate the process of compounding DXP bonuses. Instead of LPs receiving their DXP bonuses directly, the `RestakeFarm` automatically stakes these bonuses into the `RootFarm` on behalf of the LP. In return, the LP is credited with `vDXP` tokens. This mechanism simplifies the restaking process for users and encourages participation in the protocol's governance by increasing `vDXP` holdings.

## Key Features
- **Automatic Bonus Restaking**: DXP bonuses earned by LPs in a `RestakeFarm` are not paid out directly. Instead, they are automatically sent to the `RootFarm` and staked for the LP.
- **vDXP Crediting**: Upon successful restaking of the DXP bonus in `RootFarm`, the LP receives `vDXP` tokens.
- **Inherits Farm Functionality**: Builds upon the standard `Farm` contract, inheriting its core functionalities like liquidity provision, withdrawal, yield accrual, and strategy interaction.
- **Integration with RootFarm**: Directly interacts with a designated `RootFarm` contract to perform the restaking operations.
- **Bonus Reversal Mechanism**: Includes functionality to reverse restaked bonuses, for instance, if an LP withdraws their principal early and forfeits the bonus.

## State Variables
Inherits all state variables from `Farm.sol`, plus:
```solidity
/// @notice Address of the associated RootFarm.
IRootFarm public rootFarm;

/// @notice DXP token interface for bonus transfers.
IDXPToken public dxpToken;
```

## Key Functions

### Constructor
Initializes the `RestakeFarm` by calling the base `Farm` constructor and setting the `RootFarm` address.
```solidity
constructor(
    uint256 _farmId,
    address _asset,
    uint256 _maturityPeriod,
    uint256 _verifierIncentiveSplit,
    uint256 _yieldYodaIncentiveSplit,
    uint256 _lpIncentiveSplit,
    address _strategy,
    address _protocolMaster,
    address _claimToken,
    address _farmOwner,
    address _rootFarm // Address of the RootFarm contract
) Farm(...)
```

### `setDXPToken(address _dxpToken)`
Allows the farm owner to set the address of the DXP token contract. This is necessary for handling bonus DXP.
```solidity
function setDXPToken(address _dxpToken) external onlyFarmOwner
```

### `restakeBonus(address lp, uint256 bonusDXP)`
Called by the farm owner (typically an automated keeper or protocol-controlled account) to process an LP's earned DXP bonus.
- Increases the `RootFarm`'s allowance to spend this contract's DXP.
- Calls `rootFarm.restakeDeposit(lp, bonusDXP)` (this function is assumed to exist on `RootFarm`), which should handle the DXP transfer from this `RestakeFarm` to `RootFarm` and mint `vDXP` to the `lp`.
```solidity
function restakeBonus(address lp, uint256 bonusDXP) external onlyFarmOwner
```

### `reverseRestakedBonus(address lp, uint256 bonusDXP)`
Called by the farm owner to reverse a previously restaked bonus, typically when an LP withdraws early and forfeits their bonus.
- Transfers `bonusDXP` from the `lp`'s wallet to this `RestakeFarm` contract.
- Calls `rootFarm.reverseRestake(lp, bonusDXP)` (this function is assumed to exist on `RootFarm`), which should handle the burning of `vDXP` from the `lp` and return the DXP from `RootFarm` (potentially to this `RestakeFarm` or a designated treasury).
```solidity
function reverseRestakedBonus(address lp, uint256 bonusDXP) external onlyFarmOwner
```

## Events
Inherits all events from `Farm.sol`. No new events specific to `RestakeFarm` are defined in the provided snippet. Events related to bonus distribution in the base `Farm` contract would implicitly signify a restake action in this context.

## Security Considerations
- **Inherited Security**: Relies on the security measures of the base `Farm` contract.
- **Access Control**: `restakeBonus` and `reverseRestakedBonus` are `onlyFarmOwner`, ensuring that only authorized entities can trigger these critical operations. The `farmOwner` needs to be a secure, potentially multi-sig or DAO-controlled, address.
- **RootFarm Interaction**: The security of the restaking process heavily depends on the correct and secure implementation of `restakeDeposit` and `reverseRestake` functions in the `RootFarm` contract. These functions must correctly handle DXP transfers and `vDXP` minting/burning.
- **Allowance Management**: Uses `safeIncreaseAllowance` for DXP transfers to `RootFarm`, which is a good practice.
- **DXP Token Transfer on Reversal**: `reverseRestakedBonus` requires the LP to have sufficient DXP and to have approved this `RestakeFarm` to transfer it. This could be a point of friction or failure if not managed correctly by the LP or off-chain systems.

## Integration Notes
- The `RestakeFarm` is designed for LPs who prefer automated compounding of their DXP rewards into `vDXP`.
- The `farmOwner` of a `RestakeFarm` will likely be an automated system or a privileged role responsible for periodically calling `restakeBonus` for eligible LPs.
- The `RootFarm` contract needs to implement `restakeDeposit(address beneficiary, uint256 amount)` and `reverseRestake(address beneficiary, uint256 amount)` functions that:
    - `restakeDeposit`: Receives DXP from the `RestakeFarm`, locks it, and mints `vDXP` to the `beneficiary`.
    - `reverseRestake`: Burns `vDXP` from the `beneficiary`, unlocks DXP, and potentially returns it to the `RestakeFarm` or a specified address.
- The DXP token address must be correctly set via `setDXPToken` for bonus handling.

---

# Claim Token Contracts

This section covers two related contracts: `BaseClaimToken` (an abstract contract) and `FarmClaimToken` (a concrete implementation).

## BaseClaimToken Contract (`interfaces/BaseClaimToken.sol`)

### Overview
The `BaseClaimToken` is an abstract ERC20 token contract that serves as the foundation for claim tokens issued by Farms within the protocol. When a Liquidity Provider (LP) deposits assets into a Farm, they receive a corresponding amount of a claim token (1:1 against the principal deposited). This token represents their share in the Farm. `BaseClaimToken` includes core logic for minting, burning, and an optional transfer fee mechanism.

### Key Features
- **ERC20 Standard**: Implements the standard ERC20 token interface.
- **Minter-Restricted Operations**: Minting and burning of tokens are restricted to a designated `minter` address, typically the Farm contract that deploys the claim token or the `ProtocolCore`.
- **Associated Farm**: Can be linked to an `associatedFarm` address. This allows the claim token to interact with its parent Farm, for example, to notify it about transfers.
- **Transfer Fee Mechanism**: Implements an optional transfer fee. If a `transferFeeRate` (fetched from `ProtocolCore`) is set, a percentage of the transferred amount is effectively captured by the `associatedFarm`. Instead of sending the fee to a separate receiver, the `BaseClaimToken` calls `onClaimTransfer` on the `associatedFarm`. This allows the Farm to adjust its internal accounting (e.g., `principalReserve`) to reflect that a portion of the underlying principal is now considered revenue/yield rather than an LP's claimable share.
- **Ownable**: Administrative functions like setting the minter or associated farm are restricted to the contract `owner`.

### State Variables
```solidity
/// @notice Address allowed to mint/burn this token (e.g., a Farm or protocol).
address public minter;

/// @notice Address of the associated Farm contract.
address public associatedFarm;

/// @notice Interface to ProtocolCore for fetching configurations like transferFeeRate.
IProtocolCore public protocolCore;
```

### Key Functions

#### Constructor
Initializes the token with a name, symbol, and the initial `minter` address. Also sets `protocolCore` to the `_minter` address, assuming the `ProtocolCore` deploys or is the initial minter.
```solidity
constructor(
    string memory _name,
    string memory _symbol,
    address _minter
) ERC20(_name, _symbol)
```

#### `setMinter(address _minter)`
Allows the `owner` to change the `minter` address.
```solidity
function setMinter(address _minter) external onlyOwner
```

#### `setAssociatedFarm(address _farm)`
Allows the `owner` to set or update the `associatedFarm` address.
```solidity
function setAssociatedFarm(address _farm) external onlyOwner
```

#### `mint(address to, uint256 amount)`
Allows the `minter` to create new tokens and assign them to an address `to`.
```solidity
function mint(address to, uint256 amount) external virtual
```

#### `burn(address from, uint256 amount)`
Allows the `minter` to destroy tokens from an address `from`.
```solidity
function burn(address from, uint256 amount) external virtual
```

#### `transfer(address recipient, uint256 amount)` (Override)
Overrides ERC20 `transfer`. If `transferFeeRate > 0`:
- Calculates the fee.
- Calls `IFarm(associatedFarm).onClaimTransfer(sender, recipient, amount)`.
- Transfers `amount - fee` to the `recipient`.
Otherwise, performs a standard transfer.

#### `transferFrom(address sender, address recipient, uint256 amount)` (Override)
Overrides ERC20 `transferFrom`. Similar fee logic as `transfer`:
- Calculates the fee.
- Calls `IFarm(associatedFarm).onClaimTransfer(sender, recipient, amount)`.
- Transfers `amount - fee` to the `recipient`.
Otherwise, performs a standard transfer from.

### Events
```solidity
event MinterUpdated(address indexed oldMinter, address indexed newMinter);
event AssociatedFarmUpdated(address indexed oldFarm, address indexed newFarm);
// Standard ERC20 events (Transfer, Approval)
```

### Security Considerations
- **Minter Control**: The security of token supply relies on the `minter` address being secure and correctly managed (typically the associated Farm).
- **Owner Privileges**: The `owner` has significant control (setting minter, associated farm). This address must be secure (e.g., a multi-sig or DAO).
- **Associated Farm Interaction**: The call to `associatedFarm.onClaimTransfer()` assumes the Farm contract correctly handles this information. The Farm's `onClaimTransfer` function should be robust and secure.
- **Fee Logic**: The transfer fee mechanism relies on `ProtocolCore.getTransferFeeRate()` providing the correct rate.

## FarmClaimToken Contract (`ClaimToken.sol`)

### Overview
The `FarmClaimToken` is a concrete implementation of `BaseClaimToken`. It serves as a standard claim token for most Farms in the protocol. It does not add significant new logic beyond what `BaseClaimToken` provides but acts as a deployable version.

### Key Features
- **Inherits `BaseClaimToken`**: All features of `BaseClaimToken` are available.
- **Ownable**: The constructor sets `msg.sender` (typically the deploying Farm or Factory) as the `owner`.
- **Customizable**: The contract is minimal, allowing for future farm-specific logic to be added if necessary (e.g., specific transfer restrictions or penalty logic beyond the base transfer fee).

### State Variables
- Inherits all state variables from `BaseClaimToken` and `ERC20`.
- No new state variables are defined in `FarmClaimToken` itself.

### Key Functions

#### Constructor
Initializes the token by calling the `BaseClaimToken` constructor with `_name`, `_symbol`, `_minter`, and also sets the `Ownable` contract's owner to `msg.sender`.
```solidity
constructor(
    string memory _name,
    string memory _symbol,
    address _minter
) BaseClaimToken(_name, _symbol, _minter) Ownable(msg.sender)
```
- All other functions are inherited from `BaseClaimToken` and `ERC20`.

### Events
- Inherits all events from `BaseClaimToken` and `ERC20`.

### Security Considerations
- Primarily inherits the security considerations of `BaseClaimToken`.
- The entity deploying `FarmClaimToken` (and thus becoming its `owner` and initial `minter`) must be trusted and secure.

### Integration Notes
- `FarmClaimToken` (or a similar derivative of `BaseClaimToken` like `vDXPToken`) is typically deployed by a `FarmFactory` or directly by a `Farm` upon its creation.
- The `minter` is set to the Farm contract, allowing the Farm to mint claim tokens to LPs upon deposit and burn them upon withdrawal.
- The `associatedFarm` address should be set to the Farm's address to enable the transfer fee mechanism and other potential interactions.

---

# ERC6909 Multi-Token Standard Implementation

## Overview
This contract (`ERC6909.sol`) provides an implementation of the [EIP-6909: Multi-Token Standard](https://eips.ethereum.org/EIPS/eip-6909). ERC-6909 is an extension of ERC-1155 that allows for more granular approvals. Instead of approving an operator for all token IDs (as in ERC-1155's `setApprovalForAll`), ERC-6909 allows users to approve a spender for specific token IDs and amounts, similar to ERC-20's `approve` mechanism, but extended to multiple token types (IDs) within a single contract.

This standard is useful for scenarios where a contract manages multiple distinct types of fungible tokens or assets, and users need fine-grained control over who can spend which specific token type and how much.

## Key Features
- **Multi-Token Management**: Manages balances for multiple token IDs under a single contract address.
- **ID-Specific Balances**: Tracks balances per owner per token ID (`balanceOf(address owner, uint256 id)`).
- **ID-Specific Allowances**: Allows users to approve a spender for a specific `amount` of a specific token `id` (`approve(address spender, uint256 id, uint256 amount)` and `allowance(address owner, address spender, uint256 id)`).
- **Operator Approvals**: Retains the ERC-1155-style operator approval (`setOperator(address spender, bool approved)` and `isOperator(address owner, address spender)`), allowing an operator to manage all tokens of an owner if approved.
- **Standard Transfer Functions**: Provides `transfer(address receiver, uint256 id, uint256 amount)` and `transferFrom(address sender, address receiver, uint256 id, uint256 amount)` for moving specific token IDs.
- **Minting and Burning**: Includes internal `_mint(address to, uint256 id, uint256 amount)` and `_burn(address from, uint256 id, uint256 amount)` functions for managing token supply, typically controlled by derived contracts.
- **ERC165 Support**: Implements `supportsInterface` for ERC-165 interface detection, specifically advertising support for `IERC6909`.
- **Custom Error Types**: To save gas and provide clearer error messages, `ERC6909.sol` utilizes custom errors like `ERC6909InvalidOperator`, `ERC6909InvalidSpender`, `ERC6909InsufficientAllowance`, and `ERC6909InsufficientBalance`.

### Optional Interface Extensions in `IERC6909.sol`
The `interfaces/IERC6909.sol` file, in addition to the base `IERC6909` interface, also defines optional extensions for metadata and content URIs:

#### `IERC6909Metadata`
This interface extends `IERC6909` to add functions for retrieving metadata about specific token IDs.
```solidity
interface IERC6909Metadata is IERC6909 {
    function name(uint256 id) external view returns (string memory);
    function symbol(uint256 id) external view returns (string memory);
    function decimals(uint256 id) external view returns (uint8);
}
```
- **`name(uint256 id)`**: Returns the name of the token for a given `id`.
- **`symbol(uint256 id)`**: Returns the symbol of the token for a given `id`.
- **`decimals(uint256 id)`**: Returns the number of decimals for the token of a given `id`.

#### `IERC6909ContentURI`
This interface extends `IERC6909` to add functions for retrieving URIs related to the contract and specific token IDs, often used for linking to off-chain metadata (e.g., JSON files for NFTs).
```solidity
interface IERC6909ContentURI is IERC6909 {
    function contractURI() external view returns (string memory);
    function tokenURI(uint256 id) external view returns (string memory);
}
```
- **`contractURI()`**: Returns a URI for the contract itself, potentially pointing to a document describing the contract or collection.
- **`tokenURI(uint256 id)`**: Returns a URI for a specific token `id`, typically pointing to a metadata file for that token.

Implementations of `ERC6909` can choose to implement these interfaces to provide richer features for their tokens.

## State Variables
```solidity
// Mapping from owner => token ID => balance
mapping(address owner => mapping(uint256 id => uint256)) private _balances;

// Mapping from owner => operator => approved status
mapping(address owner => mapping(address operator => bool)) private _operatorApprovals;

// Mapping from owner => spender => token ID => allowance amount
mapping(address owner => mapping(address spender => mapping(uint256 id => uint256))) private _allowances;
```

## Key Functions (as per IERC6909)

### `balanceOf(address owner, uint256 id)`
Returns the balance of token `id` for a given `owner`.

### `allowance(address owner, address spender, uint256 id)`
Returns the amount of token `id` that `spender` is allowed to transfer on behalf of `owner`.

### `isOperator(address owner, address spender)`
Returns `true` if `spender` is approved to manage all of `owner`'s tokens, `false` otherwise.

### `approve(address spender, uint256 id, uint256 amount)`
Approves `spender` to transfer up to `amount` of token `id` on behalf of `msg.sender`.
Emits an `Approval` event.

### `setOperator(address spender, bool approved)`
Approves or revokes `spender` as an operator for all of `msg.sender`'s tokens.
Emits an `OperatorSet` event.

### `transfer(address receiver, uint256 id, uint256 amount)`
Transfers `amount` of token `id` from `msg.sender` to `receiver`.
Emits a `Transfer` event.

### `transferFrom(address sender, address receiver, uint256 id, uint256 amount)`
Transfers `amount` of token `id` from `sender` to `receiver`. The caller (`msg.sender`) must either be `sender`, an approved operator for `sender`, or have a sufficient allowance for the specific token `id` from `sender`.
Emits a `Transfer` event.

## Internal Functions for Supply Management

### `_mint(address to, uint256 id, uint256 amount)`
Internal function to create `amount` of token `id` and assign them to `to`. Emits a `Transfer` event with `from` as `address(0)`.

### `_burn(address from, uint256 id, uint256 amount)`
Internal function to destroy `amount` of token `id` from `from`. Emits a `Transfer` event with `to` as `address(0)`.

### `_transfer(address from, address to, uint256 id, uint256 amount)`
Internal function to move tokens, bypassing approval checks. Used by public transfer functions and can be used by derived contracts for mechanics like fees or slashing.

### `_update(address from, address to, uint256 id, uint256 amount)`
Core virtual internal function that handles balance updates for transfers, mints, and burns. This is the primary function to override for custom logic related to token movements.

### `_approve(address owner, address spender, uint256 id, uint256 amount)`
Internal function to set allowances.

### `_setOperator(address owner, address spender, bool approved)`
Internal function to set operator status.

## Events
```solidity
/// @inheritdoc IERC6909
event Transfer(address indexed operator, address indexed from, address indexed to, uint256 id, uint256 amount);

/// @inheritdoc IERC6909
event Approval(address indexed owner, address indexed spender, uint256 id, uint256 amount);

/// @inheritdoc IERC6909
event OperatorSet(address indexed owner, address indexed operator, bool approved);
```

## Security Considerations
- **Standard Token Risks**: Subject to common token vulnerabilities if not used or extended carefully. Reentrancy is generally not an issue for basic transfers/approvals but can become one if complex logic is added in overrides of `_update` without proper guards.
- **Approval Management**: Users must understand the difference between `approve` (for specific token IDs and amounts) and `setOperator` (for all tokens). Granting operator status is a significant privilege.
- **Zero Address Checks**: The implementation includes checks against sending to or approving the zero address, which is good practice.
- **Arithmetic Safety**: Uses `unchecked` for subtractions where underflow is guarded by prior balance checks. Additions for balances could theoretically overflow if an extremely large amount of a token ID is minted, though this is highly unlikely in practical scenarios.
- **Extensibility**: The `_update` function is virtual and designed for extension. Derived contracts must ensure that any custom logic introduced here is secure.

## Integration Notes
- This `ERC6909.sol` contract provides a base implementation. It would typically be inherited by another contract that defines specific token IDs and manages their minting/burning logic according to the application's needs.
- For example, a DeFi protocol might use different token IDs to represent different types of collateral, LP shares with varying characteristics, or different tranches of a structured product.
- Frontends and other interacting smart contracts need to be aware of the specific token IDs used by the application and query balances/allowances accordingly.

---

# FarmStrategy Interface (`interfaces/FarmStrategy.sol`)

## Overview
The `FarmStrategy` is an abstract contract that defines the standard interface and core functionalities for all yield-generating strategies deployed within the Dexponent Protocol. Any specific strategy implementation (e.g., for Uniswap V3 market-making, lending on Aave, etc.) must inherit from `FarmStrategy`.

Its primary role is to manage the deployment of principal assets from a `Farm` contract into an external, non-custodial yield-generating protocol or mechanism, and to handle the withdrawal of these assets and any accrued rewards back to the `Farm`.

## Key Features
- **Standardized Interface**: Provides a consistent set of functions for Farms to interact with different strategies.
- **Farm Association**: Each strategy is immutably linked to a specific `Farm` contract, which is the only entity authorized to call its critical functions.
- **Asset Agnostic**: Designed to work with both ERC20 tokens and native currency (e.g., ETH) as the principal asset.
- **Non-Custodial**: Strategies are expected to interact with external protocols without taking direct custody of funds beyond what's necessary for the strategy's operation (e.g., LPing in a DEX pool).
- **Reentrancy Protection**: Inherits `ReentrancyGuard` to protect critical functions.
- **Ownership**: Inherits `Ownable` for administrative tasks specific to the strategy, though core operations are restricted to the associated `Farm`.

## State Variables
```solidity
/// @notice The associated Farm contract that interacts with this strategy.
address public immutable farm;

/// @notice The principal asset deployed into the strategy (ERC20 token address, or address(0) for native).
address public asset;
```

## Core Strategy Functions
These functions must be implemented by concrete strategy contracts and are callable only by the associated `farm`.

### `deployLiquidity(uint256 amount)`
Deploys a specified `amount` of the principal `asset` from the Farm into the external strategy. This function is `payable` to handle native assets.
```solidity
function deployLiquidity(uint256 amount) external payable virtual onlyFarm nonReentrant;
```

### `withdrawLiquidity(uint256 amount)`
Withdraws a specified `amount` of the principal `asset` from the strategy back to the Farm.
```solidity
function withdrawLiquidity(uint256 amount) external virtual onlyFarm nonReentrant;
```

### `harvestRewards()`
Harvests yield generated by the strategy. The harvested yield should be in the form of the principal `asset` and is typically sent back to the Farm using the internal `_sendRewardsToFarm` helper.
```solidity
function harvestRewards() external virtual onlyFarm nonReentrant returns (uint256 harvested);
```

## Optional Lifecycle Hooks
These functions provide additional management capabilities and are also callable only by the `farm`.

### `rebalance()`
Allows the strategy to adjust its positions or parameters without a full withdrawal and redeployment. Useful for strategies like concentrated liquidity market making.
```solidity
function rebalance() external virtual onlyFarm nonReentrant;
```

### `emergencyWithdraw()`
Forcefully withdraws all funds managed by the strategy back to the Farm. This is intended for emergency situations.
```solidity
function emergencyWithdraw() external virtual onlyFarm nonReentrant;
```
Internally, this calls `_emergencyWithdrawImpl()`, which concrete strategies must override.

## Internal Helper Functions (for Strategy Developers)

### `_sendRewardsToFarm(uint256 amount)`
Transfers harvested rewards (in the principal `asset`) to the `farm`. Handles both ERC20 and native asset transfers.

### `_emergencyWithdrawImpl()`
Internal virtual function that concrete strategies must override to implement the logic for withdrawing all assets.
```solidity
function _emergencyWithdrawImpl() internal virtual returns (uint256 totalAssets);
```

## Optional Informational Functions
These view functions can be implemented by strategies to provide data about their state.

### `getStrategyTVL()`
Returns the total value locked (TVL) in the strategy, expressed in the principal `asset`.
```solidity
function getStrategyTVL() external view virtual returns (uint256);
```

### `getPendingRewards()`
Returns the amount of pending (unharvested) rewards in the strategy, expressed in the principal `asset`.
```solidity
function getPendingRewards() external view virtual returns (uint256);
```

## Events
```solidity
event LiquidityDeployed(uint256 amount);
event LiquidityWithdrawn(uint256 amount);
event RewardsHarvested(uint256 amount);
event StrategyRebalanced();
event EmergencyWithdrawn(uint256 amount);
```

## Security Considerations
- **`onlyFarm` Modifier**: Critical functions are protected by the `onlyFarm` modifier, ensuring that only the associated Farm contract can instruct the strategy to move funds or change its state.
- **Immutable Farm Address**: The `farm` address is set in the constructor and is immutable, preventing unauthorized changes.
- **Reentrancy Guard**: Protects against reentrancy attacks on core functions.
- **Strategy-Specific Risks**: Each concrete strategy implementation will have its own unique risks depending on the external protocols it interacts with. These must be carefully audited.
- **Asset Handling**: Correct handling of the `asset` (ERC20 or native) is crucial, especially regarding approvals and transfers.

## Integration Notes
- `Farm` contracts deploy and manage `FarmStrategy` instances.
- Strategy developers must inherit from `FarmStrategy` and implement the required virtual functions (`deployLiquidity`, `withdrawLiquidity`, `harvestRewards`, `_emergencyWithdrawImpl`) and optionally the other virtual functions.
- The `constructor` of a concrete strategy must call the `FarmStrategy` constructor, providing the `_farm` and `_asset` addresses.

---

# IBridgeAdapter Interface (`interfaces/IBridgeAdapter.sol`)

## Overview
The `IBridgeAdapter` interface defines a standardized way for the Dexponent Protocol to interact with various underlying cross-chain bridge providers. It abstracts the complexities of different bridge implementations, allowing the protocol to initiate token transfers and send messages across different blockchain networks through a consistent API. This is crucial for functionalities like cross-chain deposits into Farms or synchronized governance actions.

## Key Features
- **Bridge Agnostic**: Designed to support multiple bridge providers (e.g., Across, Axelar, Connext) through a unified interface.
- **Token Bridging**: Facilitates transferring tokens (both ERC20 and native) from a source chain to a destination chain.
    - `depositToChain`: For bridging assets from any supported chain into the protocol (e.g., to a Farm on the core chain).
    - `withdrawToUser`: For bridging assets from the protocol (e.g., from a Farm on the core chain) out to a user on another chain.
- **Cross-Chain Messaging**: Allows sending arbitrary messages (calldata) to a target contract on a destination chain, typically for state synchronization or governance.
- **Standardized Events**: Emits common events (`TokenBridgeInitiated`, `CrossChainMessageSent`) for off-chain monitoring and tracking of cross-chain operations.

## Enum: `BridgeProvider`
Defines the supported bridge providers that the adapter can use.
```solidity
enum BridgeProvider {
    None,
    Across,
    Axelar,
    Connext
}
```

## Key Functions

### `depositToChain(...)`
Initiates a token transfer from the current chain to a specified `destinationChainId`, targeting a `recipient` address. This function is `payable` to handle native asset bridging. It includes parameters that might be specific to certain bridge providers (like Across V3's `outputAmount`, `quoteTimestamp`, `fillDeadline`, etc.).
```solidity
function depositToChain(
    address token,
    uint256 amount,
    uint256 destinationChainId,
    address recipient,
    uint256 outputAmount,     // Across specific
    uint32 quoteTimestamp,    // Across specific
    uint32 fillDeadline,      // Across specific
    address exclusiveRelayer, // Across specific
    uint32 exclusivityDeadline // Across specific
) external payable;
```

### `withdrawToUser(...)`
Initiates a token transfer from the current chain (presumably the core chain where protocol funds are managed) to a `userRecipient` on a `destinationChainId`. Similar to `depositToChain`, it's `payable` and includes bridge-specific parameters.
```solidity
function withdrawToUser(
    address token,
    uint256 amount,
    uint256 destinationChainId,
    address userRecipient,
    uint256 outputAmount,     // Across specific
    uint32 quoteTimestamp,    // Across specific
    uint32 fillDeadline,      // Across specific
    address exclusiveRelayer, // Across specific
    uint32 exclusivityDeadline // Across specific
) external payable;
```

### `sendMessageToChain(...)`
Sends a generic message (`messageData`) to a `targetContract` on a `destinationChainId` using a specified `BridgeProvider`. This is intended for operations like cross-chain governance proposals or data synchronization, not direct user fund transfers. This function is also `payable` to cover potential message-sending fees.
```solidity
function sendMessageToChain(
    uint256 destinationChainId,
    address targetContract,
    bytes calldata messageData,
    BridgeProvider provider
) external payable;
```

## Events

### `TokenBridgeInitiated`
Emitted when a token bridging operation (either `depositToChain` or `withdrawToUser`) is initiated.
```solidity
event TokenBridgeInitiated(
    address indexed user,           // Initiator or ultimate beneficiary
    uint256 indexed originChain,
    uint256 indexed destinationChain,
    address token,
    uint256 amount,
    BridgeProvider bridgeUsed,
    bytes32 bridgeTxId              // Transaction ID or reference from the underlying bridge
);
```

### `CrossChainMessageSent`
Emitted when `sendMessageToChain` is successfully called.
```solidity
event CrossChainMessageSent(
    address indexed sender,         // Contract initiating the message
    uint256 indexed destinationChain,
    address indexed targetContract, // Contract on destination chain to receive message
    bytes32 messageId               // Unique ID for the message
);
```

## Integration Notes
- A concrete implementation of `IBridgeAdapter` will be deployed, which routes calls to the appropriate underlying bridge provider based on availability, cost, or user preference.
- The `ProtocolCore` or other high-level protocol contracts would interact with this `IBridgeAdapter` to perform cross-chain operations.
- Users or other contracts calling `depositToChain` or `withdrawToUser` must approve the `IBridgeAdapter` contract to spend their ERC20 tokens if `token` is not `address(0)`.
- The `payable` nature of the functions implies that the adapter might need to pay fees to the underlying bridge providers, which would be covered by `msg.value`.
- Security of cross-chain operations heavily relies on the security of the chosen underlying `BridgeProvider`. The adapter itself acts as an abstraction layer.

---

# ILiquidityManager Interface (`interfaces/ILiquidityManager.sol`)

## Overview
The `ILiquidityManager` interface provides a standardized set of functions for interacting with automated market makers (AMMs) or other decentralized exchanges (DEXes). It abstracts the underlying DEX (e.g., Uniswap v3, or a fallback/proprietary DEX) and allows other protocol contracts, particularly `FarmStrategy` implementations, to manage liquidity, perform token swaps, harvest trading fees, and query price information through a consistent API.

## Key Features
- **DEX Abstraction**: Hides the specific implementation details of the underlying liquidity pools.
- **Pool Management**: Functions to create liquidity pools (`createPool`).
- **Liquidity Operations**: Functions to add (`addLiquidity`) and remove (`removeLiquidity`) liquidity from pools.
- **Token Swaps**: A generic `swap` function to trade one token for another.
- **Fee Handling**: Functions to harvest accrued trading fees (`harvestFees`) and query pending fees (`getPendingFees`).
- **Price Oracles**: 
    - `getTwapPrice`: Provides Time-Weighted Average Prices for a token pair from a Uniswap v3-like pool.
    - `getBestSwapAmountOut`: Calculates the optimal output for a swap, potentially considering direct and multi-hop routes.

## Key Functions

### `createPool(...)`
Creates a liquidity pool for `tokenA` and `tokenB` if one doesn't already exist. It can specify Uniswap v3 fee tiers and initial price, or indicate a stable pool for fallback DEXes.
```solidity
function createPool(
    address tokenA,
    address tokenB,
    uint24 uniFee,          // Uniswap v3 fee tier
    uint160 sqrtPriceX96,   // Initial sqrtPrice for Uniswap v3
    bool stable             // For fallback stable pools
) external returns (address poolAddress);
```

### `addLiquidity(...)`
Adds liquidity to a specified pool for `tokenA` and `tokenB`. It takes desired and minimum amounts for slippage control.
```solidity
function addLiquidity(
    address tokenA,
    address tokenB,
    uint24 uniFee,
    bool stable,
    uint256 amountADesired,
    uint256 amountBDesired,
    uint256 amountAMin,
    uint256 amountBMin
) external;
```

### `removeLiquidity(...)`
Removes a specified `liquidityAmount` from a pool defined by `tokenA`, `tokenB`, and `uniFee`.
Returns the amounts of the two tokens received.
```solidity
function removeLiquidity(
    address tokenA,
    address tokenB,
    uint24 uniFee,
    uint256 liquidityAmount
) external returns (uint256 dxpAmount, uint256 usdcAmount); // Example return tokens
```

### `swap(...)`
Swaps a given `amountIn` of `tokenIn` for `tokenOut`, sending the output to `recipient`.
```solidity
function swap(
    address tokenIn,
    address tokenOut,
    uint256 amountIn,
    address recipient
) external returns (uint256 amountOut);
```

### `harvestFees(address poolAddress)`
Collects accrued trading fees from the specified `poolAddress`.
Returns the amounts of fees collected for two predefined fee tokens (e.g., USDC and DXP).
```solidity
function harvestFees(address poolAddress) external returns (uint256 usdcFees, uint256 dxpFees);
```

### `getPendingFees(address poolAddress)`
Returns the total amount of pending (unharvested) fees for a given `poolAddress`.
```solidity
function getPendingFees(address poolAddress) external view returns (uint256 pendingFees);
```

### `getTwapPrice(...)`
Returns the Time-Weighted Average Price of `tokenA` in terms of `tokenB` over a specified `interval` from a Uniswap v3 pool.
```solidity
function getTwapPrice(
    address tokenA,
    address tokenB,
    uint24 uniFee,
    uint32 interval
) external view returns (uint256 priceX96); // Price in Q64.96 format
```

### `getBestSwapAmountOut(...)`
Calculates the best possible output amount for swapping `amountIn` of `tokenIn` to `tokenOut`. It may consider different routing options (e.g., direct swap vs. two-hop swap via a base stable token).
```solidity
function getBestSwapAmountOut(
    address tokenIn,
    address tokenOut,
    uint256 amountIn
) external view returns (uint256 bestAmountOut, uint8 bestRoute);
```

## Integration Notes
- A concrete implementation of `ILiquidityManager` will be deployed, which interacts with the chosen DEX(es) (e.g., Uniswap v3, Curve, or custom pools).
- `FarmStrategy` contracts are likely primary users of this interface to deploy assets into liquidity pools, manage those positions, and execute trades as part of their yield-generating activities.
- Other protocol components might use it for oracle price feeds (`getTwapPrice`, `getBestSwapAmountOut`) or for programmatic token swaps.
- Callers performing operations like `addLiquidity` or `swap` must ensure the `ILiquidityManager` contract (or the underlying DEX router it uses) is approved to spend their tokens.
- The interface design suggests flexibility in supporting different types of AMMs, including those with different fee structures or pool types (e.g., `stable` flag).

---

# ERC6909TokenSupply Extension (`interfaces/extensions/ERC6909TokenSupply.sol`)

## Overview
The `ERC6909TokenSupply` contract is an extension of the base `ERC6909` multi-token standard implementation. Its purpose is to add functionality for tracking the total supply of each individual token ID managed by an ERC6909-compliant contract. This is analogous to the `totalSupply()` function in the ERC20 standard but applied on a per-token-ID basis for multi-token contracts.

This contract inherits from `ERC6909` and implements `IERC6909TokenSupply` (which would be part of the ERC6909 EIP's optional extensions).

## Key Features
- **Inherits ERC6909**: Builds upon the standard ERC6909 functionalities for balances, approvals, and transfers.
- **Per-ID Total Supply**: Maintains a separate `totalSupply` for each token ID.
- **Automatic Supply Updates**: Overrides the internal `_update` function of `ERC6909` to automatically adjust the total supply of a token ID whenever tokens of that ID are minted (transferred from `address(0)`) or burned (transferred to `address(0)`).

## State Variables
```solidity
// Mapping from token ID => total supply of that token ID
mapping(uint256 id => uint256) private _totalSupplies;
```

## Key Functions

### `totalSupply(uint256 id)`
Returns the total supply of the token specified by `id`.
```solidity
function totalSupply(uint256 id) public view virtual override returns (uint256);
```

### `_update(address from, address to, uint256 id, uint256 amount)` (Override)
This internal function, inherited from `ERC6909`, is overridden to include total supply accounting.
- When `from` is `address(0)` (minting), it increases `_totalSupplies[id]` by `amount`.
- When `to` is `address(0)` (burning), it decreases `_totalSupplies[id]` by `amount`.
It calls `super._update()` to ensure the original ERC6909 balance update logic is also executed.

## Security Considerations
- **Correctness of `_update` Override**: The security and accuracy of total supply tracking depend on the correct implementation of the `_update` override. The provided implementation correctly handles additions for mints and subtractions for burns.
- **Arithmetic Safety**: The subtraction for burns uses `unchecked` block, assuming that the amount burned will not exceed the existing total supply (as `amount <= _balances[id][from] <= _totalSupplies[id]`). This is a standard and safe assumption if the base ERC6909 logic prevents burning more tokens than an account holds.
- **Composability**: When this contract is further inherited, any child contract overriding `_update` again must ensure it calls `super._update()` to maintain the supply tracking logic from `ERC6909TokenSupply`.

## Integration Notes
- Contracts that require tracking the total supply of individual token IDs within an ERC6909 context can inherit from `ERC6909TokenSupply` instead of directly from `ERC6909`.
- This provides a standardized way to query the supply of each token ID, which can be useful for frontends, analytics, or other smart contracts that need this information.
- It complements the base ERC6909 standard by adding a feature commonly found in single-token standards like ERC20.

---

# BonusCalculationLib (`libraries/BonusCalculationLib.sol`)

## Overview
`BonusCalculationLib` is a Solidity library that encapsulates the mathematical logic for calculating deposit bonuses within the Dexponent Protocol. It provides pure functions that can be used by other contracts (likely `Farm` or `ProtocolCore`) to determine expected yields and the corresponding DXP bonuses for user deposits.

## Key Features
- **Yield Calculation**: Computes the expected yield on a deposit based on principal amount, benchmark yield percentage, and deposit duration.
- **Yield Conversion**: Converts the calculated yield from principal token units to DXP token units using a provided price.
- **Bonus Computation**: Calculates the final DXP bonus amount based on the DXP yield and a specified bonus ratio.
- **Gas Efficiency**: As a library with internal pure functions, it's designed to be gas-efficient when used by other contracts.

## Functions

### `computeExpectedYield(uint256 principal, uint256 benchYield, uint256 depositMaturity)`
Calculates the expected yield in terms of the principal token.
- **Parameters**:
    - `principal`: The user's deposit amount (in principal token units).
    - `benchYield`: The benchmark yield percentage (e.g., `10` for 10%).
    - `depositMaturity`: The chosen deposit maturity period in seconds.
- **Returns**: `expectedYield` (uint256) - The calculated yield in principal token units.
- **Formula**: `(principal * benchYield * depositMaturity) / (100 * 365 days)`
```solidity
function computeExpectedYield(
    uint256 principal,
    uint256 benchYield,
    uint256 depositMaturity
) internal pure returns (uint256 expectedYield);
```

### `convertYieldToDXP(uint256 expectedYield, uint256 priceScaled)`
Converts an expected yield (denominated in principal units) into an equivalent amount of DXP tokens.
- **Parameters**:
    - `expectedYield`: The yield amount in principal token units (output from `computeExpectedYield`).
    - `priceScaled`: The price of DXP in terms of the principal token, scaled (e.g., if 1 DXP = X principal units, `priceScaled` represents X with appropriate decimal scaling, typically 1e18). If `priceScaled` is `0`, a fallback of `1e18` (1 DXP = 1 principal unit) is used.
- **Returns**: `yieldInDXP` (uint256) - The yield denominated in DXP tokens.
- **Formula**: `(expectedYield * 1e18) / priceScaled`
```solidity
function convertYieldToDXP(
    uint256 expectedYield,
    uint256 priceScaled
) internal pure returns (uint256 yieldInDXP);
```

### `computeDepositBonus(uint256 yieldInDXP, uint256 depositBonusRatio)`
Calculates the actual deposit bonus in DXP tokens based on the DXP-denominated yield and a bonus ratio.
- **Parameters**:
    - `yieldInDXP`: The yield amount in DXP tokens (output from `convertYieldToDXP`).
    - `depositBonusRatio`: The bonus ratio as a percentage (e.g., `70` for 70%).
- **Returns**: `bonusDXP` (uint256) - The final deposit bonus amount in DXP tokens.
- **Formula**: `(yieldInDXP * depositBonusRatio) / 100`
```solidity
function computeDepositBonus(
    uint256 yieldInDXP,
    uint256 depositBonusRatio
) internal pure returns (uint256 bonusDXP);
```

## Integration Notes
- This library's functions are `internal pure`, meaning they can be called directly from other contracts without deploying an instance of the library (the bytecode is embedded in the calling contract).
- It is likely used by contracts managing user deposits and DXP reward distribution, such as `Farm` contracts or the `ProtocolCore`.
- The accuracy of bonus calculations depends on the accuracy of the `benchYield`, `priceScaled`, and `depositBonusRatio` parameters provided by the calling contracts.
- The `365 days` constant in `computeExpectedYield` implies an annualization based on a 365-day year.

---

# BridgingAdapter Implementation (`libraries/BridgeAdaptor.sol`)

## Overview
The `BridgingAdapter` contract is the concrete implementation of the cross-chain bridging and messaging abstraction layer for the Dexponent Protocol. It builds upon the `IBridgeAdapter` interface (though not explicitly inheriting it in the provided snippet, its function signatures match) and provides the actual logic for interacting with various underlying bridge providers like Across, Axelar, and Connext. The contract is `Ownable`, allowing a designated owner (e.g., governance) to configure its operational parameters.

Note: The filename is `BridgeAdaptor.sol` while the contract name is `BridgingAdapter`.

## Key Features
- **Multi-Bridge Support**: Designed to interact with multiple bridge providers (Across, Axelar, Connext).
- **Configurable Routing**: The owner can define preferred bridge providers for specific token and destination chain pairs (`bridgeRoute` mapping).
- **Token Management**: The owner can whitelist tokens allowed for bridging (`tokenAllowed` mapping).
- **Provider-Specific Configurations**: Stores and allows updates for addresses of external bridge contracts (e.g., `acrossSpokePool`, `axelarGateway`, `connext`) and provider-specific parameters (e.g., `axelarTokenSymbol`, `axelarChainName`, `connextDomainId`).
- **Access Control**: Critical functions like `withdrawToUser` and `sendMessageToChain` can be restricted to `allowedCaller` addresses (e.g., core protocol contracts) in addition to the owner.
- **Native Token Handling**: Supports bridging of native assets by internally wrapping them into their ERC20 equivalents (e.g., WETH) using a configured `wrappedNativeToken` address.
- **Event Emission**: Emits detailed events (`TokenBridgeInitiated`, `CrossChainMessageSent`, etc.) for off-chain monitoring and relaying.
- **Safety**: Utilizes `SafeERC20` for token interactions and includes mechanisms like clearing approvals after use.

## State Variables
- `acrossSpokePool`, `axelarGateway`, `axelarGasService`, `connext`, `lifiDiamond`, `wrappedNativeToken`: Addresses of external bridge provider contracts.
- `bridgeRoute`: `mapping(address token => mapping(uint256 destinationChainId => BridgeProvider))` - Defines the preferred bridge provider for a token to a destination chain.
- `tokenAllowed`: `mapping(address token => bool)` - Marks tokens as allowed for bridging.
- `axelarTokenSymbol`: `mapping(address token => string)` - Maps local token addresses to their Axelar network symbol.
- `axelarChainName`: `mapping(uint256 chainId => string)` - Maps EVM chain IDs to Axelar chain name strings.
- `connextDomainId`: `mapping(uint256 chainId => uint32)` - Maps EVM chain IDs to Connext domain IDs.
- `allowedCaller`: `mapping(address => bool)` - Addresses authorized to call restricted functions.

## Key Functions

### Owner Configuration Functions
- `setBridgeRoute(address token, uint256 destChainId, BridgeProvider provider)`: Sets the preferred bridge provider for a token and destination chain.
- `setTokenAllowed(address token, bool allowed)`: Allows or disallows a token for bridging.
- `setExternalAddresses(...)`: Updates the addresses of the various bridge provider contracts.
- `setAxelarTokenSymbol(address token, string calldata symbol)`: Sets the Axelar symbol for a token.
- `setAxelarChainName(uint256 chainId, string calldata name)`: Sets the Axelar chain name for a chain ID.
- `setConnextDomainId(uint256 chainId, uint32 domainId)`: Sets the Connext domain ID for a chain ID.
- `setAllowedCaller(address caller, bool allowed)`: Authorizes or revokes an address for calling restricted functions.

### Core Bridging and Messaging Functions
These functions generally align with the `IBridgeAdapter` interface.
- **`depositToChain(...) payable`**: Initiates a token transfer from the current chain to a destination chain. Internally calls `_performTokenBridge`.
- **`withdrawToUser(...) payable`**: Initiates a token transfer from the current chain to a user on a destination chain. Requires caller to be owner or an `allowedCaller`. Internally calls `_performTokenBridge`.
- **`sendMessageToChain(uint256 destinationChainId, address targetContract, bytes calldata messageData, BridgeProvider provider) payable`**: Sends a message to a target contract on a destination chain using either Axelar or Connext. Requires caller to be owner or an `allowedCaller`.

### Internal Bridging Logic: `_performTokenBridge(...)`
This internal function is the core of token bridging operations. It:
1. Checks if the token is allowed and if a route is configured.
2. Handles native tokens by wrapping them into `wrappedNativeToken` and unwrapping on the other side (implicitly, as bridges handle ERC20s).
3. Based on the `BridgeProvider` determined from `bridgeRoute` (or a default like Across):
    - **Across**: Interacts with `acrossSpokePool` using `depositV3` (for deposits) or potentially other functions for withdrawals. Requires parameters like `outputAmount`, `quoteTimestamp`, `fillDeadline`.
    - **Axelar**: Interacts with `axelarGateway` (e.g., `sendToken` or `callContractWithToken`). Requires Axelar-specific parameters like destination chain name string and token symbol. May involve `axelarGasService` for paying destination gas fees.
    - **Connext**: Interacts with `connext` contract using `xcall`. Requires Connext domain ID for the destination and may use `msg.value` for relayer fees.
4. Approves tokens to the respective bridge contract before the call and clears the approval afterwards.
5. Emits `TokenBridgeInitiated` event.

## Security Considerations
- **Ownership and Configuration**: Security heavily relies on the owner managing configurations (routes, allowed tokens, external contract addresses) correctly and securely.
- **External Bridge Security**: The overall security of bridged assets depends on the security of the underlying bridge providers (Across, Axelar, Connext).
- **Access Control for Sensitive Functions**: `withdrawToUser` and `sendMessageToChain` are protected by `allowedCaller` and `owner` checks, which is crucial.
- **Token Approvals**: Uses `SafeERC20` and clears approvals, which is good practice.
- **Input Validation**: Requires checks for valid routes, allowed tokens, and configured bridge parameters.
- **Native Token Handling**: Correctly wrapping and accounting for native tokens is important.

## Integration Notes
- This contract acts as a central point for all cross-chain bridging and messaging initiated by the Dexponent Protocol.
- Protocol contracts (e.g., `Farm`s, `ProtocolCore`) would call `depositToChain`, `withdrawToUser`, or `sendMessageToChain` on this `BridgingAdapter` instance.
- Off-chain services might monitor the emitted events to track and verify cross-chain transactions.
- Proper and secure configuration by the owner is paramount for the adapter's correct and safe operation.

---

# LiquidityManager Implementation (`libraries/LiquidityManager.sol`)

## Overview
The `LiquidityManager` contract is the concrete implementation of the `ILiquidityManager` interface. It serves as a sophisticated abstraction layer for interacting with various Decentralized Exchanges (DEXes) to manage liquidity, perform swaps, and fetch price information. It is designed to be `Ownable`, typically by a strategy or farm contract within the Dexponent Protocol, which directs its operations.

The contract primarily targets Uniswap V3 for its operations, with built-in fallbacks to Uniswap V2-compatible routers or Aerodrome-style DEXes, depending on the chain and configuration.

## Key Features
- **Multi-DEX Interaction**: Supports Uniswap V3 as the primary DEX and includes logic for fallback interactions with Uniswap V2-like (e.g., Sushiswap) or Aerodrome-style (stable/volatile pools) DEXes.
- **Chain-Specific Configuration**: DEX contract addresses (Uniswap V3 components, fallback routers/factories) are initialized in the constructor based on the `block.chainid`. The provided code includes configurations for Ethereum Mainnet (ID 1) and Arbitrum (ID 42161).
- **Owned Operations**: Most core functions (`createPool`, `addLiquidity`, `removeLiquidity`, `swap`, `harvestFees`) are restricted by `onlyOwner`, ensuring that only the designated protocol contract (e.g., a `FarmStrategy`) can execute these liquidity operations.
- **Uniswap V3 Specialization**: Includes detailed logic for Uniswap V3 operations such as creating pools, minting LP positions (and receiving NFTs via `IERC721Receiver`), managing liquidity within specific tick ranges, collecting fees, and calculating TWAP.
- **Fallback Mechanism**: If Uniswap V3 components are not configured or an operation is better suited for another DEX type, it can use a `fallbackRouter` and `fallbackFactory`.
- **Token Handling**: Utilizes `SafeERC20` for secure token transfers and manages approvals to DEX contracts internally.
- **Price Oracle Functionality**: Provides `getTwapPrice` (leveraging Uniswap V3 pool observations) and `getBestSwapAmountOut` (comparing direct vs. two-hop routes via a `baseStableToken`).

## State Variables
- `uniV3PositionManager`: `IUniswapV3PositionManager` interface for Uniswap V3.
- `uniV3Factory`: `IUniswapV3Factory` interface for Uniswap V3.
- `uniV3Quoter`: `IUniswapV3Quoter` interface for Uniswap V3.
- `defaultUniFee`: Default fee tier for Uniswap V3 pools.
- `fallbackFactory`: Address of the fallback DEX factory (e.g., Uniswap V2 factory or Aerodrome factory).
- `fallbackRouter`: Address of the fallback DEX router (e.g., Uniswap V2 router or Aerodrome router).
- `fallbackUsesStableSwap`: Boolean indicating if the `fallbackRouter` uses Aerodrome's stable/volatile pool logic.
- `baseStableToken`: Address of a common stablecoin (e.g., USDC) used for routing multi-hop swaps.
- `farm`: `immutable address` - The owner contract (typically a strategy or farm contract) that this manager serves.

## Key Functions

### Constructor
- `constructor(address _farm)`: Initializes `Ownable` with `msg.sender` (which should be the deploying strategy/farm), sets the immutable `farm` address, and configures DEX component addresses based on `block.chainid`.

### Pool and Liquidity Management (Owner-Only)
- **`createPool(address tokenA, address tokenB, uint24 uniFee, uint160 sqrtPriceX96, bool stable)`**: Creates a liquidity pool. It first attempts to get/create a Uniswap V3 pool. If not available or applicable, it may use the `fallbackFactory` (distinguishing between standard Uniswap V2 `createPair` and Aerodrome `createPool` with a `stable` flag).
- **`addLiquidity(address tokenA, address tokenB, uint24 uniFee, bool stable, uint256 amountADesired, uint256 amountBDesired, uint256 amountAMin, uint256 amountBMin)`**: Adds liquidity to a pool. Tokens are transferred from the caller (owner). It prioritizes Uniswap V3 (using `uniV3PositionManager.mint`), then falls back to the `fallbackRouter` (handling Uniswap V2 `addLiquidity` or Aerodrome `addLiquidity` with stable/volatile logic).
- **`removeLiquidity(uint256 tokenId, address tokenA, address tokenB, uint24 uniFee, bool stable, uint128 liquidity, uint256 amountAMin, uint256 amountBMin)`**: (Structure inferred from `ILiquidityManager` and common patterns) Removes liquidity. For Uniswap V3, it would use `uniV3PositionManager.decreaseLiquidity` and `uniV3PositionManager.collect`. For fallback DEXes, it would call their respective `removeLiquidity` functions.
- **`harvestFees(uint256 tokenId, address tokenA, address tokenB, uint24 uniFee)`**: (Structure inferred) Collects accumulated fees from a Uniswap V3 position using `uniV3PositionManager.collect`. May not be applicable to fallback DEXes in the same way.

### Swaps (Owner-Only)
- **`swap(address tokenIn, address tokenOut, uint24 fee, bool stablePool, uint256 amountIn, address recipient)`**: Performs a token swap. It attempts a Uniswap V3 swap first (using `uniV3PositionManager` for swaps, though often direct pool interaction or a router is used for swaps). If not, it uses the `fallbackRouter` (handling Uniswap V2 `swapExactTokensForTokens` or Aerodrome `swapExactTokensForTokens` with route construction).

### View Functions (Public)
- **`getPendingFees(uint256 tokenId, address tokenA, address tokenB)`**: (Structure inferred) Retrieves pending fees for a Uniswap V3 LP position.
- **`getTwapPrice(address poolAddress, address tokenIn, address tokenOut, uint32 interval)`**: Calculates the Time-Weighted Average Price from a Uniswap V3 pool using `observe` and `TickMath`.
- **`getBestSwapAmountOut(address tokenIn, address tokenOut, uint256 amountIn)`**: Determines the best possible output amount for a swap by comparing a direct route with a two-hop route via `baseStableToken`, using `uniV3Quoter` or the `fallbackRouter` for quotes.

### IERC721Receiver
- **`onERC721Received(...)`**: Standard implementation to allow the contract to receive ERC721 tokens, specifically Uniswap V3 LP NFTs.

## Security Considerations
- **Ownership**: As critical functions are `onlyOwner`, the security of the owning contract (the `farm` or strategy) is paramount. Compromise of the owner would lead to loss of funds managed by this `LiquidityManager`.
- **DEX Security**: The security of operations also depends on the security of the underlying DEX contracts (Uniswap V3, Uniswap V2, Aerodrome, etc.).
- **Correct Configuration**: Chain-specific addresses for DEX components must be correct and kept up-to-date. Incorrect addresses could lead to failed transactions or loss of funds.
- **Token Approvals**: The contract manages token approvals to DEXes. While it uses `SafeERC20` and clears approvals where appropriate, the logic must be flawless.
- **Slippage**: For swaps and liquidity provision, while not explicitly detailed in the provided outline for all functions, proper slippage protection would typically be handled by the calling owner contract by setting `amountMin` parameters appropriately.

## Integration Notes
- This `LiquidityManager` is designed to be a core component used by Dexponent Protocol's strategy contracts.
- Strategy contracts would deploy and own an instance of `LiquidityManager`, then call its functions to manage LP positions and execute trades according to their strategy logic.
- The `farm` address passed in the constructor is crucial as it's often the recipient of LP tokens/NFTs or withdrawn assets.
- The chain-specific DEX addresses mean this contract is deployable across multiple EVM chains where these DEXes exist.

---

# TickMath Library (`libraries/TickMath.sol`)

## Overview
`TickMath.sol` is a utility library providing mathematical functions essential for working with Uniswap V3's tick-based system for concentrated liquidity. Ticks represent discrete price points in Uniswap V3, and this library allows for conversion between these ticks and their corresponding square root price ratios (sqrtPriceX96).

The calculations are based on the formula `price = 1.0001^tick`, and `sqrtPriceX96` is a fixed-point Q64.96 representation of `sqrt(price)`. This library is a fundamental building block for any contract interacting with Uniswap V3 pools at a low level, such as the `LiquidityManager`.

The implementation appears to be a direct adaptation or port of Uniswap V3's official `TickMath` library.

## Key Features
- **Tick to SqrtPriceX96 Conversion**: Calculates the `sqrtPriceX96` for a given tick.
- **SqrtPriceX96 to Tick Conversion**: Calculates the tick corresponding to a given `sqrtPriceX96`.
- **Fixed-Point Arithmetic**: Uses Q64.96 fixed-point numbers for `sqrtPriceX96` values.
- **Constant Definitions**: Defines `MIN_TICK`, `MAX_TICK`, `MIN_SQRT_RATIO`, and `MAX_SQRT_RATIO` which represent the valid boundaries for ticks and their corresponding sqrt price ratios in Uniswap V3.

## Constants
- **`MIN_TICK = -887272`**: The minimum allowable tick value.
- **`MAX_TICK = 887272`**: The maximum allowable tick value.
- **`MIN_SQRT_RATIO = 4295128739`**: The minimum `sqrtPriceX96` value, corresponding to `MIN_TICK`.
- **`MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342`**: The maximum `sqrtPriceX96` value, corresponding to `MAX_TICK`.

## Core Functions

### `getSqrtRatioAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96)`
- **Purpose**: Calculates `sqrt(1.0001^tick) * 2^96`.
- **Parameters**:
    - `tick`: The input tick (an `int24` value).
- **Returns**: `sqrtPriceX96` (a `uint160` value) representing the square root of the price ratio at the given tick, scaled as a Q64.96 fixed-point number.
- **Constraints**: Throws an error if the absolute value of `tick` exceeds `MAX_TICK`.

### `getTickAtSqrtRatio(uint160 sqrtPriceX96) internal pure returns (int24 tick)`
- **Purpose**: Calculates the greatest tick value such that `getSqrtRatioAtTick(tick) <= sqrtPriceX96`.
- **Parameters**:
    - `sqrtPriceX96`: The input square root price ratio (a `uint160` Q64.96 number).
- **Returns**: `tick` (an `int24` value) representing the tick corresponding to the input `sqrtPriceX96`.
- **Constraints**: Throws an error if `sqrtPriceX96` is outside the range `[MIN_SQRT_RATIO, MAX_SQRT_RATIO)`.

## Usage
This library is typically used internally by contracts that need to:
- Determine the price range of a Uniswap V3 liquidity position.
- Calculate prices for swaps based on current tick or target ticks.
- Convert between price representations and tick indices when interacting with Uniswap V3 pools.

The `LiquidityManager` contract in the Dexponent Protocol uses this library for its Uniswap V3 interactions.

## Security Considerations
- As a math library performing complex fixed-point arithmetic, the correctness of its implementation is critical. Given its likely origin from Uniswap V3 core contracts, it is generally considered well-audited and robust.
- Callers should ensure that inputs (`tick` or `sqrtPriceX96`) are within the valid ranges defined by the constants to avoid reversions.