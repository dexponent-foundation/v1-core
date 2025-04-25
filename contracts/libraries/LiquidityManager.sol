// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import "../libraries/TickMath.sol";

/// @notice Interface for Uniswap v3 Factory.
interface IUniswapV3Factory {
    function getPool(
        address tokenA,
        address tokenB,
        uint24 fee
    ) external view returns (address);
}

/// @notice Interface for Uniswap v3 Position Manager.
interface IUniswapV3PositionManager {
    function createAndInitializePoolIfNecessary(
        address token0,
        address token1,
        uint24 fee,
        uint160 sqrtPriceX96
    ) external payable returns (address pool);

    function mint(
        address token0,
        address token1,
        uint24 fee,
        int24 tickLower,
        int24 tickUpper,
        uint256 amount0Desired,
        uint256 amount1Desired,
        uint256 amount0Min,
        uint256 amount1Min,
        address recipient,
        uint256 deadline
    )
        external
        payable
        returns (
            uint256 tokenId,
            uint128 liquidity,
            uint256 amount0,
            uint256 amount1
        );
        
    // In a real implementation, decreaseLiquidity would be used to remove liquidity.
    // Here we simulate liquidity removal.
    function decreaseLiquidity(
        uint256 tokenId,
        uint128 liquidity,
        uint256 amount0Min,
        uint256 amount1Min,
        uint256 deadline
    ) external returns (uint256 amount0, uint256 amount1);
}

/// @notice Interface for Uniswap v3 Pool.
interface IUniswapV3Pool {
    function observe(
        uint32[] calldata secondsAgos
    )
        external
        view
        returns (
            int56[] memory tickCumulatives,
            uint160[] memory liquidityCumulatives
        );

    function slot0() external view returns (uint160 sqrtPriceX96, int24 tick);
}

/// @notice Interface for Uniswap v3 Quoter.
interface IUniswapV3Quoter {
    function quoteExactInputSingle(
        address tokenIn,
        address tokenOut,
        uint24 fee,
        uint256 amountIn,
        uint160 sqrtPriceLimitX96
    ) external view returns (uint256 amountOut);
}

/// @notice Interface for Uniswap v2 Router.
interface IUniswapV2Router {
    function factory() external view returns (address);

    function getAmountsOut(
        uint256 amountIn,
        address[] calldata path
    ) external view returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

/// @notice Interface for Aerodrome Router.
interface IAerodromeRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    function getAmountsOut(
        uint256 amountIn,
        Route[] calldata routes
    ) external view returns (uint256[] memory amounts);

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);
}

/// @notice Interface for Uniswap v2 Factory.
interface IFactory {
    function createPair(
        address tokenA,
        address tokenB
    ) external returns (address pair);
}

/// @notice Interface for Aerodrome Factory.
interface IAerodromeFactory {
    function createPool(
        address tokenA,
        address tokenB,
        bool stable
    ) external returns (address pool);
}

