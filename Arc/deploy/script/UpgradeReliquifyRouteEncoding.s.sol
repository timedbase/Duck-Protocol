// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — Reliquify (Arc): sell routes that work.
//
// Universal Router's V4_SWAP reads its parameters as one ABI-encoded struct, and Arc's routing library encoded the
// loose fields instead (no leading offset word), so a sale through a configured route reverted inside the router.
// Now encoded as the struct, byte for byte what the app's own Arc swaps send (test/RouteEncoding.t.sol).
// A UUPS implementation swap only: no state variable changed, no initializer runs, no migration data changes.
// (Arc has no WETH, so the WETH-paired route shape that Robinhood/Ink gain does not apply here.)
//
//   forge script script/UpgradeReliquifyRouteEncoding.s.sol --rpc-url https://rpc.mainnet.arc.io \
//     --account duck-deployer --sender 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7 --broadcast --slow --with-gas-price 20gwei
//
// Drop --broadcast for a dry run against live state first.

import {Script, console} from "forge-std/Script.sol";
import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";

interface IUUPSProxyRREArc {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeReliquifyRouteEncoding is Script {
    address constant PROXY = 0xf7F65C4e96E8D2f4b960E1d7837Cf3c4520412bA;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    // "v3": after "v2" UpgradeReliquifyLeaderCreator.
    bytes32 constant SALT_IMPL = keccak256("duckfun.arc.v3.DuckReliquify.impl");

    function run() external returns (address impl) {
        impl = upgradeAs(vm.envOr("OWNER", OWNER));
        console.log("=== Reliquify sell-route upgrade (Arc 5042) ===");
        console.log("proxy:              ", PROXY);
        console.log("new implementation: ", impl);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function upgradeAs(address owner) public returns (address impl) {
        vm.startBroadcast(owner);
        impl = address(new DuckReliquify{salt: SALT_IMPL}());
        IUUPSProxyRREArc(PROXY).upgradeToAndCall(impl, "");
        vm.stopBroadcast();
    }
}
