// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

/**
 * @title ILiquidityManager
 * @notice Interface for the LiquidityManager contract used within the protocol.
 *         It provides methods to create pools, add/remove liquidity, perform token swaps,
 *         harvest fees, and obtain pricing information (TWAP and best swap amounts).
 */
interface ILiquidityManager {
    /**
     * @notice Creates a liquidity pool for tokenA and tokenB if one does not exist.
     * @param tokenA The first token in the pair.
     * @param tokenB The second token in the pair.
     * @param uniFee The Uniswap v3 fee tier (e.g., 3000 for 0.3%).
     * @param sqrtPriceX96 The initial sqrt price (in Q64.96) for the pool.
     * @param stable True if creating a stable pool on the fallback DEX.
     * @return poolAddress The address of the created or existing pool.
     */
    function createPool(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        uint160 sqrtPriceX96,
        bool stable
    ) external returns (address poolAddress);

    /**
     * @notice Adds liquidity to a pool (Uniswap v3 or fallback DEX) and sends LP tokens/NFT to the Farm.
     * @param tokenA The first token of the pair.
     * @param tokenB The second token of the pair.
     * @param uniFee The Uniswap v3 fee tier (ignored for fallback DEXes).
     * @param stable Boolean flag for using a stable pool (for fallback DEXes).
     * @param amountADesired Desired amount of tokenA to add.
     * @param amountBDesired Desired amount of tokenB to add.
     * @param amountAMin Minimum amount of tokenA to add (for slippage protection).
     * @param amountBMin Minimum amount of tokenB to add (for slippage protection).
     */
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

    /**
     * @notice Removes liquidity from a pool.
     * @param tokenA The first token of the pair.
     * @param tokenB The second token of the pair.
     * @param uniFee The Uniswap v3 fee tier.
     * @param liquidityAmount The amount of liquidity to remove.
     * @return dxpAmount Amount of DXP obtained.
     * @return usdcAmount Amount of USDC (or the other token) obtained.
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        uint256 liquidityAmount
    ) external returns (uint256 dxpAmount, uint256 usdcAmount);

    /**
     * @notice Swaps a given amount of tokenIn for tokenOut.
     * @param tokenIn The input token.
     * @param tokenOut The output token.
     * @param amountIn The amount of tokenIn to swap.
     * @param recipient The address that will receive tokenOut.
     * @return amountOut The amount of tokenOut obtained.
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external returns (uint256 amountOut);

    /**
     * @notice Harvests fees from a specified liquidity pool.
     * @param poolAddress The address of the liquidity pool.
     * @return usdcFees The amount of USDC fees harvested.
     * @return dxpFees The amount of DXP fees harvested.
     */
    function harvestFees(address poolAddress) external returns (uint256 usdcFees, uint256 dxpFees);

    /**
     * @notice Returns the pending fee amount from a specified liquidity pool.
     * @param poolAddress The address of the liquidity pool.
     * @return pendingFees The pending fee amount.
     */
    function getPendingFees(address poolAddress) external view returns (uint256 pendingFees);

    /**
     * @notice Returns the TWAP price of tokenA in terms of tokenB over a specified interval.
     * @param tokenA The base token.
     * @param tokenB The quote token.
     * @param uniFee The Uniswap v3 fee tier.
     * @param interval The time interval (in seconds) over which to calculate the TWAP.
     * @return priceX96 The time-weighted average price in Q64.96 format.
     */
    function getTwapPrice(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        uint32 interval
    ) external view returns (uint256 priceX96);

    /**
     * @notice Calculates the best output amount for swapping a given amount of tokenIn for tokenOut.
     * @param tokenIn The input token.
     * @param tokenOut The output token.
     * @param amountIn The amount of tokenIn.
     * @return bestAmountOut The maximum output amount obtainable.
     * @return bestRoute 0 if the direct route is best, 1 if a two-hop route via baseStableToken is best.
     */
    function getBestSwapAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 bestAmountOut, uint8 bestRoute);
}
