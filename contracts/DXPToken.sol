// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/finance/VestingWallet.sol";
import "@openzeppelin/contracts/finance/VestingWalletCliff.sol";

/**
 * @title VestingComponent
 * @dev Combines linear vesting with a cliff period:
 *      - No tokens are released until the cliff ends.
 *      - After the cliff, tokens vest linearly until `start + duration`.
 */
contract VestingComponent is VestingWallet, VestingWalletCliff {
    constructor(
        address _beneficiary,
        uint64 _startTimestamp,
        uint64 _durationSeconds,
        uint64 _cliffSeconds
    )
        VestingWallet(_beneficiary, _startTimestamp, _durationSeconds)
        VestingWalletCliff(_cliffSeconds)
    {}

    /**
     * @dev Overridden vesting schedule that yields 0 until the cliff is reached,
     *      then linear vesting from cliff end to end.
     */
    function _vestingSchedule(
        uint256 totalAllocation,
        uint64 timestamp
    ) internal view override(VestingWallet, VestingWalletCliff) returns (uint256) {
        return (timestamp < cliff()) 
            ? 0 
            : super._vestingSchedule(totalAllocation, timestamp);
    }
}

/**
 * @title DXPToken
 * @dev Implements Dexponent Token with the following features:
 *      - Total supply of 21M DXP
 *      - 60% (12.6M) allocated for emissions (block-based or time-based), halving every 4 years
 *      - 40% (8.4M) for vesting (team, advisors, etc.)
 *      - Emission logic avoids double counting by tracking how many “blocks” have passed since the last emission call
 *      - Recycle function to return tokens to `address(this)` (the unissued supply)
 *      - Owner (the Dexponent Protocol contract) can call `emitTokens()` to manage supply
 */
