// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * @title DXPFaucet
 * @notice A simple faucet for testnet that allows users to claim DXP tokens.
 *         Users can claim a fixed amount of DXP once per cooldown period.
 */
contract DXPFaucet is Ownable {
    IERC20 public dxpToken;
    uint256 public claimAmount;
    uint256 public cooldown; // in seconds

    // Tracks the last claim timestamp for each user.
    mapping(address => uint256) public lastClaimed;

    event TokensClaimed(address indexed claimer, uint256 amount);

    /**
     * @param _dxpToken The address of the DXP token contract.
     * @param _claimAmount The amount of DXP tokens to dispense per claim (in wei).
     * @param _cooldown The cooldown period in seconds between claims.
     */
    constructor(address _dxpToken, uint256 _claimAmount, uint256 _cooldown) Ownable(msg.sender) {
        require(_dxpToken != address(0), "Invalid token address");
        dxpToken = IERC20(_dxpToken);
        claimAmount = _claimAmount;
        cooldown = _cooldown;
    }

    /**
     * @notice Allows a user to claim DXP tokens, subject to the cooldown.
     */
    function claim() external {
        require(
            block.timestamp >= lastClaimed[msg.sender] + cooldown,
            "Cooldown period has not passed"
        );
        lastClaimed[msg.sender] = block.timestamp;
        require(dxpToken.transfer(msg.sender, claimAmount), "Token transfer failed");
        emit TokensClaimed(msg.sender, claimAmount);
    }

    /**
     * @notice Allows the owner to update faucet parameters.
     * @param _claimAmount New claim amount.
     * @param _cooldown New cooldown period in seconds.
     */
    function updateParameters(uint256 _claimAmount, uint256 _cooldown) external onlyOwner {
        claimAmount = _claimAmount;
        cooldown = _cooldown;
    }

    /**
     * @notice Allows the owner to recover tokens from the faucet in case of emergencies.
     * @param tokenAddress Address of the token to recover.
     * @param amount Amount to recover.
     */
    function recoverTokens(address tokenAddress, uint256 amount) external onlyOwner {
        IERC20(tokenAddress).transfer(owner(), amount);
    }
}
