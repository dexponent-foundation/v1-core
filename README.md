# v1-core
Core Contracts of Dexponent Protocol V1

## Core Contracts

This section provides an overview of the primary smart contracts within the Dexponent Protocol V1.

### `ClaimToken.sol` (Contract: `FarmClaimToken`)
Represents a share of an LP's principal deposited into a specific Farm. It's an ERC20 token, typically minted/burned by its associated Farm. Can include custom logic like early withdrawal penalties.

### `Consensus.sol` (Contract: `Consensus`)
Manages consensus rounds for farm performance verification. Verifiers submit scores and benchmark data. The contract computes averages and reports them to the `ProtocolCore` after reaching a minimum quorum.

### `DXPToken.sol` (Contract: `DXPToken`)
The native ERC20 token (DXP) of the Dexponent protocol. It includes logic for token emissions (halving schedule) and vesting schedules for token distribution, utilizing a `VestingComponent` for cliff and linear vesting.

### `ERC6909.sol` (Contract: `ERC6909`)
An implementation of the ERC-6909 multi-token standard, allowing a single contract to manage multiple distinct fungible token types, each identified by an ID.

### `Farm.sol` (Contract: `Farm`)
A base contract for yield-generating farms. It handles LP deposits, tracks liquidity, manages yield accrual, and distributes incentives. Interacts with `Strategy` contracts (for deploying liquidity), `ClaimToken` (for LP shares), and `ProtocolCore`.

### `FarmFactory.sol` (Contract: `FarmFactory`)
A factory contract for deploying new `Farm` and `RestakeFarm` instances using `CREATE2` for deterministic address generation.

### `ProtocolCore.sol` (Contract: `ProtocolCore`)
The central registry and orchestrator for the Dexponent protocol. It manages farm registrations, benchmark yields, LP deposit bonuses, verifier staking, consensus results, and DXP token emissions.

### `RestakeFarm.sol` (Contract: `RestakeFarm`)
A specialized `Farm` where DXP bonuses earned by LPs are automatically restaked into the `RootFarm`. LPs receive `vDXP` (the `RootFarm`'s claim token) in return.

### `RootFarm.sol` (Contract: `RootFarm`)
A unique `Farm` where the principal asset is DXP. LPs deposit DXP and receive `vDXP` (its claim token) 1:1. Deposited DXP is locked, and fees from `vDXP` transfers can unlock DXP from this pool, making it available as revenue.

### `vDXPToken.sol` (Contract: `vDXPToken`)
Serves as the claim token for the `RootFarm` and the protocol's governance token. It features a cooling-off period for users and a transfer fee mechanism where a portion of transferred `vDXP` is burned, and an equivalent amount of DXP is unlocked in the `RootFarm` as revenue.
