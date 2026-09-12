// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckVaultMath

import {V4Math} from "duck-lib/V4Math.sol";

library DuckVaultMath {
    uint256 internal constant WAD = 1e18;
    uint256 internal constant BPS_DENOM = 10_000;
    uint256 internal constant SECONDS_PER_YEAR = 365 days;
    uint256 internal constant Q192 = 1 << 192;

    error ZeroPrice();

    function tickToPricePerToken(int24 tick, bool tokenIsCurrency0, uint8 tokenDecimals)
        internal pure returns (uint256 price)
    {
        uint160 sqrtPriceX96 = V4Math.getSqrtPriceAtTick(tick);
        uint256 scale = 10 ** tokenDecimals;
        if (tokenIsCurrency0) {

            uint256 step = V4Math.mulDivFull(sqrtPriceX96, scale, 1);
            price = V4Math.mulDivFull(step, sqrtPriceX96, Q192);
        } else {

            uint256 step = V4Math.mulDivFull(Q192, scale, sqrtPriceX96);
            price = V4Math.mulDivFull(step, 1, sqrtPriceX96);
        }
    }

    int24 internal constant FULL_RANGE_TICK = 887_200;

    function poolCurrencyDepth(int24 tick, uint128 liquidity, bool tokenIsCurrency0)
        internal pure returns (uint256 currencyDepth)
    {
        if (liquidity == 0) return 0;
        uint160 sqrtCurrent = V4Math.getSqrtPriceAtTick(tick);
        if (tokenIsCurrency0) {

            uint160 sqrtLower = V4Math.getSqrtPriceAtTick(-FULL_RANGE_TICK);
            currencyDepth = V4Math.getAmount1ForLiquidity(sqrtLower, sqrtCurrent, liquidity);
        } else {

            uint160 sqrtUpper = V4Math.getSqrtPriceAtTick(FULL_RANGE_TICK);
            currencyDepth = V4Math.getAmount0ForLiquidity(sqrtCurrent, sqrtUpper, liquidity);
        }
    }

    function utilizationBps(uint256 totalBorrows, uint256 totalReserves) internal pure returns (uint256) {
        uint256 pool = totalReserves + totalBorrows;
        if (pool == 0) return 0;
        return (totalBorrows * BPS_DENOM) / pool;
    }

    function borrowRateBps(
        uint256 utilBps, uint16 kinkBps, uint16 baseRateBps, uint16 slope1Bps, uint16 slope2Bps
    ) internal pure returns (uint256) {
        if (utilBps <= kinkBps) {
            return baseRateBps + (slope1Bps * utilBps) / kinkBps;
        }
        uint256 excessUtil = utilBps - kinkBps;
        uint256 maxExcess = BPS_DENOM - kinkBps;
        return baseRateBps + slope1Bps + (slope2Bps * excessUtil) / maxExcess;
    }

    function accrueInterest(
        uint256 totalBorrows, uint256 borrowIndex, uint256 annualRateBps, uint256 elapsedSeconds
    ) internal pure returns (uint256 interestAccrued, uint256 newBorrowIndex) {
        if (totalBorrows == 0 || elapsedSeconds == 0) return (0, borrowIndex);

        uint256 growthWad = (annualRateBps * WAD * elapsedSeconds) / (BPS_DENOM * SECONDS_PER_YEAR);
        interestAccrued = (totalBorrows * growthWad) / WAD;
        newBorrowIndex = borrowIndex + (borrowIndex * growthWad) / WAD;
    }

    function currentDebt(uint128 principal, uint256 indexSnap, uint256 currentIndex) internal pure returns (uint256) {
        if (principal == 0) return 0;
        return (uint256(principal) * currentIndex) / indexSnap;
    }

    function collateralValue(uint256 collateralAmount, uint256 price, uint8 tokenDecimals) internal pure returns (uint256) {
        if (price == 0) revert ZeroPrice();
        return (collateralAmount * price) / (10 ** tokenDecimals);
    }

    function isLiquidatable(uint256 debt, uint256 collateralValueAtLiqPrice, uint16 liquidationThresholdBps)
        internal pure returns (bool)
    {
        return debt * BPS_DENOM > collateralValueAtLiqPrice * liquidationThresholdBps;
    }

    function healthFactorBps(uint256 debt, uint256 collateralValueAtLiqPrice, uint16 liquidationThresholdBps)
        internal pure returns (uint256)
    {
        if (debt == 0) return type(uint256).max;
        return (collateralValueAtLiqPrice * liquidationThresholdBps) / debt;
    }

    function computeSeize(
        uint256 repayAmount, uint256 price, uint8 tokenDecimals, uint16 liquidationBonusBps, uint128 postedCollateral
    ) internal pure returns (uint256 seizeAmount, uint256 badDebtCurrency) {
        if (price == 0) revert ZeroPrice();
        uint256 baseSeize = (repayAmount * (10 ** tokenDecimals)) / price;
        uint256 wantSeize = baseSeize + (baseSeize * liquidationBonusBps) / BPS_DENOM;
        if (wantSeize >= postedCollateral) {

            seizeAmount = postedCollateral;
            uint256 coveredRepay = (postedCollateral * price) / ((10 ** tokenDecimals) + (10 ** tokenDecimals) * liquidationBonusBps / BPS_DENOM);
            badDebtCurrency = repayAmount > coveredRepay ? repayAmount - coveredRepay : 0;
        } else {
            seizeAmount = wantSeize;
            badDebtCurrency = 0;
        }
    }
}
