// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";

contract DuckVaultConfigTest is Test {
    DuckVaultConfig config;
    address owner = makeAddr("owner");
    address stranger = makeAddr("stranger");

    function setUp() public {
        DuckVaultConfig impl = new DuckVaultConfig();
        ERC1967Proxy proxy = new ERC1967Proxy(address(impl), abi.encodeCall(DuckVaultConfig.initialize, (owner)));
        config = DuckVaultConfig(address(proxy));
    }

    function test_SetMaxLtvBpsRejectsAtOrAboveLiquidationThreshold() public {

        uint16 threshold = config.liquidationThresholdBps();

        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setMaxLtvBps(threshold);

        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setMaxLtvBps(0);

        vm.prank(owner);
        config.setMaxLtvBps(threshold - 1);
        assertEq(config.maxLtvBps(), threshold - 1);
    }

    function test_SetLiquidationThresholdBpsRejectsAtOrBelowMaxLtv() public {
        uint16 maxLtv = config.maxLtvBps();

        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setLiquidationThresholdBps(maxLtv);

        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setLiquidationThresholdBps(10_001);

        vm.prank(owner);
        config.setLiquidationThresholdBps(maxLtv + 1);
        assertEq(config.liquidationThresholdBps(), maxLtv + 1);
    }

    function test_SetOracleWindowsRejectsLongNotStrictlyAboveShort() public {
        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidWindow.selector);
        config.setOracleWindows(1800, 1800);

        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidWindow.selector);
        config.setOracleWindows(0, 100);

        vm.prank(owner);
        config.setOracleWindows(900, 3600);
        assertEq(config.shortWindow(), 900);
        assertEq(config.longWindow(), 3600);
    }

    function test_SetInterestCurveRejectsZeroOrMaxKink() public {
        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setInterestCurve(0, 200, 800, 10_000);

        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setInterestCurve(10_000, 200, 800, 10_000);
    }

    function test_SetMaxPoolDepthShareBpsRejectsZeroAndAboveDenom() public {
        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setMaxPoolDepthShareBps(0);

        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setMaxPoolDepthShareBps(10_001);

        vm.prank(owner);
        config.setMaxPoolDepthShareBps(5000);
        assertEq(config.maxPoolDepthShareBps(), 5000);
    }

    function test_SetMaxCirculatingShareBpsRejectsZeroAndAboveDenom() public {
        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setMaxCirculatingShareBps(0);

        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setMaxCirculatingShareBps(10_001);

        vm.prank(owner);
        config.setMaxCirculatingShareBps(2500);
        assertEq(config.maxCirculatingShareBps(), 2500);
    }

    function test_BuybackBpsAllowsZeroButNotAboveDenom() public {
        vm.prank(owner);
        config.setBuybackBps(0);
        assertEq(config.buybackBps(), 0);

        vm.prank(owner);
        vm.expectRevert(DuckVaultConfig.InvalidBps.selector);
        config.setBuybackBps(10_001);
    }

    function test_NonOwnerCannotCallAnySetter() public {
        vm.startPrank(stranger);

        vm.expectRevert();
        config.setMaxLtvBps(2000);

        vm.expectRevert();
        config.setLiquidationThresholdBps(8000);

        vm.expectRevert();
        config.setMaxPoolDepthShareBps(1000);

        vm.expectRevert();
        config.setMaxCirculatingShareBps(1000);

        vm.expectRevert();
        config.setOracleWindows(900, 3600);

        vm.stopPrank();
    }
}
