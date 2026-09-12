// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Swaps through every route in RouteTables against LIVE chain state, one route at a time and in
// both directions, via the deployed DuckBondingCurve proxy's own executeSwapRoute entry point.
// Pranking as the proxy satisfies its msg.sender == address(this) guard, so each fallback is
// proven on its own rather than only whichever route happens to succeed first. Buys land the
// quote token on the proxy; the sell then spends exactly those tokens back to native, so no
// token balances have to be synthesised.
import {Test, console} from "forge-std/Test.sol";
import {Route, ILaunchRoutingSelf} from "duck-lib/LaunchRouting.sol";
import {RouteTables} from "../script/RouteTables.sol";

abstract contract SetRoutesForkBase is Test {
    address constant CURVE = 0xcE71ce995C2A3657aF9bEC45bA1Ee2E8fA2ef5eF;
    uint256 constant BUY   = 0.01 ether;

    address seller = makeAddr("seller");

    function _exerciseAll(address universalRouter) internal {
        RouteTables.TokenRoutes[] memory t = RouteTables.forChain(block.chainid);
        uint256 failures;
        uint256 checked;

        for (uint256 i; i < t.length; ++i) {
            for (uint256 j; j < t[i].routes.length; ++j) {
                ++checked;
                Route memory r = t[i].routes[j];

                vm.deal(CURVE, CURVE.balance + BUY);
                vm.deal(address(this), BUY);
                vm.prank(CURVE);
                uint256 quoteOut;
                try ILaunchRoutingSelf(CURVE).executeSwapRoute{value: BUY}(
                    r, universalRouter, t[i].token, true, BUY, 0, CURVE
                ) returns (uint256 out) {
                    quoteOut = out;
                } catch {
                    console.log("FAIL buy ", t[i].symbol, j);
                    ++failures;
                    continue;
                }
                if (quoteOut == 0) {
                    console.log("FAIL buy returned 0", t[i].symbol, j);
                    ++failures;
                    continue;
                }

                uint256 before = seller.balance;
                vm.prank(CURVE);
                try ILaunchRoutingSelf(CURVE).executeSwapRoute(
                    r, universalRouter, t[i].token, false, quoteOut, 0, seller
                ) returns (uint256 nativeOut) {
                    if (nativeOut == 0 || seller.balance <= before) {
                        console.log("FAIL sell returned 0", t[i].symbol, j);
                        ++failures;
                    } else {
                        console.log("ok", t[i].symbol, j);
                        console.log("   quote out / native back (wei):", quoteOut, nativeOut);
                    }
                } catch {
                    console.log("FAIL sell", t[i].symbol, j);
                    ++failures;
                }
            }
        }

        console.log("routes checked:", checked, "failures:", failures);
        assertEq(failures, 0, "every configured route must swap both ways against live liquidity");
    }
}

contract SetRoutesRobinhoodForkTest is SetRoutesForkBase {
    function setUp() public {
        vm.createSelectFork(vm.envOr("ROBINHOOD_RPC_URL", string("https://rpc.mainnet.chain.robinhood.com")));
    }

    function test_EveryConfiguredRouteSwapsBothWays() public {
        _exerciseAll(0x8876789976dEcBfCbBbe364623C63652db8C0904);
    }
}

contract SetRoutesInkForkTest is SetRoutesForkBase {
    function setUp() public {
        vm.createSelectFork(vm.envOr("INK_RPC_URL", string("https://rpc-gel.inkonchain.com")));
    }

    function test_EveryConfiguredRouteSwapsBothWays() public {
        _exerciseAll(0x112908daC86e20e7241B0927479Ea3Bf935d1fa0);
    }
}
