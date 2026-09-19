// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — Reliquify (Arc): the migration's leader becomes the pool's creator.
//
// Same change as the shared tree's script (see deploy/script/UpgradeReliquifyLeaderCreator.s.sol): the leader,
// not the platform wallet, is the creator of the migrated pool and of its vault, so the creatorBps share of every
// fee payout is theirs. A UUPS implementation swap only: identical storage layout, no initializer, no data change.
//
//   forge script script/UpgradeReliquifyLeaderCreator.s.sol --rpc-url https://rpc.mainnet.arc.io \
//     --account duck-deployer --sender 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7 --broadcast --slow --with-gas-price 20gwei
//
// Drop --broadcast for a dry run against live state first.

import {Script, console} from "forge-std/Script.sol";
import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";

interface IUUPSProxyRLCArc {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeReliquifyLeaderCreator is Script {
    address constant PROXY = 0xf7F65C4e96E8D2f4b960E1d7837Cf3c4520412bA;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    // "v2": after DeployDuckReliquify's "v1" (Reliquify's own first version on Arc).
    bytes32 constant SALT_IMPL = keccak256("duckfun.arc.v2.DuckReliquify.impl");

    function run() external returns (address impl) {
        impl = upgradeAs(vm.envOr("OWNER", OWNER));
        console.log("=== Reliquify leader-as-creator upgrade (Arc 5042) ===");
        console.log("proxy:              ", PROXY);
        console.log("new implementation: ", impl);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function upgradeAs(address owner) public returns (address impl) {
        vm.startBroadcast(owner);
        impl = address(new DuckReliquify{salt: SALT_IMPL}());
        IUUPSProxyRLCArc(PROXY).upgradeToAndCall(impl, "");
        vm.stopBroadcast();
    }
}
