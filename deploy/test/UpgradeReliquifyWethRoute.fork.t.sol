// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {UpgradeReliquifyWethRoute} from "../script/UpgradeReliquifyWethRoute.s.sol";
import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {Route, RouteShape} from "duck-lib/LaunchRouting.sol";

// The upgrade exactly as the script broadcasts it, against the LIVE Robinhood proxy and its real migration #0 (FEG).
contract UpgradeReliquifyWethRouteForkTest is Test {
    address constant PROXY = 0xD4B52e1b491B757e04f592c1f995212f93a1ec2D;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;
    address constant FEG   = 0x7e22945F9E2e1F6cf7a2E611c4a7718ac8A88888;
    address constant WETH  = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant HOOK  = 0x18bd65Fb1c44DD629caD7c7F5B96aD2bCAF76ACC;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    DuckReliquify live = DuckReliquify(payable(PROXY));

    function setUp() public { vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL")); }

    function test_Upgrade_KeepsEveryPieceOfLiveState() public {
        address ownerBefore = live.owner();
        uint256 countBefore = live.migrationCount();
        uint256 feeBefore = live.reliquifyFee();
        address hookBefore = live.v4Hook();
        address tokenImplBefore = live.tokenImpl();
        address vaultFactoryBefore = live.vaultFactory();
        (address leader, address oldToken, address newToken, uint256 eligible, uint256 deposited, uint256 reserved, DuckReliquify.MigrationStatus st) = live.getMigration(0);
        bool pausedBefore = live.paused(0);
        assertEq(oldToken, FEG);

        address impl = new UpgradeReliquifyWethRoute().upgradeAs(OWNER);

        assertEq(address(uint160(uint256(vm.load(PROXY, IMPL_SLOT)))), impl, "the proxy points at the new implementation");
        assertEq(live.owner(), ownerBefore);
        assertEq(live.migrationCount(), countBefore);
        assertEq(live.reliquifyFee(), feeBefore);
        assertEq(live.v4Hook(), hookBefore);
        assertEq(live.tokenImpl(), tokenImplBefore);
        assertEq(live.vaultFactory(), vaultFactoryBefore);
        (address l2, address o2, address n2, uint256 e2, uint256 d2, uint256 r2, DuckReliquify.MigrationStatus s2) = live.getMigration(0);
        assertEq(l2, leader); assertEq(o2, oldToken); assertEq(n2, newToken);
        assertEq(e2, eligible); assertEq(d2, deposited); assertEq(r2, reserved);
        assertEq(uint8(s2), uint8(st));
        assertEq(live.paused(0), pausedBefore, "still paused: the upgrade must not reopen deposits");
        emit log_named_decimal_uint("FEG deposited (kept)", d2, 18);
    }

    function test_AfterUpgrade_OwnerCanSetFegsRoute() public {
        new UpgradeReliquifyWethRoute().upgradeAs(OWNER);

        Route[] memory r = new Route[](1);
        address[] memory path = new address[](1);
        path[0] = WETH;
        r[0] = Route({shape: RouteShape.V4_WETH_STYLE, enabled: true, path: path, fees: new uint24[](0), hook: HOOK, fee: 0, tickSpacing: 200});
        vm.prank(OWNER);
        live.setRoutes(FEG, r);

        (RouteShape shape, bool enabled, address hook, uint24 fee, int24 ts) = live.routes(FEG, 0);
        assertEq(uint8(shape), 2);
        assertTrue(enabled);
        assertEq(hook, HOOK);
        assertEq(fee, 0);
        assertEq(int256(ts), 200);
        vm.expectRevert(); live.routes(FEG, 1); // exactly one route
    }

    function test_OnlyTheOwnerCanUpgrade() public {
        address impl = address(new DuckReliquify());
        vm.prank(makeAddr("not-owner"));
        vm.expectRevert();
        live.upgradeToAndCall(impl, "");
    }
}
