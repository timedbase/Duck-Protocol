// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Real fork verification of DuckBondingCurve's Universal-Router-based swap routing (this session's
// LaunchRouting rewrite) against LIVE Robinhood Chain state: the actual deployed Universal Router
// (0x8876789976DECbFCbBbE364623c63652DB8C0904), the actual canonical Permit2, and a real WETH/USDG
// Uniswap v3 pool with real liquidity (fee=100, chosen because it carries far more liquidity than
// the other WETH/USDG fee tiers on this chain -- confirmed via a direct getPool()/liquidity() scan
// against this same RPC). This is the direct counterpart to DuckBondingCurveUniversalRouter.t.sol's
// mock-based tests: those prove the calldata shape is internally consistent; this proves it's
// actually accepted end-to-end by the real deployed Universal Router and produces a real swap
// against real liquidity.
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {Route, RouteShape} from "duck-lib/LaunchRouting.sol";

contract DuckBondingCurveUniversalRouterForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER    = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant RH_USDG             = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    // The WETH/RH_USDG fee=100 v3 pool -- confirmed to carry ~17.4 v3 liquidity units, an order of
    // magnitude more than the 500/3000/10000 tiers, via a live getPool()/liquidity() scan.
    uint24  constant REAL_FEE_TIER       = 100;
    // The native/RH_USDG v4 pool at fee=100/tickSpacing=1 -- confirmed to carry ~3.74e17 v4
    // liquidity units, ~13x the next-best of the standard fee tiers, via a live StateView scan.
    uint24  constant REAL_V4_FEE_TIER     = 100;
    int24   constant REAL_V4_TICK_SPACING = 1;

    DuckBondingCurve curve;
    DuckBondingCurve curveV4;
    DuckToken tokenImpl;

    address owner    = makeAddr("owner");
    address platform = makeAddr("platform");
    address creator  = makeAddr("creator");
    address buyer    = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        vm.startPrank(owner);
        tokenImpl = new DuckToken(address(0));

        curve = _deployCurve();
        curve.setQuoteTokenAllowed(RH_USDG, true);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = RH_USDG;
        uint24[] memory fees = new uint24[](1);
        fees[0] = REAL_FEE_TIER;
        Route[] memory routes = new Route[](1);
        routes[0] = Route({shape: RouteShape.V3_STYLE, enabled: true, path: path, fees: fees, hook: address(0), fee: 0, tickSpacing: 0});
        curve.setRoutes(RH_USDG, routes);

        curveV4 = _deployCurve();
        curveV4.setQuoteTokenAllowed(RH_USDG, true);
        Route[] memory v4Routes = new Route[](1);
        v4Routes[0] = Route({
            shape: RouteShape.V4_STYLE, enabled: true, path: new address[](0), fees: new uint24[](0),
            hook: address(0), fee: REAL_V4_FEE_TIER, tickSpacing: REAL_V4_TICK_SPACING
        });
        curveV4.setRoutes(RH_USDG, v4Routes);
        vm.stopPrank();

        vm.deal(creator, 10 ether);
        vm.deal(buyer, 10 ether);
    }

    function _deployCurve() internal returns (DuckBondingCurve c) {
        DuckBondingCurve impl = new DuckBondingCurve();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(DuckBondingCurve.initialize, (
                WETH, V4_POSITION_MANAGER, V4_POOL_MANAGER, address(0),
                platform, address(tokenImpl)
            ))
        );
        c = DuckBondingCurve(payable(address(proxy)));
        c.setUniversalRouter(UNIVERSAL_ROUTER);
    }

    function _mineVanitySalt(address deployer, uint256 seed) internal view returns (bytes32 userSalt) {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            address(tokenImpl),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = 0; i < 200_000; i++) {
            userSalt = bytes32(seed + i);
            bytes32 salt = keccak256(abi.encode(creator, userSalt));
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff), deployer, salt, initCodeHash
            )))));
            if (uint16(uint160(predicted)) == 0x8888) return userSalt;
        }
        revert("salt not found");
    }

    function _createUsdgQuotedToken(DuckBondingCurve c, uint256 saltSeed) internal returns (address token) {
        DuckBondingCurve.BaseParams memory p;
        p.name = "Fork Test";
        p.symbol = "FORK";
        p.supplyTier = 0;
        p.curveBps = 8_000;
        p.liquidityBps = 2_000;
        p.quoteToken = RH_USDG;
        p.startVirtualQuote = 1_000e18;
        p.migrationTargetQuote = 10_000e18;
        p.hookFeeBps = 0;
        p.creatorBps = 10_000;
        p.metaURI = "";
        p.salt = _mineVanitySalt(address(c), saltSeed);

        vm.prank(creator);
        token = c.createToken{value: 0.0005 ether}(p);
    }

    function test_RealBuyWithNative_ThroughLiveUniversalRouter_V3Pool() public {
        address token = _createUsdgQuotedToken(curve, 1);

        vm.prank(buyer);
        curve.buyWithNative{value: 0.01 ether}(token, 0, 0, block.timestamp + 1 hours);

        assertGt(DuckToken(payable(token)).balanceOf(buyer), 0, "buyer should hold real launched tokens after a real swap");
    }

    function test_RealSellForNative_ThroughLiveUniversalRouter_V3Pool() public {
        address token = _createUsdgQuotedToken(curve, 1);

        vm.prank(buyer);
        curve.buyWithNative{value: 0.01 ether}(token, 0, 0, block.timestamp + 1 hours);

        uint256 tokenBal = DuckToken(payable(token)).balanceOf(buyer);
        assertGt(tokenBal, 0, "sanity: buyer must hold tokens before selling");

        vm.startPrank(buyer);
        DuckToken(payable(token)).approve(address(curve), tokenBal);
        uint256 nativeBefore = buyer.balance;
        curve.sellForNative(token, tokenBal, 0, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGt(buyer.balance, nativeBefore, "seller should receive real native ETH back through the live Universal Router");
    }

    function test_RealBuyWithNative_ThroughLiveUniversalRouter_V4Pool() public {
        address token = _createUsdgQuotedToken(curveV4, 50_000);

        vm.prank(buyer);
        curveV4.buyWithNative{value: 0.01 ether}(token, 0, 0, block.timestamp + 1 hours);

        assertGt(DuckToken(payable(token)).balanceOf(buyer), 0, "buyer should hold real launched tokens after a real v4 swap");
    }

    function test_RealSellForNative_ThroughLiveUniversalRouter_V4Pool() public {
        address token = _createUsdgQuotedToken(curveV4, 50_000);

        vm.prank(buyer);
        curveV4.buyWithNative{value: 0.01 ether}(token, 0, 0, block.timestamp + 1 hours);

        uint256 tokenBal = DuckToken(payable(token)).balanceOf(buyer);
        assertGt(tokenBal, 0, "sanity: buyer must hold tokens before selling");

        vm.startPrank(buyer);
        DuckToken(payable(token)).approve(address(curveV4), tokenBal);
        uint256 nativeBefore = buyer.balance;
        curveV4.sellForNative(token, tokenBal, 0, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGt(buyer.balance, nativeBefore, "seller should receive real native ETH back through the live Universal Router v4 path");
    }
}
