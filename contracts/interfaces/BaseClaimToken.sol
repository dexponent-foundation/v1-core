// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "./IFarm.sol";

import "./IProtocolCore.sol";


/**
 * @title BaseClaimToken
 * @notice Abstract base contract for claim tokens used by Farms.
 *         It is responsible for minting claim tokens (1:1 against principal deposited)
 *         and implements an optional transfer fee mechanism.
 *
 *         In this updated design, instead of sending a fee to a feeReceiver,
 *         the fee is deducted from the transferred amount and then an external function
 *         is called on the associated Farm (set via setAssociatedFarm) so that the Farm
 *         can update its internal "principalReserve" (i.e. the portion of principal that is
 *         earmarked for yield/revenue rather than remaining as LP claim).
 *
 *         The minter is restricted to the Farm (or protocol) that deployed this claim token.
 */
abstract contract BaseClaimToken is ERC20, Ownable {
    /// @notice Address allowed to mint/burn this token (e.g., a Farm or protocol).
    address public minter;

    /// @notice Address of the associated Farm contract.
    /// This should be set by the Farm once deployed.
    address public associatedFarm;


    IProtocolCore public protocolCore;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------
    event MinterUpdated(address indexed oldMinter, address indexed newMinter);
    event AssociatedFarmUpdated(address indexed oldFarm, address indexed newFarm);

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------
    constructor(
        string memory _name,
        string memory _symbol,
        address _minter
    ) ERC20(_name, _symbol) {
        require(_minter != address(0), "BaseClaimToken: invalid minter");
        minter = _minter;
        protocolCore = IProtocolCore(_minter); // Protocol mints the claim token
    }

    // -------------------------------------------------------------------------
    // Admin: Minter & Fee Config
    // -------------------------------------------------------------------------
    /**
     * @notice Sets a new minter address. Only the contract owner can call this.
     * @param _minter New minter address.
     */
    function setMinter(address _minter) external onlyOwner {
        require(_minter != address(0), "BaseClaimToken: invalid minter");
        emit MinterUpdated(minter, _minter);
        minter = _minter;
    }


    /**
     * @notice Sets the associated Farm address.
     *         This function should be called by the Farm (or protocol) after deploying the claim token.
     * @param _farm The address of the associated Farm.
     */
    function setAssociatedFarm(address _farm) external onlyOwner {
        require(_farm != address(0), "BaseClaimToken: invalid farm address");
        emit AssociatedFarmUpdated(associatedFarm, _farm);
        associatedFarm = _farm;
    }

    // -------------------------------------------------------------------------
    // Restricted Mint / Burn
    // -------------------------------------------------------------------------
    /**
     * @notice Mints tokens to a specified address.
     *         Only the authorized minter can call this.
     * @param to Recipient address.
     * @param amount Amount to mint.
     */
    function mint(address to, uint256 amount) external virtual {
        require(msg.sender == minter, "BaseClaimToken: not minter");
        _mint(to, amount);
    }

    /**
     * @notice Burns tokens from a specified address.
     *         Only the authorized minter can call this.
     * @param from Address from which tokens will be burned.
     * @param amount Amount to burn.
     */
    function burn(address from, uint256 amount) external virtual {
        require(msg.sender == minter, "BaseClaimToken: not minter");
        _burn(from, amount);
    }

    // -------------------------------------------------------------------------
    // Overriding Transfer / TransferFrom for Fee Logic
    // -------------------------------------------------------------------------
    /**
     * @dev Overrides the standard transfer method.
     *      If transferFeeRate > 0, a fee is deducted from the transferred amount.
     *      Instead of sending the fee to a feeReceiver, the fee is sent to the associated Farm
     *      via an external call (updatePrincipalReserve), so that the Farm can update its principal reserve.
     */
    function transfer(address recipient, uint256 amount)
        public
        virtual
        override
        returns (bool)
    {
        address sender = _msgSender();
        require(recipient != address(0), "BaseClaimToken: transfer to zero address");

        uint256 transferFeeRate = protocolCore.getTransferFeeRate();

        if (transferFeeRate > 0) {
            uint256 fee = (amount * transferFeeRate) / 10000;
            uint256 net = amount - fee;

            // Instead of transferring fee to feeReceiver, call associatedFarm.updatePrincipalReserve.
            if (associatedFarm != address(0)) {
                // Interface IFarm should include updatePrincipalReserve(uint256 fee)
                // Here we assume the call succeeds; in production you might add error handling.
                IFarm(associatedFarm).onClaimTransfer(sender, recipient, amount);
            }
            // Transfer the net amount to the recipient.
            super._transfer(sender, recipient, net);
        } else {
            super._transfer(sender, recipient, amount);
        }
        return true;
    }

    /**
     * @dev Overrides the standard transferFrom method with similar fee logic.
     */
    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public virtual override returns (bool) {
        require(recipient != address(0), "BaseClaimToken: transfer to zero address");

        uint256 currentAllowance = allowance(sender, _msgSender());
        require(currentAllowance >= amount, "BaseClaimToken: transfer amount exceeds allowance");
        _approve(sender, _msgSender(), currentAllowance - amount);

        uint256 transferFeeRate = protocolCore.getTransferFeeRate();

        if (transferFeeRate > 0) {
            uint256 fee = (amount * transferFeeRate) / 10000;
            uint256 net = amount - fee;

            if (associatedFarm != address(0)) {
                IFarm(associatedFarm).onClaimTransfer(sender, recipient, amount);
            }
            super._transfer(sender, recipient, net);
        } else {
            super._transfer(sender, recipient, amount);
        }
        return true;
    }
}