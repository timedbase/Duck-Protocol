// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — Crowdfund access modes (Arc).
//
// Same change as the shared tree's script (see deploy/script/UpgradeCrowdfundAccess.s.sol): a crowdfund is Open (with an
// optional per-wallet maximum) or Whitelist (a Merkle list, optional allocations, optional shared maximum), fixed at
// launch. On Arc the maximum is in whole ERC-20 USDC units (6 decimals), and a native-USDC contribution is converted
// before it is checked, so both forms count toward the same maximum. Backward compatible; a UUPS implementation swap only.
//
//   forge script script/UpgradeCrowdfundAccess.s.sol --rpc-url https://rpc.mainnet.arc.io \
//     --account duck-deployer --sender 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7 --broadcast --slow --with-gas-price 20gwei
//
// Drop --broadcast for a dry run against live state first.

import {Script, console} from "forge-std/Script.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";

interface IUUPSProxyCFAArc {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeCrowdfundAccess is Script {
    address constant PROXY = 0x0c8f0f1353f2d963D03C3eC558D20b151DaF7214;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    // "v4": after "v3" UpgradeReliquifyRouteEncoding.
    bytes32 constant SALT_IMPL = keccak256("duckfun.arc.v4.DuckCrowdfund.impl");

    function run() external returns (address impl) {
        impl = upgradeAs(vm.envOr("OWNER", OWNER));
        console.log("=== Crowdfund access-modes upgrade (Arc 5042) ===");
        console.log("proxy:              ", PROXY);
        console.log("new implementation: ", impl);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function upgradeAs(address owner) public returns (address impl) {
        vm.startBroadcast(owner);
        impl = address(new DuckCrowdfund{salt: SALT_IMPL}());
        IUUPSProxyCFAArc(PROXY).upgradeToAndCall(impl, "");
        vm.stopBroadcast();
    }
}
