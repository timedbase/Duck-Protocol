// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — Reliquify: the migration's leader becomes the pool's creator.
//
// Before: seedPool registered every migrated pool (and approveMigration created its vault) with the PLATFORM
// wallet as creator, so the creatorBps share of every fee payout went to the platform. After: the migration's
// leader is the creator of both, so that share goes to them, and they can route it with setFeeSplits. The hook
// owner can still move the role with DuckGenesisHook.transferPoolCreator if a leader's key is lost or compromised.
//
// A UUPS implementation swap only: the storage layout is identical (checked with `forge inspect
// DuckReliquify storage-layout` before and after), no initializer runs, and no migration data changes. Only pools
// seeded AFTER the upgrade get the leader as creator; a pool already seeded keeps its creator.
//
// Run once per chain (Robinhood Chain 4663 and Ink 57073, same proxy address) as the proxy's owner:
//
//   forge script script/UpgradeReliquifyLeaderCreator.s.sol --rpc-url robinhood --account duck-deployer \
//     --sender 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7 --broadcast --slow
//
// Drop --broadcast for a dry run against live state first.

import {Script, console} from "forge-std/Script.sol";
import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";

interface IUUPSProxyRLC {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeReliquifyLeaderCreator is Script {
    address constant PROXY = 0xD4B52e1b491B757e04f592c1f995212f93a1ec2D;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    // "v6": after v1 DeployDuckProtocol, v2 UpgradeToGenesis, v3 UpgradeCurveOpenToken, v4 UpgradeRewardConfigFix
    // and v5 DeployDuckReliquify.
    bytes32 constant SALT_IMPL = keccak256("duckfun.v6.DuckReliquify.impl");

    function run() external returns (address impl) {
        impl = upgradeAs(vm.envOr("OWNER", OWNER));
        console.log("=== Reliquify leader-as-creator upgrade, chain", block.chainid, "===");
        console.log("proxy:              ", PROXY);
        console.log("new implementation: ", impl);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function upgradeAs(address owner) public returns (address impl) {
        vm.startBroadcast(owner);
        impl = address(new DuckReliquify{salt: SALT_IMPL}());
        IUUPSProxyRLC(PROXY).upgradeToAndCall(impl, "");
        vm.stopBroadcast();
    }
}