/// @title LiquidityManager
/// @notice Provides methods for creating pools, adding/removing liquidity,
/// swapping tokens, harvesting fees, and obtaining price information.
/// @dev This contract is owned by the protocol and is used by strategy contracts.
contract LiquidityManager is Ownable, IERC721Receiver {
    using SafeERC20 for IERC20;

    // ------------------------------
    // Uniswap v3 Components
    // ------------------------------
    IUniswapV3PositionManager public immutable uniV3PositionManager;
    IUniswapV3Factory public immutable uniV3Factory;
    IUniswapV3Quoter public immutable uniV3Quoter;
    uint24 public immutable defaultUniFee; // e.g., 3000 for 0.3%

    // ------------------------------
    // Fallback DEX Components
    // ------------------------------
    address public immutable fallbackFactory;
    address public immutable fallbackRouter;
    bool public immutable fallbackUsesStableSwap; // true for Aerodrome, false for Uniswap v2 style
    address public immutable baseStableToken; // e.g., USDC

    // ------------------------------
    // Farm Address
    // ------------------------------
    address public immutable farm;

    // ------------------------------
    // Constructor
    // ------------------------------
    constructor(address _farm) Ownable(msg.sender) {
        require(_farm != address(0), "LiquidityManager: invalid farm address");
        farm = _farm;
        uint256 cid = block.chainid;
        if (cid == 1) {
            // Ethereum Mainnet addresses
            uniV3PositionManager = IUniswapV3PositionManager(
                0xC36442b4a4522E871399CD717aBDD847Ab11FE88
            );
            uniV3Factory = IUniswapV3Factory(
                0x1F98431c8aD98523631AE4a59f267346ea31F984
            );
            uniV3Quoter = IUniswapV3Quoter(
                0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6
            );
            defaultUniFee = 3000;
            fallbackFactory = address(0);
            fallbackRouter = address(0);
            fallbackUsesStableSwap = false;
            baseStableToken = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
        } else if (cid == 42161) {
            uniV3PositionManager = IUniswapV3PositionManager(
                0xC36442b4a4522E871399CD717aBDD847Ab11FE88
            );
            uniV3Factory = IUniswapV3Factory(
                0x1F98431c8aD98523631AE4a59f267346ea31F984
            );
            uniV3Quoter = IUniswapV3Quoter(
                0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6
            );
            defaultUniFee = 3000;
            fallbackFactory = 0x6EcCab422D763aC031210895C81787E87B43A652;
            fallbackRouter = 0xc873fEcbd354f5A56E00E710B90EF4201db2448d;
            fallbackUsesStableSwap = false;
            baseStableToken = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
        } else if (cid == 8453) {
            uniV3PositionManager = IUniswapV3PositionManager(
                0x03a520b32C04BF3bEEf7BEb72E919cf822Ed34f1
            );
            uniV3Factory = IUniswapV3Factory(
                0x33128a8fC17869897dcE68Ed026d694621f6FDfD
            );
            uniV3Quoter = IUniswapV3Quoter(
                0xb27308f9F90D607463bb33eA1BeBb41C27CE5AB6
            );
            defaultUniFee = 3000;
            fallbackFactory = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
            fallbackRouter = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
            fallbackUsesStableSwap = true;
            baseStableToken = 0xd9aAEc86B65D86f6A7B5B1b0c42FFA531710b6CA;
        } else {
            uniV3PositionManager = IUniswapV3PositionManager(address(0));
            uniV3Factory = IUniswapV3Factory(address(0));
            uniV3Quoter = IUniswapV3Quoter(address(0));
            defaultUniFee = 3000;
            fallbackFactory = address(0);
            fallbackRouter = address(0);
            fallbackUsesStableSwap = false;
            baseStableToken = address(0);
        }
    }

    // ------------------------------
    // Pool Creation
    // ------------------------------
    /**
     * @notice Creates a liquidity pool for tokenA and tokenB if one does not exist.
     * @param tokenA First token.
     * @param tokenB Second token.
     * @param uniFee Fee tier for Uniswap v3.
     * @param sqrtPriceX96 Initial sqrt price in Q64.96.
     * @param stable True if creating a stable pool on fallback DEX.
     * @return poolAddress The address of the created or existing pool.
     */
    function createPool(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        uint160 sqrtPriceX96,
        bool stable
    ) external onlyOwner returns (address poolAddress) {
        if (address(uniV3Factory) != address(0)) {
            poolAddress = uniV3Factory.getPool(tokenA, tokenB, uniFee);
            if (poolAddress == address(0)) {
                poolAddress = uniV3PositionManager.createAndInitializePoolIfNecessary(
                    tokenA,
                    tokenB,
                    uniFee,
                    sqrtPriceX96
                );
            }
            return poolAddress;
        } else if (fallbackFactory != address(0)) {
            if (fallbackUsesStableSwap) {
                poolAddress = IAerodromeFactory(fallbackFactory).createPool(tokenA, tokenB, stable);
            } else {
                poolAddress = IFactory(fallbackFactory).createPair(tokenA, tokenB);
            }
            return poolAddress;
        } else {
            revert("No DEX available for pool creation");
        }
    }

    // ------------------------------
    // Add Liquidity
    // ------------------------------
    /**
     * @notice Adds liquidity to a pool and sends LP tokens/NFT to the farm.
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
    ) external onlyOwner {
        IERC20(tokenA).safeTransferFrom(msg.sender, address(this), amountADesired);
        IERC20(tokenB).safeTransferFrom(msg.sender, address(this), amountBDesired);
        if (address(uniV3PositionManager) != address(0)) {
            IERC20(tokenA).safeIncreaseAllowance(address(uniV3PositionManager), amountADesired);
            IERC20(tokenB).safeIncreaseAllowance(address(uniV3PositionManager), amountBDesired);
            int24 tickLower = type(int24).min / int24(uniFee);
            int24 tickUpper = type(int24).max / int24(uniFee);
            uniV3PositionManager.mint(
                tokenA,
                tokenB,
                uniFee,
                tickLower,
                tickUpper,
                amountADesired,
                amountBDesired,
                amountAMin,
                amountBMin,
                farm,
                block.timestamp
            );
            IERC20(tokenA).forceApprove(address(uniV3PositionManager), 0);
            IERC20(tokenB).forceApprove(address(uniV3PositionManager), 0);
        } else if (fallbackRouter != address(0)) {
            IERC20(tokenA).safeIncreaseAllowance(fallbackRouter, amountADesired);
            IERC20(tokenB).safeIncreaseAllowance(fallbackRouter, amountBDesired);
            if (fallbackUsesStableSwap) {
                IAerodromeRouter.Route[] memory routes;
                IAerodromeRouter(fallbackRouter).addLiquidity(
                    tokenA,
                    tokenB,
                    stable,
                    amountADesired,
                    amountBDesired,
                    amountAMin,
                    amountBMin,
                    farm,
                    block.timestamp
                );
            } else {
                IUniswapV2Router(fallbackRouter).addLiquidity(
                    tokenA,
                    tokenB,
                    amountADesired,
                    amountBDesired,
                    amountAMin,
                    amountBMin,
                    farm,
                    block.timestamp
                );
            }
            IERC20(tokenA).forceApprove(fallbackRouter, 0);
            IERC20(tokenB).forceApprove(fallbackRouter, 0);
        } else {
            revert("No DEX available for adding liquidity");
        }
    }

    // ------------------------------
    // Remove Liquidity
    // ------------------------------
    /**
     * @notice Removes liquidity from a pool.
     * @param tokenA First token.
     * @param tokenB Second token.
     * @param uniFee Fee tier.
     * @param liquidityAmount Amount of liquidity to remove.
     * @return dxpAmount Amount of DXP obtained.
     * @return usdcAmount Amount of USDC obtained.
     */
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        uint256 liquidityAmount
    ) external onlyOwner returns (uint256 dxpAmount, uint256 usdcAmount) {
        // In a production implementation, you would track the minted liquidity tokens (NFT tokenId)
        // and then call decreaseLiquidity on the Uniswap v3 Position Manager.
        // Here we simulate removal by splitting liquidity equally.
        dxpAmount = liquidityAmount / 2;
        usdcAmount = liquidityAmount / 2;
        return (dxpAmount, usdcAmount);
    }

    // ------------------------------
    // Swap Function
    // ------------------------------
    /**
     * @notice Swaps a given amount of tokenIn for tokenOut and sends output to recipient.
     * @param tokenIn Input token.
     * @param tokenOut Output token.
     * @param amountIn Amount of tokenIn to swap.
     * @param recipient Recipient address.
     * @return amountOut Amount of tokenOut obtained.
     */
    function swap(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        address recipient
    ) external onlyOwner returns (uint256 amountOut) {
        // Use the Uniswap v3 quoter to simulate a swap.
        amountOut = uniV3Quoter.quoteExactInputSingle(tokenIn, tokenOut, defaultUniFee, amountIn, 0);
        require(amountOut > 0, "LiquidityManager: swap failed");
        // In production, perform the swap via a SwapRouter.
        // For simulation, assume tokens are swapped and transfer tokenOut from this contract to recipient.
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).safeIncreaseAllowance(address(uniV3PositionManager), amountIn);
        // (Swap logic omitted: in production, call SwapRouter.)
        IERC20(tokenOut).safeTransfer(recipient, amountOut);
        return amountOut;
    }

    // ------------------------------
    // Harvest Fees
    // ------------------------------
    /**
     * @notice Harvests fees from a pool.
     * @param poolAddress The liquidity pool address.
     * @return usdcFees Fees in USDC.
     * @return dxpFees Fees in DXP.
     */
    function harvestFees(address poolAddress) external onlyOwner returns (uint256 usdcFees, uint256 dxpFees) {
        // In production, implement actual fee harvesting logic.
        // Here we return dummy values.
        usdcFees = 1000;
        dxpFees = 500;
        return (usdcFees, dxpFees);
    }

    // ------------------------------
    // Pending Fees
    // ------------------------------
    /**
     * @notice Returns the pending fees from a pool.
     * @param poolAddress The liquidity pool address.
     * @return pendingFees Pending fee amount.
     */
    function getPendingFees(address poolAddress) external view returns (uint256 pendingFees) {
        // In production, return actual pending fees.
        return 100;
    }

    // ------------------------------
    // TWAP Price
    // ------------------------------
    /**
     * @notice Returns the TWAP price of tokenA in terms of tokenB.
     * @param tokenA Base token.
     * @param tokenB Quote token.
     * @param uniFee Fee tier.
     * @param interval Time interval in seconds.
     * @return priceX96 TWAP price as Q64.96.
     */
    function getTwapPrice(
        address tokenA,
        address tokenB,
        uint24 uniFee,
        uint32 interval
    ) external view returns (uint256 priceX96) {
        require(address(uniV3Factory) != address(0), "Uniswap v3 not configured");
        address poolAddress = uniV3Factory.getPool(tokenA, tokenB, uniFee);
        require(poolAddress != address(0), "Pool not found");
        IUniswapV3Pool v3pool = IUniswapV3Pool(poolAddress);
        uint32[] memory times = new uint32[](2);
        times[0] = interval;
        times[1] = 0;
        (int56[] memory tickCumulatives, ) = v3pool.observe(times);
        int56 tickCumulDiff = tickCumulatives[1] - tickCumulatives[0];
        int24 avgTick = int24(tickCumulDiff / int56(int32(interval)));
        return _tickToPriceX96(avgTick);
    }

    // ------------------------------
    // Best Swap Amount
    // ------------------------------
    /**
     * @notice Calculates the best output for swapping tokenIn for tokenOut.
     * @param tokenIn Input token.
     * @param tokenOut Output token.
     * @param amountIn Amount of tokenIn.
     * @return bestAmountOut Maximum output amount.
     * @return bestRoute 0 for direct, 1 for via stable.
     */
    function getBestSwapAmountOut(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) external view returns (uint256 bestAmountOut, uint8 bestRoute) {
        uint256 directOut = 0;
        uint256 twoHopOut = 0;
        if (address(uniV3Quoter) != address(0)) {
            directOut = uniV3Quoter.quoteExactInputSingle(tokenIn, tokenOut, defaultUniFee, amountIn, 0);
            uint256 stableOut = uniV3Quoter.quoteExactInputSingle(tokenIn, baseStableToken, defaultUniFee, amountIn, 0);
            if (stableOut > 0) {
                twoHopOut = uniV3Quoter.quoteExactInputSingle(baseStableToken, tokenOut, defaultUniFee, stableOut, 0);
            }
        } else if (fallbackRouter != address(0)) {
            if (fallbackUsesStableSwap) {
                IAerodromeRouter.Route[] memory route1 = new IAerodromeRouter.Route[](1);
                route1[0] = IAerodromeRouter.Route(tokenIn, tokenOut, false, fallbackFactory);
                uint256[] memory outs1 = IAerodromeRouter(fallbackRouter).getAmountsOut(amountIn, route1);
                if (outs1.length > 0) directOut = outs1[outs1.length - 1];
                IAerodromeRouter.Route[] memory route2 = new IAerodromeRouter.Route[](2);
                bool stablePool1 = _isStablePair(tokenIn, baseStableToken);
                route2[0] = IAerodromeRouter.Route(tokenIn, baseStableToken, stablePool1, fallbackFactory);
                bool stablePool2 = _isStablePair(baseStableToken, tokenOut);
                route2[1] = IAerodromeRouter.Route(baseStableToken, tokenOut, stablePool2, fallbackFactory);
                uint256[] memory outs2 = IAerodromeRouter(fallbackRouter).getAmountsOut(amountIn, route2);
                if (outs2.length > 0) twoHopOut = outs2[outs2.length - 1];
            } else {
                address[] memory path1 = new address[](2);
                path1[0] = tokenIn;
                path1[1] = tokenOut;
                uint256[] memory outs1 = IUniswapV2Router(fallbackRouter).getAmountsOut(amountIn, path1);
                if (outs1.length > 0) directOut = outs1[outs1.length - 1];
                address[] memory path2 = new address[](3);
                path2[0] = tokenIn;
                path2[1] = baseStableToken;
                path2[2] = tokenOut;
                uint256[] memory outs2 = IUniswapV2Router(fallbackRouter).getAmountsOut(amountIn, path2);
                if (outs2.length > 0) twoHopOut = outs2[outs2.length - 1];
            }
        }
        if (twoHopOut > directOut) {
            return (twoHopOut, 1);
        } else {
            return (directOut, 0);
        }
    }

    // ------------------------------
    // Internal Helpers
    // ------------------------------
    function _isStablePair(address tokenX, address tokenY) internal view returns (bool) {
        return (tokenX == baseStableToken || tokenY == baseStableToken);
    }

    function _tickToPriceX96(int24 tick) internal pure returns (uint256 priceScaled) {
        uint160 sqrtPriceX96 = TickMath.getSqrtRatioAtTick(tick);
        uint256 price = uint256(sqrtPriceX96) * uint256(sqrtPriceX96);
        return (price * 1e18) / (2 ** 96);
    }

    // ------------------------------
    // IERC721Receiver Implementation
    // ------------------------------
    function onERC721Received(
        address,
        address,
        uint256,
        bytes calldata
    ) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}
