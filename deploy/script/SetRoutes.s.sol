// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — SetRoutes
//
// Writes RouteTables' routes for every curated quote token to all three launch families, and on
// Ink (re-)enables USDG and the USDG-routed stocks. Route data lives in RouteTables.sol so the
// fork test exercises exactly what this script configures.

import {Script, console} from "forge-std/Script.sol";
import {Route} from "duck-lib/LaunchRouting.sol";
import {RouteTables} from "./RouteTables.sol";

interface IRoutable {
    function setRoutes(address quoteToken_, Route[] calldata routes_) external;
}

interface IQuoteAdmin {
    function addQuoteToken(address token_) external;
    function setQuoteTokenAllowed(address token_, bool allowed_) external;
    function setQuoteAssetAllowed(address token_, bool allowed_) external;
}

contract SetRoutes is Script {

    address constant CURVE     = 0xcE71ce995C2A3657aF9bEC45bA1Ee2E8fA2ef5eF;
    address constant LAUNCHER  = 0x5F37c68f9937A0524Cc441b4E1080Ca4F089693B;
    address constant CROWDFUND = 0xdA868A545aB058D14a70C46CA7760226e7Dcf7b9;

    function run() external {
        uint256 pk = vm.envOr("PRIVATE_KEY", uint256(0));
        address sender = pk != 0 ? vm.addr(pk) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(sender != address(0), "Set DEPLOYER_ADDRESS (with --account) or PRIVATE_KEY");

        RouteTables.TokenRoutes[] memory t = RouteTables.forChain(block.chainid);

        if (pk != 0) vm.startBroadcast(pk); else vm.startBroadcast(sender);

        for (uint256 i; i < t.length; ++i) {
            // Same list on all three families -- they share LaunchRouting, and letting them drift
            // would mean a token buyable on the curve but not through the launcher.
            IRoutable(CURVE).setRoutes(t[i].token, t[i].routes);
            IRoutable(LAUNCHER).setRoutes(t[i].token, t[i].routes);
            IRoutable(CROWDFUND).setRoutes(t[i].token, t[i].routes);
            console.log("routes set:", t[i].symbol, t[i].routes.length);
        }

        if (block.chainid == RouteTables.INK_CHAIN_ID) {
            address[] memory enable = RouteTables.inkEnable();
            for (uint256 i; i < enable.length; ++i) {
                IQuoteAdmin(CURVE).setQuoteTokenAllowed(enable[i], true);
                IQuoteAdmin(LAUNCHER).addQuoteToken(enable[i]);
                IQuoteAdmin(CROWDFUND).setQuoteAssetAllowed(enable[i], true);
                console.log("enabled quote token:", enable[i]);
            }
        }

        vm.stopBroadcast();
    }
}
