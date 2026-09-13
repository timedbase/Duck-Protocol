// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — bonding-curve tokens without the launch-phase transfer lock.
//
// The lock kept a curve token out of every pool until migration, so nobody could initialize or seed its
// pool first. DuckGenesisHook already enforces that (it only initializes pools a launcher registered, at
// migration, and only launchers can add liquidity), so new curve tokens launch on DuckCurveToken, which has
// no lock -- the restriction token scanners flag. Run once per chain (Robinhood Chain 4663, Ink 57073) as
// the curve's owner. The protocol addresses are the same on both chains.
//
//   1. A new DuckBondingCurve implementation (initToken without the lock) linked against the new
//      BondingCurveMigration (unlocks at migration only tokens that are still locked, so curve tokens
//      launched on DuckToken before this still migrate normally), and a UUPS upgrade of the proxy.
//   2. DuckCurveToken as the curve's clone template.
//
// Linking: BondingCurveMigration's bytecode changed, so forge deploys a new copy; pass the libraries that
// didn't change so the ones already live are reused:
//
//   forge script script/UpgradeCurveOpenToken.s.sol --rpc-url robinhood --account duck-deployer \
//     --sender 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7 --broadcast --slow \
//     --libraries ../lib/BondingCurveMath.sol:BondingCurveMath:0xf499aa5b7688af720df3289e1552172148501dd7 \
//     --libraries ../lib/LaunchRouting.sol:LaunchRoutingExec:0xac1245112ded0de4e43e16d0cdf59b71c21fefea \
//     --libraries ../lib/V4Minting.sol:V4Minting:0xaab94bf4e158a43631c86c804cd9453e0c6d7878
//
// Drop --broadcast for a dry run against live state first.

import {Script, console} from "forge-std/Script.sol";

import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckCurveToken} from "duck-lib/DuckCurveToken.sol";

interface IUUPSProxyCurve {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeCurveOpenToken is Script {
    address constant CURVE         = 0xcE71ce995C2A3657aF9bEC45bA1Ee2E8fA2ef5eF;
    address constant VAULT_FACTORY = 0x006e53d079BB4c2010682a4896D1950965faD5A5;
    address constant OWNER         = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    // "v3": after DeployDuckProtocol's "v1" and UpgradeToGenesis's "v2" salts.
    bytes32 constant SALT_CURVE_IMPL       = keccak256("duckfun.v3.DuckBondingCurve.impl");
    bytes32 constant SALT_CURVE_TOKEN_IMPL = keccak256("duckfun.v3.DuckCurveToken.impl");

    struct Result {
        address curveImpl;
        address curveTokenImpl;
    }

    function run() external returns (Result memory r) {
        r = upgradeAs(vm.envOr("OWNER", OWNER));
        console.log("=== Curve open-token upgrade, chain", block.chainid, "===");
        console.log("DuckBondingCurve impl:    ", r.curveImpl);
        console.log("DuckCurveToken impl:      ", r.curveTokenImpl);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function upgradeAs(address owner) public returns (Result memory r) {
        vm.startBroadcast(owner);
        r.curveImpl = address(new DuckBondingCurve{salt: SALT_CURVE_IMPL}());
        IUUPSProxyCurve(CURVE).upgradeToAndCall(r.curveImpl, "");
        r.curveTokenImpl = address(new DuckCurveToken{salt: SALT_CURVE_TOKEN_IMPL}(VAULT_FACTORY));
        DuckBondingCurve(payable(CURVE)).setTokenImpl(r.curveTokenImpl);
        vm.stopBroadcast();
    }
}
