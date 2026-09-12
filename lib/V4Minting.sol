// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — V4Minting

import {PoolKey} from "./LaunchRouting.sol";
import {V4Math} from "./V4Math.sol";

interface IV4PositionManagerMint {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
}

interface IDuckHookV4Mint {
    function registerPool(
        PoolKey calldata key, address token, address creator, uint256 hookFeeBps,
        uint16 creatorBps, uint16 vaultBps, uint16 burnBps
    ) external;
}

library V4Minting {
    error PoolAlreadyExists();

    int24   private constant MIN_TICK = -887_200;
    int24   private constant MAX_TICK =  887_200;

    // Setup only: initializes the pool, registers it with the hook, and computes the full-range
    // liquidity these amounts are worth. Mints nothing -- the caller takes (key, ticks, liquidity)
    // and adds it to the PoolManager directly (see LaunchRouting._mintFullRangeDirect).
    struct MintFullRangeSetupParams {
        address positionManager;
        address hook;
        address token0;
        address token1;
        uint24  fee;
        int24   tickSpacing;
        address token;
        address creator;
        uint256 amount0;
        uint256 amount1;
        uint256 hookFeeBps;
        uint16  creatorBps;
        uint16  vaultBps;
        uint16  burnBps;
    }

    function setupFullRangePool(MintFullRangeSetupParams calldata p)
        external returns (bytes32 poolId, PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        key = PoolKey({
            currency0:   p.token0,
            currency1:   p.token1,
            fee:         p.fee,
            tickSpacing: p.tickSpacing,
            hooks:       p.hook
        });

        int24 tick = IV4PositionManagerMint(p.positionManager).initializePool(
            key, V4Math.sqrtPriceX96FromAmounts(p.amount0, p.amount1)
        );
        if (tick == type(int24).max) revert PoolAlreadyExists();
        poolId = keccak256(abi.encode(key));
        IDuckHookV4Mint(p.hook).registerPool(key, p.token, p.creator, p.hookFeeBps, p.creatorBps, p.vaultBps, p.burnBps);

        tickLower = MIN_TICK;
        tickUpper = MAX_TICK;
        liquidity = V4Math.getLiquidityForAmounts(
            V4Math.getSqrtPriceAtTick(tick), V4Math.getSqrtPriceAtTick(MIN_TICK), V4Math.getSqrtPriceAtTick(MAX_TICK),
            p.amount0, p.amount1
        );
    }

    // Bundled into a struct rather than 13 loose parameters -- that many locals/params in one
    // function can hit "stack too deep" even under via-IR (a real error hit while adding the
    // creatorBps/burnBps split), same reasoning as MintFullRangeSetupParams above.
    struct RegisterPoolParams {
        address positionManager;
        address hook;
        address token0;
        address token1;
        uint24  fee;
        int24   tickSpacing;
        uint160 sqrtPriceX96;
        address token;
        address creator;
        uint256 hookFeeBps;
        uint16  creatorBps;
        uint16  vaultBps;
        uint16  burnBps;
    }

    function initAndRegisterPool(RegisterPoolParams calldata p)
        external returns (int24 tick, bytes32 poolId, PoolKey memory key)
    {
        key = PoolKey({currency0: p.token0, currency1: p.token1, fee: p.fee, tickSpacing: p.tickSpacing, hooks: p.hook});
        tick = IV4PositionManagerMint(p.positionManager).initializePool(key, p.sqrtPriceX96);
        if (tick == type(int24).max) revert PoolAlreadyExists();
        poolId = keccak256(abi.encode(key));
        IDuckHookV4Mint(p.hook).registerPool(key, p.token, p.creator, p.hookFeeBps, p.creatorBps, p.vaultBps, p.burnBps);
    }

    uint160 private constant MIN_SQRT_PRICE = 4295128739;
    uint160 private constant MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;

    error InvalidTickRange();

    function computeOneSidedLiquidity(int24 currentTick, bool tokenIsCurrency1, int24 tickSpacing, uint256 totalSupply)
        external pure returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        if (tokenIsCurrency1) {
            tickLower = MIN_TICK;
            tickUpper = _floorToTickSpacing(currentTick, tickSpacing);
            if (tickLower >= tickUpper) revert InvalidTickRange();
            liquidity = V4Math.getLiquidityForAmount1(MIN_SQRT_PRICE, V4Math.getSqrtPriceAtTick(tickUpper), totalSupply);
        } else {
            tickLower = _floorToTickSpacing(currentTick, tickSpacing) + tickSpacing;
            tickUpper = MAX_TICK;
            if (tickLower >= tickUpper) revert InvalidTickRange();
            liquidity = V4Math.getLiquidityForAmount0(V4Math.getSqrtPriceAtTick(tickLower), MAX_SQRT_PRICE, totalSupply);
        }
    }

    function _floorToTickSpacing(int24 tick, int24 tickSpacing) private pure returns (int24) {
        int24 compressed = tick / tickSpacing;
        if (tick < 0 && tick % tickSpacing != 0) compressed--;
        return compressed * tickSpacing;
    }
}
