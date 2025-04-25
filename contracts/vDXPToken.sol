// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "./interfaces/BaseClaimToken.sol";
import "./RootFarm.sol";

/**
 * @title vDXPToken
 * @notice vDXPToken serves as both the claim token for RootFarm and the protocol's governance token.
 *
 * Key features:
 * - Inherits from BaseClaimToken to enforce minting/burning restrictions.
 * - Records the timestamp of each token acquisition to enforce a cooling period (for voting/claiming).
 * - Implements a transfer fee mechanism:
 *     - On transfers, a fee (as defined by transferFeeRate) is deducted from the transfer amount.
 *     - The fee is burned (removed from circulation).
 *     - The fee amount is then sent to the RootFarm via unlockDXP, which unlocks an equivalent amount of DXP from the locked pool,
 *       effectively increasing the revenue available for distribution.
 *
 * The RootFarm address is set by the protocol after deployment.
 */
contract vDXPToken is BaseClaimToken {
    // -------------------------------------------------------
    // Cooling Logic
    // -------------------------------------------------------
    /// @notice Maps each account to its last acquisition timestamp.
    mapping(address => uint256) public lastAcquireTimestamp;
    
    /// @notice Global cooling period in seconds. A user is considered "cooled down" if
    ///         block.timestamp >= lastAcquireTimestamp[user] + coolingPeriod.
    uint256 public coolingPeriod;

    // -------------------------------------------------------
    // Events
    // -------------------------------------------------------
    event CoolingPeriodUpdated(uint256 oldPeriod, uint256 newPeriod);
    event RootFarmUpdated(address oldRootFarm, address newRootFarm);

    // -------------------------------------------------------
    // Constructor
    // -------------------------------------------------------
    /**
     * @notice Initializes the vDXPToken.
     * @param _name Token name.
     * @param _symbol Token symbol.
     * @param _minter Address allowed to mint/burn tokens (initially set to protocol).
     * @param _coolingPeriod Initial cooling period in seconds.
     */
    constructor(
        string memory _name,
        string memory _symbol,
        address _minter,
        uint256 _coolingPeriod
    )
        BaseClaimToken(_name, _symbol, _minter) Ownable(msg.sender)
    {
        coolingPeriod = _coolingPeriod;
    }

    // -------------------------------------------------------
    // Administration Functions
    // -------------------------------------------------------
    /**
     * @notice Updates the global cooling period.
     * @param _newPeriod New cooling period in seconds.
     */
    function setCoolingPeriod(uint256 _newPeriod) external onlyOwner {
        emit CoolingPeriodUpdated(coolingPeriod, _newPeriod);
        coolingPeriod = _newPeriod;
    }

    // -------------------------------------------------------
    // Transfer Overrides with Fee & Unlock Mechanism
    // -------------------------------------------------------
    /**
     * @notice Overrides transfer to:
     *         1) Deduct a fee from the transferred amount.
     *         2) Burn the fee.
     *         3) Notify RootFarm to unlock an equivalent amount of DXP (increasing revenue).
     *         4) Transfer the net amount to the recipient.
     *         5) Update the recipient's last acquire timestamp.
     * @param recipient Address receiving the tokens.
     * @param amount Amount to transfer.
     * @return true if the transfer succeeds.
     */
    function transfer(address recipient, uint256 amount)
        public
        virtual
        override
        returns (bool)
    {
        require(recipient != address(0), "vDXP: transfer to zero address");
        address sender = _msgSender();
        uint256 feeRate = transferFeeRate; // Inherited from BaseClaimToken.

        if (feeRate > 0) {
            uint256 fee = (amount * feeRate) / 10000;
            uint256 net = amount - fee;
            // Burn the fee amount.
            _burn(sender, fee);
            // Notify RootFarm to unlock the fee amount of DXP.
            if (associatedFarm != address(0)) {
                // RootFarm.unlockDXP should be restricted to calls from vDXPToken.
                RootFarm(associatedFarm).unlockDXP(fee);
            }
            // Transfer net tokens.
            super._transfer(sender, recipient, net);
            // Record the acquisition time for cooling.
            lastAcquireTimestamp[recipient] = block.timestamp;
        } else {
            super._transfer(sender, recipient, amount);
            lastAcquireTimestamp[recipient] = block.timestamp;
        }
        return true;
    }

    /**
     * @notice Overrides transferFrom similarly to transfer.
     * @param sender Address from which tokens are transferred.
     * @param recipient Address receiving the tokens.
     * @param amount Amount to transfer.
     * @return true if the transfer succeeds.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        require(recipient != address(0), "vDXP: transfer to zero address");
        uint256 currentAllowance = allowance(sender, _msgSender());
        require(currentAllowance >= amount, "vDXP: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);

        uint256 feeRate = transferFeeRate;
        if (feeRate > 0) {
            uint256 fee = (amount * feeRate) / 10000;
            uint256 net = amount - fee;
            _burn(sender, fee);
            if (associatedFarm != address(0)) {
                RootFarm(associatedFarm).unlockDXP(fee);
            }
            super._transfer(sender, recipient, net);
            lastAcquireTimestamp[recipient] = block.timestamp;
        } else {
            super._transfer(sender, recipient, amount);
            lastAcquireTimestamp[recipient] = block.timestamp;
        }
        return true;
    }

    // -------------------------------------------------------
    // Voting & Cooling Helpers
    // -------------------------------------------------------
    /**
     * @notice Checks if a user has cooled down since their last acquisition.
     * @param user The address to check.
     * @return True if the current time is at least coolingPeriod seconds after lastAcquireTimestamp[user].
     */
    function isCooledDown(address user) external view returns (bool) {
        return block.timestamp >= (lastAcquireTimestamp[user] + coolingPeriod);
    }

    /**
     * @notice Checks if a user is allowed to vote based on cooling period.
     * @param user The address to check.
     * @return True if the user is cooled down.
     */
    function canVote(address user) external view returns (bool) {
        return block.timestamp >= (lastAcquireTimestamp[user] + coolingPeriod);
    }

    // -------------------------------------------------------
    // Mint & Burn Overrides
    // -------------------------------------------------------
    /**
     * @notice Mints new vDXP tokens and records the acquisition timestamp.
     *         Can only be called by the designated minter.
     * @param to Address to receive minted tokens.
     * @param amount Amount of tokens to mint.
     */
    function mint(address to, uint256 amount) external override {
        require(msg.sender == minter, "vDXP: not minter");
        _mint(to, amount);
        lastAcquireTimestamp[to] = block.timestamp;
    }

    /**
     * @notice Burns vDXP tokens.
     *         Can only be called by the designated minter.
     * @param from Address from which tokens will be burned.
     * @param amount Amount to burn.
     */
    function burn(address from, uint256 amount) external override {
        require(msg.sender == minter, "vDXP: not minter");
        _burn(from, amount);
    }
}