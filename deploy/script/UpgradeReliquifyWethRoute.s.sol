// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — Reliquify: sell routes that work.
//
// Two changes to how the old token is sold (both in lib/LaunchRouting.sol, linked into DuckReliquify):
//
//  1. Universal Router's V4_SWAP reads its parameters as one ABI-encoded struct, and the library encoded the loose
//     fields instead (no leading offset word), so every V4 route reverted inside the router. Now encoded as the
//     struct, byte for byte what the app's own swaps already send (test/RouteEncoding.t.sol).
//  2. A new route shape, V4_WETH_STYLE, for a v4 pool paired with WETH rather than native ETH: which is every
//     DuckGenesisHook pool, and the only pool a Duck-launched token such as FEG has. It swaps old token -> WETH
//     through the router, then unwraps to ETH. Enum value appended (V3_STYLE 0, V4_STYLE 1, V4_WETH_STYLE 2); the
//     Route struct is unchanged; the WETH address rides in path[0].
//
// A UUPS implementation swap only: no state variable changed, no initializer runs, no migration data changes.
// Run once per chain (Robinhood Chain 4663 and Ink 57073 share the proxy address) as the proxy's owner:
//
//   forge script script/UpgradeReliquifyWethRoute.s.sol --rpc-url robinhood --account duck-deployer \
//     --sender 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7 --broadcast --slow
//
// Drop --broadcast for a dry run against live state first. Afterwards the owner can set FEG's route (see the
// cast command in the hand-over notes / DEPLOYMENT.md).

import {Script, console} from "forge-std/Script.sol";
import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";

interface IUUPSProxyRWR {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeReliquifyWethRoute is Script {
    address constant PROXY = 0xD4B52e1b491B757e04f592c1f995212f93a1ec2D;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    // "v7": after v6 UpgradeReliquifyLeaderCreator.
    bytes32 constant SALT_IMPL = keccak256("duckfun.v7.DuckReliquify.impl");

    function run() external returns (address impl) {
        impl = upgradeAs(vm.envOr("OWNER", OWNER));
        console.log("=== Reliquify sell-route upgrade, chain", block.chainid, "===");
        console.log("proxy:              ", PROXY);
        console.log("new implementation: ", impl);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function upgradeAs(address owner) public returns (address impl) {
        vm.startBroadcast(owner);
        impl = address(new DuckReliquify{salt: SALT_IMPL}());
        IUUPSProxyRWR(PROXY).upgradeToAndCall(impl, "");
        vm.stopBroadcast();
    }
}
