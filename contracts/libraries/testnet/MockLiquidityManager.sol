// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "../../interfaces/ILiquidityManager.sol";

/**
 * @title MockLiquidityManager
 * @notice A minimal stub implementation of the ILiquidityManager interface for testing.
 *         All methods simply return fixed or mock values, ensuring your protocol
 *         can call them without reverting.
 */
contract MockLiquidityManager is ILiquidityManager, Ownable {

    constructor(address dxpToken, address usdcToken) Ownable(msg.sender) {
        // Optionally set config
    }
    /**
     * @dev createPool stub. Returns a pseudo pool address by hashing tokenA, tokenB, block.timestamp.
     */
    function createPool(
        address tokenA,
        address tokenB,
        uint24 /*uniFee*/,
        uint160 /*sqrtPriceX96*/,
        bool /*stable*/
    ) external override returns (address poolAddress) {
        // Just return a pseudo-deterministic address
        poolAddress = address(
            uint160(
                uint256(
                    keccak256(abi.encode(tokenA, tokenB, block.timestamp))
                )
            )
        );
    }

    /**
     * @dev addLiquidity stub. Does nothing but ensures it won't revert.
     */
    function addLiquidity(
        address /*tokenA*/,
        address /*tokenB*/,
        uint24 /*uniFee*/,
        bool /*stable*/,
        uint256 /*amountADesired*/,
        uint256 /*amountBDesired*/,
        uint256 /*amountAMin*/,
        uint256 /*amountBMin*/
    ) external override {
        // No-op
    }

    /**
     * @dev removeLiquidity stub. Returns a fixed pair of dxpAmount and usdcAmount.
     */
    function removeLiquidity(
        address /*tokenA*/,
        address /*tokenB*/,
        uint24 /*uniFee*/,
        uint256 /*liquidityAmount*/
    ) external override returns (uint256 dxpAmount, uint256 usdcAmount) {
        // Return arbitrary non-zero values
        dxpAmount = 500;
        usdcAmount = 1000;
    }

    /**
     * @dev swap stub. Returns a fixed amountOut.
     */
    function swap(
        address /*tokenIn*/,
        address /*tokenOut*/,
        uint256 /*amountIn*/,
        address /*recipient*/
    ) external override returns (uint256 amountOut) {
        // Return a mock non-zero
        amountOut = 1234;
    }

    /**
     * @dev harvestFees stub. Returns fixed usdcFees and dxpFees.
     */
    function harvestFees(address /*poolAddress*/)
        external
        override
        returns (uint256 usdcFees, uint256 dxpFees)
    {
        usdcFees = 777;
        dxpFees = 333;
    }

    /**
     * @dev getPendingFees stub. Returns a fixed pending fee.
     */
    function getPendingFees(address /*poolAddress*/)
        external
        view
        override
        returns (uint256 pendingFees)
    {
        pendingFees = 42;
    }

    /**
     * @dev getTwapPrice stub. Returns a fixed Q64.96 price (e.g., 5e18 to represent $5).
     *      You can tweak this to suit your testing.
     */
    function getTwapPrice(
        address /*tokenA*/,
        address /*tokenB*/,
        uint24 /*uniFee*/,
        uint32 /*interval*/
    ) external view override returns (uint256 priceX96) {
        // For example, we say everything is $5 in terms of "Q64.96 style"
        // (the real formula would be more complex, but we want a stable, non-zero value).
        return 1e18;
    }

    /**
     * @dev getBestSwapAmountOut stub. Returns a fixed bestAmountOut and route=0.
     */
    function getBestSwapAmountOut(
        address /*tokenIn*/,
        address /*tokenOut*/,
        uint256 /*amountIn*/
    ) external view override returns (uint256 bestAmountOut, uint8 bestRoute) {
        // Provide a stable non-zero. E.g., 1000 out, direct route is best (0).
        bestAmountOut = 1000;
        bestRoute = 0;
    }
}
