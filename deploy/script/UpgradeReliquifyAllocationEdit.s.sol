// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — Reliquify: editable allocations, finalize, rescue.
//
//  - Before the seed the leader can propose an allocation edit (proposeAllocationEdit). Proposing pauses the migration;
//    the platform owner approves or rejects; an approved edit can be applied after 24 hours (applyAllocationEdit) within
//    7 days, and the migration resumes. Anyone can clear an expired edit.
//  - After the seed only the owner edits (adminAdjustAllocations), immediately.
//  - Every edit obeys one rule: allocation still to be deposited cannot exceed what is reserved in the contract, and no
//    wallet can be set below what it has already deposited.
//  - finalizeMigration (owner, Seeded) ends a migration: no more deposits or edits, claims stay open. rescueReserve
//    (owner, after finalize) then moves what is left in the reserve. Nothing is burned.
//
// Storage: two mappings appended after `reliquifyFee` (pendingEdit, finalized); nothing existing changes. No initializer
// runs and no migration data changes. Run once per chain as the proxy's owner:
//
//   forge script script/UpgradeReliquifyAllocationEdit.s.sol --rpc-url robinhood --account duck-deployer \
//     --sender 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7 --broadcast --slow
//
// Drop --broadcast for a dry run against live state first.

import {Script, console} from "forge-std/Script.sol";
import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";

interface IUUPSProxyRAE {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeReliquifyAllocationEdit is Script {
    address constant PROXY = 0xD4B52e1b491B757e04f592c1f995212f93a1ec2D;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    bytes32 constant SALT_IMPL = keccak256("duckfun.v8.DuckReliquify.impl");

    function run() external returns (address impl) {
        impl = upgradeAs(vm.envOr("OWNER", OWNER));
        console.log("=== Reliquify allocation-edit upgrade, chain", block.chainid, "===");
        console.log("proxy:              ", PROXY);
        console.log("new implementation: ", impl);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function upgradeAs(address owner) public returns (address impl) {
        vm.startBroadcast(owner);
        impl = address(new DuckReliquify{salt: SALT_IMPL}());
        IUUPSProxyRAE(PROXY).upgradeToAndCall(impl, "");
        vm.stopBroadcast();
    }
}
