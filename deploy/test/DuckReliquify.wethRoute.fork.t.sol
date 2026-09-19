// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {DuckReliquifyToken} from "duck-lib/DuckReliquifyToken.sol";
import {LaunchRouting, Route, RouteShape} from "duck-lib/LaunchRouting.sol";

interface IERC20WethRoute {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}
interface IHookWethRoute { function owner() external view returns (address); function platformWallet() external view returns (address); function addLauncher(address) external; }
interface IVaultFactoryWethRoute { function owner() external view returns (address); function setFamily(address, bool) external; }

// A bare LaunchRouting so the library's buy direction (which Reliquify itself never uses) can be exercised too.
contract RouteHarness is LaunchRouting {
    function setRoute(address token, Route[] calldata r) external { _setRoutes(token, r); }
    function setRouter(address r) external { _setUniversalRouter(r); }
    function acquire(address token, uint256 minOut, address to) external payable returns (uint256 out, bool ok) { return _acquireQuoteToken(token, msg.value, minOut, to); }
    function dispose(address token, uint256 amount, uint256 minOut, address to) external returns (uint256 out, bool ok) { return _disposeQuoteToken(token, amount, minOut, to); }
    receive() external payable {}
}

// FEG is Duck-launched: its only pool is a WETH-paired v4 pool on the live DuckGenesisHook (fee 0, tick spacing 200),
// which the native-ETH V4_STYLE route can't reach. V4_WETH_STYLE can. Everything here runs against the real pool, the
// real Universal Router and the real hook.
contract DuckReliquifyWethRouteForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER    = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant HOOK                = 0x18bd65Fb1c44DD629caD7c7F5B96aD2bCAF76ACC;
    address constant VAULT_FACTORY       = 0x006e53d079BB4c2010682a4896D1950965faD5A5;
    address constant FEG                 = 0x7e22945F9E2e1F6cf7a2E611c4a7718ac8A88888;
    uint24  constant FEG_POOL_FEE        = 0;
    int24   constant FEG_POOL_TICKS      = 200;

    DuckReliquify reliquify;
    IHookWethRoute hook = IHookWethRoute(HOOK);

    address leader  = makeAddr("wr-leader");
    address holder1 = makeAddr("wr-holder1");
    address holder2 = makeAddr("wr-holder2");
    address holder3 = makeAddr("wr-holder3");
    uint256 constant AMT = 5_000_000e18; // ~0.006 ETH at the pool's price: small against its liquidity

    // FEG tracks holder totals for its reward accounting, so conjuring a balance with deal() makes its next transfer
    // underflow. Real transfers only: the live Reliquify proxy holds ~205M FEG from real deposits, and on a fork
    // it can simply be made to send some.
    address constant LIVE_RELIQUIFY = 0xD4B52e1b491B757e04f592c1f995212f93a1ec2D;
    function _giveFeg(address to, uint256 amount) private {
        vm.prank(LIVE_RELIQUIFY);
        IERC20WethRoute(FEG).transfer(to, amount);
        assertGe(IERC20WethRoute(FEG).balanceOf(to), amount, "funded");
    }

    function _wethRoute() private pure returns (Route[] memory r) {
        r = new Route[](1);
        address[] memory path = new address[](1);
        path[0] = WETH;
        r[0] = Route({shape: RouteShape.V4_WETH_STYLE, enabled: true, path: path, fees: new uint24[](0), hook: HOOK, fee: FEG_POOL_FEE, tickSpacing: FEG_POOL_TICKS});
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        DuckReliquifyToken tokenImpl = new DuckReliquifyToken(VAULT_FACTORY);
        DuckReliquify impl = new DuckReliquify();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(DuckReliquify.initialize, (WETH, address(tokenImpl), V4_POOL_MANAGER, V4_POSITION_MANAGER, HOOK, hook.platformWallet()))
        );
        reliquify = DuckReliquify(payable(address(proxy)));
        reliquify.setUniversalRouter(UNIVERSAL_ROUTER);
        reliquify.setVaultFactory(VAULT_FACTORY);
        vm.prank(hook.owner());
        hook.addLauncher(address(reliquify));
        vm.prank(IVaultFactoryWethRoute(VAULT_FACTORY).owner());
        IVaultFactoryWethRoute(VAULT_FACTORY).setFamily(address(reliquify), true);

        _giveFeg(holder1, AMT); _giveFeg(holder2, AMT); _giveFeg(holder3, AMT);
    }

    function _live() private returns (uint256 id) {
        vm.prank(leader);
        id = reliquify.proposeMigration(FEG, 200, 10_000, 0, 0);
        address[] memory a = new address[](3);
        a[0] = holder1; a[1] = holder2; a[2] = holder3;
        uint256[] memory b = new uint256[](3);
        b[0] = AMT; b[1] = AMT; b[2] = AMT;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, a, b);
        reliquify.finalizeSnapshot(id);
        vm.stopPrank();
        reliquify.approveMigration(id, "Reliquified FEG", "rFEG", "");
    }

    function _deposit(address who, uint256 id, bool post) private {
        vm.startPrank(who);
        IERC20WethRoute(FEG).approve(address(reliquify), AMT);
        if (post) reliquify.depositPostSeed(id, AMT, 0, 0); else reliquify.depositPreSeed(id, AMT);
        vm.stopPrank();
    }

    function test_Seed_SellsFegThroughTheWethPairedV4Pool() public {
        reliquify.setRoutes(FEG, _wethRoute());
        uint256 id = _live();
        _deposit(holder1, id, false);
        _deposit(holder2, id, false);

        uint256 wethBefore = IERC20WethRoute(WETH).balanceOf(address(reliquify));
        vm.recordLogs();
        reliquify.seedPool(id, 1);
        Vm.Log[] memory logs = vm.getRecordedLogs();

        uint256 raised;
        bytes32 topic = keccak256("PoolSeeded(uint256,bytes32,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(reliquify) && logs[i].topics[0] == topic) (, raised) = abi.decode(logs[i].data, (bytes32, uint256));
        }
        assertGt(raised, 0, "the sale must have produced ETH");
        (,,,,,, DuckReliquify.MigrationStatus status) = reliquify.getMigration(id);
        assertEq(uint8(status), 3, "Seeded");
        // The swap paid WETH, which was unwrapped, then wrapped again and put in the new pool. The full-range mint
        // leaves a sliver of rounding dust (it is rescuable by the owner); the sale itself must strand nothing.
        uint256 dust = IERC20WethRoute(WETH).balanceOf(address(reliquify)) - wethBefore;
        assertLt(dust, raised / 1000, "at most 0.1% of the proceeds is left as LP rounding dust");
        emit log_named_uint("LP rounding dust (wei)", dust);
        assertEq(address(reliquify).balance, 0, "no ETH left behind");
        assertEq(IERC20WethRoute(FEG).balanceOf(address(reliquify)), 0, "all deposited FEG was sold");
        emit log_named_decimal_uint("ETH raised by selling 10M FEG", raised, 18);
    }

    function test_PostSeedDeposit_SellsThroughTheSameRoute() public {
        reliquify.setRoutes(FEG, _wethRoute());
        uint256 id = _live();
        _deposit(holder1, id, false);
        _deposit(holder2, id, false);
        reliquify.seedPool(id, 1);

        _deposit(holder3, id, true); // sells, then buys back and burns with the proceeds
        assertEq(IERC20WethRoute(FEG).balanceOf(address(reliquify)), 0, "sold");
        assertEq(address(reliquify).balance, 0, "no ETH left behind");
    }

    function test_FloorIsEnforced() public {
        reliquify.setRoutes(FEG, _wethRoute());
        uint256 id = _live();
        _deposit(holder1, id, false);
        _deposit(holder2, id, false);
        // An absurd minimum: the route's swap reverts, so no route succeeds.
        vm.expectRevert();
        reliquify.seedPool(id, 1_000 ether);
    }

    function test_MalformedRoute_IsSkipped_NotSilentlyUsed() public {
        Route[] memory r = _wethRoute();
        address[] memory two = new address[](2);
        two[0] = WETH; two[1] = FEG;
        r[0].path = two; // the shape needs exactly one address
        reliquify.setRoutes(FEG, r);
        uint256 id = _live();
        _deposit(holder1, id, false);
        _deposit(holder2, id, false);
        vm.expectRevert(DuckReliquify.SellRouteNotConfigured.selector);
        reliquify.seedPool(id, 0);
    }

    function test_LibraryBuysAndSellsBothDirections() public {
        RouteHarness h = new RouteHarness();
        h.setRouter(UNIVERSAL_ROUTER);
        h.setRoute(FEG, _wethRoute());

        address buyer = makeAddr("wr-buyer");
        (uint256 got, bool ok) = h.acquire{value: 0.001 ether}(FEG, 1, buyer);
        assertTrue(ok, "buy route");
        assertGt(got, 0);
        assertEq(IERC20WethRoute(FEG).balanceOf(buyer), got, "FEG delivered to the recipient");
        assertEq(IERC20WethRoute(WETH).balanceOf(address(h)), 0, "no WETH left in the caller");

        _giveFeg(address(h), 1_000_000e18);
        uint256 ethBefore = address(h).balance;
        (uint256 out, bool sold) = h.dispose(FEG, 1_000_000e18, 1, address(h));
        assertTrue(sold, "sell route");
        assertGt(out, 0);
        assertEq(address(h).balance - ethBefore, out, "ETH, not WETH, comes back");
        assertEq(IERC20WethRoute(WETH).balanceOf(address(h)), 0, "unwrapped");

        // A sell to someone else lands as native ETH in their account.
        _giveFeg(address(h), 1_000_000e18);
        address seller = makeAddr("wr-seller");
        (uint256 out2, bool sold2) = h.dispose(FEG, 1_000_000e18, 1, seller);
        assertTrue(sold2);
        assertEq(seller.balance, out2, "recipient receives native ETH");
    }
}
