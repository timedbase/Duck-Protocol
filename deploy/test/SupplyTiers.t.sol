// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {SupplyTiers} from "duck-lib/SupplyTiers.sol";

contract SupplyTiersHarness {
    function resolve(uint8 tier) external pure returns (uint256) {
        return SupplyTiers.resolve(tier);
    }
}

contract SupplyTiersTest is Test {
    SupplyTiersHarness harness;

    function setUp() public {
        harness = new SupplyTiersHarness();
    }

    function test_AllSevenTiersResolveToTheDocumentedValues() public view {
        assertEq(harness.resolve(0), 1_000_000_000e18, "tier 0 = 1B");
        assertEq(harness.resolve(1), 10_000_000_000e18, "tier 1 = 10B");
        assertEq(harness.resolve(2), 100_000_000_000e18, "tier 2 = 100B");
        assertEq(harness.resolve(3), 1_000_000_000_000e18, "tier 3 = 1T");
        assertEq(harness.resolve(4), 10_000_000_000_000e18, "tier 4 = 10T");
        assertEq(harness.resolve(5), 100_000_000_000_000e18, "tier 5 = 100T");
        assertEq(harness.resolve(6), 1_000_000_000_000_000e18, "tier 6 = 1Q");
    }

    function test_EachTierIsExactlyTenTimesThePrevious() public view {
        for (uint8 i = 1; i <= 6; i++) {
            assertEq(harness.resolve(i), harness.resolve(i - 1) * 10, "each tier must be exactly 10x the one before it");
        }
    }

    function test_RevertsOnAnyTierAboveSix() public {
        vm.expectRevert(abi.encodeWithSelector(SupplyTiers.InvalidSupplyTier.selector, 7));
        harness.resolve(7);

        vm.expectRevert(abi.encodeWithSelector(SupplyTiers.InvalidSupplyTier.selector, 255));
        harness.resolve(255);
    }
}
