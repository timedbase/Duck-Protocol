// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Real fork verification of DuckBondingCurve's Universal-Router-based swap routing against LIVE Ink
// state -- the direct counterpart to DuckBondingCurveUniversalRouter.fork.t.sol's Robinhood Chain
// coverage. Ink runs the canonical/vanilla Universal Router (no RouteSigner/ChainedActions
// compliance layer, no minHopPriceX36 field on IV4Router.ExactInputSingleParams), so this exercises
// the OTHER branch of LaunchRoutingExec._swapV4's chain-conditional encoding -- Robinhood's fork
// proved the 6-field/Robinhood-chain-id branch; this proves the 5-field/else branch actually matches
// what a real, non-Robinhood Universal Router deployment expects. Also proves the V3 path's
// "always append an empty minHopPriceX36 array" trick is genuinely harmless against a real vanilla
// V3SwapRouter that never reads it (not just reasoned about from source).
//
// Addresses used here:
// - Universal Router 0x112908daC86e20e7241B0927479Ea3Bf935d1fa0 and WETH
//   0x4200000000000000000000000000000000000006 -- both confirmed via Uniswap's official v4
//   deployments page and Ink's own on-chain verification notes (contract name "UniswapRouter",
//   verified, notes explicitly describing V2/V3/V4 swap routing support).
// - V3 factory 0x640887A9ba3A9C53Ed27D0F7e8246A4F933f3424 -- not listed on Uniswap's V3 deployments
//   docs page (Ink isn't in that list), so pulled directly from the Universal Router's own
//   constructor calldata (its creation transaction, sent through the canonical CREATE2 deployer at
//   block 4580586) and decoded as RouterParameters -- the actual value the deployed router itself
//   uses via UniswapImmutables.UNISWAP_V3_FACTORY, not a guess.
// - USDT0/WETH v3 pool at fee=3000 and native/USDT0 v4 pool at fee=3000/tickSpacing=60 -- both
//   confirmed to carry real liquidity via a live getPool()/liquidity() and StateView scan (the other
//   standard fee tiers on each were either empty or carried orders of magnitude less).
import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {Route, RouteShape} from "duck-lib/LaunchRouting.sol";

contract DuckBondingCurveUniversalRouterInkForkTest is Test {
    address constant WETH                = 0x4200000000000000000000000000000000000006;
    address constant V4_POOL_MANAGER     = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant V4_POSITION_MANAGER = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address constant UNIVERSAL_ROUTER    = 0x112908daC86e20e7241B0927479Ea3Bf935d1fa0;
    address constant INK_USDT0           = 0x0200C29006150606B650577BBE7B6248F58470c1;
    // The WETH/USDT0 fee=3000 v3 pool -- confirmed to carry ~4.0e16 liquidity units, ~7 orders of
    // magnitude more than fee=500 (the only other non-empty standard tier) via a live scan.
    uint24  constant REAL_FEE_TIER       = 3000;
    // The native/USDT0 v4 pool at fee=3000/tickSpacing=60 -- the only standard fee tier with any
    // liquidity at all (100 and 10000 were empty) via a live StateView scan.
    uint24  constant REAL_V4_FEE_TIER     = 3000;
    int24   constant REAL_V4_TICK_SPACING = 60;

    DuckBondingCurve curve;
    DuckBondingCurve curveV4;
    DuckToken tokenImpl;

    address owner    = makeAddr("owner");
    address platform = makeAddr("platform");
    address creator  = makeAddr("creator");
    address buyer    = makeAddr("buyer");

    function setUp() public {
        vm.createSelectFork(vm.envString("INK_RPC_URL"));

        vm.startPrank(owner);
        tokenImpl = new DuckToken(address(0));

        curve = _deployCurve();
        curve.setQuoteTokenAllowed(INK_USDT0, true);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = INK_USDT0;
        uint24[] memory fees = new uint24[](1);
        fees[0] = REAL_FEE_TIER;
        Route[] memory routes = new Route[](1);
        routes[0] = Route({shape: RouteShape.V3_STYLE, enabled: true, path: path, fees: fees, hook: address(0), fee: 0, tickSpacing: 0});
        curve.setRoutes(INK_USDT0, routes);

        curveV4 = _deployCurve();
        curveV4.setQuoteTokenAllowed(INK_USDT0, true);
        Route[] memory v4Routes = new Route[](1);
        v4Routes[0] = Route({
            shape: RouteShape.V4_STYLE, enabled: true, path: new address[](0), fees: new uint24[](0),
            hook: address(0), fee: REAL_V4_FEE_TIER, tickSpacing: REAL_V4_TICK_SPACING
        });
        curveV4.setRoutes(INK_USDT0, v4Routes);
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

    function _createUsdt0QuotedToken(DuckBondingCurve c, uint256 saltSeed) internal returns (address token) {
        DuckBondingCurve.BaseParams memory p;
        p.name = "Fork Test";
        p.symbol = "FORK";
        p.supplyTier = 0;
        p.curveBps = 8_000;
        p.liquidityBps = 2_000;
        p.quoteToken = INK_USDT0;
        p.startVirtualQuote = 1_000e6;
        p.migrationTargetQuote = 10_000e6;
        p.hookFeeBps = 0;
        p.creatorBps = 10_000;
        p.metaURI = "";
        p.salt = _mineVanitySalt(address(c), saltSeed);

        vm.prank(creator);
        token = c.createToken{value: 0.0005 ether}(p);
    }

    function test_RealBuyWithNative_ThroughLiveUniversalRouter_V3Pool() public {
        address token = _createUsdt0QuotedToken(curve, 1);

        vm.prank(buyer);
        curve.buyWithNative{value: 0.01 ether}(token, 0, 0, block.timestamp + 1 hours);

        assertGt(DuckToken(payable(token)).balanceOf(buyer), 0, "buyer should hold real launched tokens after a real swap");
    }

    function test_RealSellForNative_ThroughLiveUniversalRouter_V3Pool() public {
        address token = _createUsdt0QuotedToken(curve, 1);

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
        address token = _createUsdt0QuotedToken(curveV4, 50_000);

        vm.prank(buyer);
        curveV4.buyWithNative{value: 0.01 ether}(token, 0, 0, block.timestamp + 1 hours);

        assertGt(DuckToken(payable(token)).balanceOf(buyer), 0, "buyer should hold real launched tokens after a real v4 swap");
    }

    function test_RealSellForNative_ThroughLiveUniversalRouter_V4Pool() public {
        address token = _createUsdt0QuotedToken(curveV4, 50_000);

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
