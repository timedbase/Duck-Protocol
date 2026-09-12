// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {DuckVaultMath} from "duck-lending/DuckVaultMath.sol";

contract DuckVaultMathTest is Test {
    function test_TickZeroIsRawUnitParity() public pure {

        assertEq(DuckVaultMath.tickToPricePerToken(0, true, 18), 1e18);
        assertEq(DuckVaultMath.tickToPricePerToken(0, false, 18), 1e18);
        assertEq(DuckVaultMath.tickToPricePerToken(0, true, 6), 1e6);
        assertEq(DuckVaultMath.tickToPricePerToken(0, false, 6), 1e6);
    }

    function test_PositiveTickIncreasesPriceWhenTokenIsCurrency0() public pure {

        uint256 priceAtZero = DuckVaultMath.tickToPricePerToken(0, true, 18);
        uint256 priceAtPositive = DuckVaultMath.tickToPricePerToken(10_000, true, 18);
        assertGt(priceAtPositive, priceAtZero);
    }

    function test_PositiveTickDecreasesPriceWhenTokenIsCurrency1() public pure {

        uint256 priceAtZero = DuckVaultMath.tickToPricePerToken(0, false, 18);
        uint256 priceAtPositive = DuckVaultMath.tickToPricePerToken(10_000, false, 18);
        assertLt(priceAtPositive, priceAtZero);
    }

    function test_InverseRoundTripApproximatelyOne() public pure {

        int24 tick = 5_000;
        uint256 priceFwd = DuckVaultMath.tickToPricePerToken(tick, true, 18);
        uint256 priceInv = DuckVaultMath.tickToPricePerToken(tick, false, 18);
        uint256 product = (priceFwd * priceInv) / 1e18;
        assertApproxEqRel(product, 1e18, 0.0001e18);
    }

    function test_UtilizationBpsZeroWhenPoolEmpty() public pure {
        assertEq(DuckVaultMath.utilizationBps(0, 0), 0);
    }

    function test_UtilizationBpsHalf() public pure {
        assertEq(DuckVaultMath.utilizationBps(50, 50), 5000);
    }

    function test_AccrueInterestZeroWhenNoBorrows() public pure {
        (uint256 interest, uint256 idx) = DuckVaultMath.accrueInterest(0, 1e18, 1000, 1 days);
        assertEq(interest, 0);
        assertEq(idx, 1e18);
    }

    function test_IsLiquidatableAtExactThreshold() public pure {

        assertFalse(DuckVaultMath.isLiquidatable(7500, 10000, 7500));
        assertTrue(DuckVaultMath.isLiquidatable(7501, 10000, 7500));
    }

    function test_ComputeSeizeWithinCollateral() public pure {

        (uint256 seize, uint256 badDebt) = DuckVaultMath.computeSeize(100 ether, 1e18, 18, 800, 1000 ether);
        assertEq(seize, 108 ether);
        assertEq(badDebt, 0);
    }

    function test_ComputeSeizeClampsAtInsufficientCollateral() public pure {
        (uint256 seize, uint256 badDebt) = DuckVaultMath.computeSeize(100 ether, 1e18, 18, 800, 50 ether);
        assertEq(seize, 50 ether, "must seize exactly what's posted, no more");
        assertGt(badDebt, 0, "shortfall must be reported, not silently absorbed");
    }
}