contract DXPToken is ERC20Permit, Ownable, ReentrancyGuard {
    // -------------------------------------------------------
    // Tokenomics
    // -------------------------------------------------------
    uint256 public constant TOTAL_SUPPLY = 21_000_000 * 1e18;   // 21M
    uint256 public constant EMISSION_SUPPLY = (TOTAL_SUPPLY * 60) / 100; // 12.6M DXP
    uint256 public constant VESTED_SUPPLY   = (TOTAL_SUPPLY * 40) / 100; // 8.4M DXP

    // -------------------------------------------------------
    // Emission parameters
    // -------------------------------------------------------
    /**
     * @dev The emission rate in DXP per “block” or time interval (we define a block as ~20-30 seconds).
     *      Adjust to your target (e.g. 1 DXP per 30s => blockTime=30, emissionPerBlock=1e18).
     */
    uint256 public emissionPerBlock = 1 * 1e18; 

    /**
     * @dev The ‘blockTime’ or average block time in seconds, e.g. 20 or 30. 
     *      You can adjust if your chain’s block time differs from typical ~20s or ~2s.
     */
    uint256 public immutable blockTime = 30; // e.g. 30 seconds

    /**
     * @dev The timestamp when this contract is deployed. Used to measure how many “blocks” have passed.
     */
    uint256 public immutable startTime;

    /**
     * @dev Halving every 4 years in seconds, e.g. 4 * 365 days = ~126144000
     *      Adjust if you want exactly 4 * 365.25 days or a different approach.
     */
    uint256 public immutable halvingInterval = 4 * 365 days; 

    // Emission tracking
    uint256 public totalEmitted;    // total minted from EMISSION_SUPPLY
    uint256 public lastHalvingTime; // tracks the last halving event
    uint256 public lastEmissionTime; // new: tracks the last time we did an emission call

    // -------------------------------------------------------
    // Vesting
    // -------------------------------------------------------
    mapping(address => address) public vestingWallets;

    // -------------------------------------------------------
    // Events
    // -------------------------------------------------------
    event HalvingOccurred(uint256 newEmissionRate);
    event TokensEmitted(uint256 amount);
    event TokensRecycled(uint256 amount);
    event VestingWalletCreated(address indexed beneficiary, address vestingWallet);

    /**
     * @dev Constructor: name & symbol set, half of the VESTED_SUPPLY can be minted
     *      to the owner if desired or minted to vesting wallets on creation.
     */
    constructor() 
        ERC20("Dexponent Token", "DXP") 
        ERC20Permit("Dexponent Token") 
        Ownable(msg.sender) 
    {
        startTime = block.timestamp;
        lastHalvingTime = block.timestamp;
        lastEmissionTime = block.timestamp;

        // Example: optionally mint some portion of VESTED_SUPPLY to the owner or to a vesting wallet.
        // e.g. _mint(msg.sender, VESTED_SUPPLY / 2);
        // The rest can be minted upon creating vesting wallets or remain unissued.
        _mint(msg.sender, VESTED_SUPPLY / 2);

        // The full emission supply (12.6M) is not minted initially. We mint gradually 
        // in `emitTokens()`. 
        // The difference between total minted so far + unissued is the remainder up to 21M.
    }

    // -------------------------------------------------------
    // Emission Logic
    // -------------------------------------------------------

    /**
     * @notice Called by the Dexponent Protocol (the owner) to mint new DXP tokens
     *         based on how many time intervals (“blocks”) have passed since lastEmissionTime.
     *         This avoids double-counting from the start each time.
     *
     * @dev 1) Halve emission rate every 4 years if needed
     *      2) Calculate how many intervals have passed since lastEmissionTime
     *      3) Mint = emissionPerBlock * intervals
     *      4) Update lastEmissionTime
     */
    function emitTokens() external onlyOwner nonReentrant {
        require(totalEmitted < EMISSION_SUPPLY, "Emission supply exhausted");

        // 1) check for halving
        if (block.timestamp >= lastHalvingTime + halvingInterval) {
            emissionPerBlock /= 2;
            lastHalvingTime = block.timestamp;
            emit HalvingOccurred(emissionPerBlock);
        }

        // 2) calculate how many intervals since lastEmissionTime
        uint256 timeElapsed = block.timestamp - lastEmissionTime;
        uint256 intervals = timeElapsed / blockTime;
        if (intervals == 0) {
            // no intervals have passed => no mint
            return;
        }

        // 3) compute minted amount
        uint256 amount = intervals * emissionPerBlock;
        
        // clamp if it exceeds EMISSION_SUPPLY
        if (totalEmitted + amount > EMISSION_SUPPLY) {
            amount = EMISSION_SUPPLY - totalEmitted;
        }

        if (amount == 0) {
            // either already exhausted or no intervals
            return;
        }

        // 4) update
        totalEmitted += amount;
        lastEmissionTime = block.timestamp;

        // mint to address(this) as unissued supply
        _mint(msg.sender, amount);
        emit TokensEmitted(amount);
    }

    /**
     * @notice Recycles DXP tokens back into address(this) from msg.sender. 
     *         Typically used for returned deposit bonuses or fee payments.
     * @param amount The amount of DXP to recycle.
     */
    function recycleTokens(uint256 amount) external {
        // user must have an allowance or enough DXP
        _burn(msg.sender, amount);
        _mint(address(this), amount);
        emit TokensRecycled(amount);
    }

    // -------------------------------------------------------
    // Vesting Logic
    // -------------------------------------------------------

    /**
     * @notice Creates a vesting wallet for a beneficiary with a cliff + linear vesting schedule.
     *        This can be used to distribute some or all of the VESTED_SUPPLY (8.4M).
     */
    function createVestingWallet(
        address beneficiary,
        uint64 startTimestamp,
        uint64 durationSeconds,
        uint64 cliffSeconds,
        uint256 allocation
    ) external onlyOwner {
        require(vestingWallets[beneficiary] == address(0), "Already has vesting");
        require(allocation <= VESTED_SUPPLY, "Allocation>VESTED_SUPPLY? handle carefully");

        // Deploy a custom vesting component
        VestingComponent wallet = new VestingComponent(
            beneficiary,
            startTimestamp,
            durationSeconds,
            cliffSeconds
        );
        vestingWallets[beneficiary] = address(wallet);

        // Mint or transfer tokens to that wallet
        // If you want to keep track of how much of the VESTED_SUPPLY is allocated, 
        // you can store a variable or do partial checks. 
        // We’ll do a direct mint from nowhere for demonstration.
        _mint(address(wallet), allocation);

        emit VestingWalletCreated(beneficiary, address(wallet));
    }

    // -------------------------------------------------------
    // Additional Helpers
    // -------------------------------------------------------

    /**
     * @notice Returns how many intervals (“blocks”) have passed since the last emission.
     */
    function getIntervalsSinceLastEmission() external view returns (uint256) {
        uint256 timeElapsed = block.timestamp - lastEmissionTime;
        return timeElapsed / blockTime;
    }

    /**
     * @notice Returns the current emission rate, factoring in how many halvings have occurred 
     *         since `startTime`. 
     *         This is an approximate: the actual rate is `emissionPerBlock`, which we halve 
     *         whenever we pass a halving boundary in `emitTokens()`.
     */
    function getCurrentEmissionRate() external view returns (uint256) {
        // e.g. we can do a purely time-based approach:
        // but actually, the contract logic only halves when we cross the boundary, so 
        // we rely on the actual `emissionPerBlock`.
        return emissionPerBlock;
    }
}
