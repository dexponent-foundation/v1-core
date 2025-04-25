// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";


/// @title IDXPToken
/// @notice Minimal interface for the Dexponent Token (DXPToken) used in the protocol.
///         This interface exposes the functions that the protocol needs to interact with the token,
///         such as emission logic, recycling tokens, and basic ERC20 functions.
interface IDXPToken is IERC20 {
    // ERC20 standard functions:
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    // Emission function: called by the protocol (owner) to mint new tokens.
    function emitTokens() external;

    // Recycle tokens: used for deposit bonus reversal or fee returns.
    function recycleTokens(uint256 amount) external;
    
}
