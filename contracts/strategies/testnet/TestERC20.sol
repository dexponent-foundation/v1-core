// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract TestERC20 is ERC20, ERC20Permit, Ownable {
    constructor(string memory name_, string memory symbol_, uint256 initialSupply) ERC20(name_, symbol_) ERC20Permit(name_) Ownable(msg.sender) {

        _mint(msg.sender, initialSupply);
    }

   /**
     * @dev Mints tokens to the specified address.
     * For testing, this function is public so anyone can mint tokens.
     * In production, you’d want to restrict minting.
     */
    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    /**
     * @dev Utility function to mint and immediately transfer tokens to a specified address.
     * This simulates sending tokens to an address as needed.
     */
    function sendTokens(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
