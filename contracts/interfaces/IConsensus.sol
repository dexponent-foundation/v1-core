interface IConsensus {
    /// @notice Returns the current protocol fee rate applied to revenue.
    /// @dev Fee rate is expressed as an integer percentage (0 to 100).
    /// @return The protocol fee rate percentage.
    function getProtocolFeeRate() external view returns (uint256);

    /// @notice Returns the current DXP token balance held in reserve by the protocol.
    /// @dev Protocol reserves accrue from fees and can be redeemed or reallocated.
    /// @return The DXP token reserve amount.
    function getProtocolReserves() external view returns (uint256);

    /// @notice Returns the current emission reserve for mintable DXP tokens.
    /// @dev Emission reserve tracks DXP tokens set aside for distribution to farms and other incentives.
    /// @return The DXP token emission reserve amount.
    function getEmissionReserve() external view returns (uint256);
}