// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — Crowdfund access modes.
//
// A crowdfund is now either Open (anyone, with an optional per-wallet maximum) or Whitelist (only wallets in the
// creator's Merkle list, each with an optional allocation, and an optional shared maximum that is a hard ceiling for every wallet). The mode, the maximum and the
// list root are fixed at launch (launchWithAccess) and can't change afterwards.
//
// Backward compatible: the original launch() and contribute() are unchanged in behaviour (Open, no maximum), and a
// campaign that already exists reads as Open with no maximum because the new state is a separate mapping appended to
// the end of storage (the Campaign array can't grow a field without shifting its elements; verified with a
// storage-layout diff: every existing variable keeps its slot, and Campaign's 20 fields are identical).
//
// A UUPS implementation swap only: no initializer runs, no campaign data changes. Run once per chain (Robinhood
// Chain 4663 and Ink 57073 share the proxy address) as the proxy's owner:
//
//   forge script script/UpgradeCrowdfundAccess.s.sol --rpc-url robinhood --account duck-deployer \
//     --sender 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7 --broadcast --slow
//
// Drop --broadcast for a dry run against live state first.

import {Script, console} from "forge-std/Script.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";

interface IUUPSProxyCFA {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeCrowdfundAccess is Script {
    address constant PROXY = 0xdA868A545aB058D14a70C46CA7760226e7Dcf7b9;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    // "v8": after v7 UpgradeReliquifyWethRoute.
    bytes32 constant SALT_IMPL = keccak256("duckfun.v8.DuckCrowdfund.impl");

    function run() external returns (address impl) {
        impl = upgradeAs(vm.envOr("OWNER", OWNER));
        console.log("=== Crowdfund access-modes upgrade, chain", block.chainid, "===");
        console.log("proxy:              ", PROXY);
        console.log("new implementation: ", impl);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function upgradeAs(address owner) public returns (address impl) {
        vm.startBroadcast(owner);
        impl = address(new DuckCrowdfund{salt: SALT_IMPL}());
        IUUPSProxyCFA(PROXY).upgradeToAndCall(impl, "");
        vm.stopBroadcast();
    }
}
