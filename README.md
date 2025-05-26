# v1-core
Core Contracts of Dexponent Protocol V1

## Protocol Architecture

### Core Components

The Dexponent Protocol is built around several key components that work together to create a robust yield generation ecosystem:

- **Sharpe Consensus**: Provides the foundation for reliable performance evaluation and benchmarking in a peer-to-peer yield generation ecosystem.
- **Farm Management**: Handles liquidity provisioning and yield distribution
- **Tokenomics**: Manages DXP emissions, vesting, and governance mechanisms

## Core Contracts

This section provides an overview of the primary smart contracts within the Dexponent Protocol V1.

### `ClaimToken.sol` (Contract: `FarmClaimToken`)
Represents a share of an LP's principal deposited into a specific Farm. It's an ERC20 token, typically minted/burned by its associated Farm. Can include custom logic like early withdrawal penalties.

## Sharpe Consensus Mechanism

Dexponent Protocol implements Sharpe Consensus, a sophisticated Byzantine fault-tolerant mechanism that ensures transparent and accurate performance metrics for yield-generating strategies. This system harmonizes the protocol's operations by providing reliable farm scoring and benchmarking.

### Key Features

- **Farm Scoring Algorithm**: Evaluates strategies based on multiple factors including normalized yield, volume-weighted performance, and risk-adjusted returns
- **Risk Assessment**: Implements Sortino ratio-inspired metrics to evaluate downside risk and reward consistency
- **Dynamic Benchmarking**: Establishes objective performance standards by analyzing historical data and current market conditions
- **Verifiable Performance**: Ensures transparent and tamper-resistant metrics through decentralized verification

### `Consensus.sol` (Contract: `Consensus`)
Manages consensus rounds for farm performance verification, implementing the core logic of Sharpe Consensus. The contract processes verifier-submitted scores and benchmark data, computing weighted averages while ensuring data integrity. It enforces minimum quorum requirements before reporting to `ProtocolCore`, playing a critical role in maintaining the protocol's performance evaluation standards.

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
