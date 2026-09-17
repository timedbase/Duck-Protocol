// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — Arc build: close the "hidden owner" pattern token scanners flag.
//
// Arc never had the reward-currency mismatch the shared-tree upgrade fixes (no native quote, no WETH
// wrap -- confirmed directly against BondingCurveMigration/DuckCrowdfund source before writing this).
// It DID have the same "hidden owner" pattern: reward config was set later, by a separate
// setRewardConfig call restricted to a `mintManager` address that lived on indefinitely after the
// token's real owner had already renounced. DuckOpenToken.initToken now takes hook_/currency_/
// poolManager_ directly and sets reward config inline, in the same transaction as everything else --
// no privileged address survives. Confirmed zero tokens/campaigns exist on Arc yet (campaignCount() and
// both launch contracts' allTokens are empty), so this upgrade carries zero migration risk.
//
// Run once, as the owner of the launch contracts. In order:
//   1. New implementations of DuckBondingCurve, DuckLauncher and DuckCrowdfund (each pulls in a fresh
//      copy of every library it links against, including the fixed BondingCurveMigration -- forge does
//      NOT reliably respect --libraries for selective reuse in this project, confirmed against the
//      shared tree's own curve-open-token upgrade broadcast receipt. Redeploying everything fresh costs
//      a little extra gas and removes that whole class of doubt.) -- and a UUPS upgrade of each live
//      proxy onto them.
//   2. New DuckCurveToken/DuckLauncherToken/DuckCrowdfundToken clone templates (their base,
//      DuckOpenToken, changed), wired into each launch contract via setTokenImpl.
//
// The hook (DuckGenesisHook) is NOT touched by this upgrade.
//
//   forge script script/UpgradeRewardConfigFix.s.sol --rpc-url arc --account duck-deployer \
//     --sender 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7 --broadcast --slow
//
// Drop --broadcast for a dry run against live state first.

import {Script, console} from "forge-std/Script.sol";

import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckLauncher} from "duck-launcher/DuckLauncher.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {DuckCurveToken} from "duck-lib/DuckCurveToken.sol";
import {DuckLauncherToken} from "duck-lib/DuckLauncherToken.sol";
import {DuckCrowdfundToken} from "duck-lib/DuckCrowdfundToken.sol";

interface IUUPSProxyArcRC {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeRewardConfigFix is Script {
    // From DeployDuckProtocolArc's 2026-09-14 mainnet broadcast (see memory: arc-deploy-build).
    address constant CURVE         = 0xFD5FAE76B375e1dA6A3F1759eB84B26b39dE706C;
    address constant LAUNCHER      = 0xf916E628503639DCb4726d4B75745Ad678dc4d02;
    address constant CROWDFUND     = 0x0c8f0f1353f2d963D03C3eC558D20b151DaF7214;
    address constant VAULT_FACTORY = 0xE3D4d83307E6f5A2C7B4b85436eAacAfd1B873C3;
    address constant OWNER         = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    // "v2": after DeployDuckProtocolArc's "v1" (implicit, unsalted at first deploy).
    bytes32 constant SALT_CURVE_IMPL           = keccak256("duckfun.arc.v2.DuckBondingCurve.impl");
    bytes32 constant SALT_LAUNCHER_IMPL        = keccak256("duckfun.arc.v2.DuckLauncher.impl");
    bytes32 constant SALT_CROWDFUND_IMPL       = keccak256("duckfun.arc.v2.DuckCrowdfund.impl");
    bytes32 constant SALT_CURVE_TOKEN_IMPL     = keccak256("duckfun.arc.v2.DuckCurveToken.impl");
    bytes32 constant SALT_LAUNCHER_TOKEN_IMPL  = keccak256("duckfun.arc.v2.DuckLauncherToken.impl");
    bytes32 constant SALT_CROWDFUND_TOKEN_IMPL = keccak256("duckfun.arc.v2.DuckCrowdfundToken.impl");

    struct Result {
        address curveImpl;
        address launcherImpl;
        address crowdfundImpl;
        address curveTokenImpl;
        address launcherTokenImpl;
        address crowdfundTokenImpl;
    }

    function run() external returns (Result memory r) {
        r = upgradeAs(vm.envOr("OWNER", OWNER));
        _log(r);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function upgradeAs(address owner) public returns (Result memory r) {
        vm.startBroadcast(owner);

        r.curveImpl     = address(new DuckBondingCurve{salt: SALT_CURVE_IMPL}());
        r.launcherImpl  = address(new DuckLauncher{salt: SALT_LAUNCHER_IMPL}());
        r.crowdfundImpl = address(new DuckCrowdfund{salt: SALT_CROWDFUND_IMPL}());
        IUUPSProxyArcRC(CURVE).upgradeToAndCall(r.curveImpl, "");
        IUUPSProxyArcRC(LAUNCHER).upgradeToAndCall(r.launcherImpl, "");
        IUUPSProxyArcRC(CROWDFUND).upgradeToAndCall(r.crowdfundImpl, "");

        r.curveTokenImpl     = address(new DuckCurveToken{salt: SALT_CURVE_TOKEN_IMPL}(VAULT_FACTORY));
        r.launcherTokenImpl  = address(new DuckLauncherToken{salt: SALT_LAUNCHER_TOKEN_IMPL}(VAULT_FACTORY));
        r.crowdfundTokenImpl = address(new DuckCrowdfundToken{salt: SALT_CROWDFUND_TOKEN_IMPL}(VAULT_FACTORY));
        DuckBondingCurve(payable(CURVE)).setTokenImpl(r.curveTokenImpl);
        DuckLauncher(payable(LAUNCHER)).setTokenImpl(r.launcherTokenImpl);
        DuckCrowdfund(payable(CROWDFUND)).setTokenImpl(r.crowdfundTokenImpl);

        vm.stopBroadcast();
    }

    function _log(Result memory r) private view {
        console.log("=== Arc reward-config fix upgrade, chain", block.chainid, "===");
        console.log("DuckBondingCurve impl:      ", r.curveImpl);
        console.log("DuckLauncher impl:          ", r.launcherImpl);
        console.log("DuckCrowdfund impl:         ", r.crowdfundImpl);
        console.log("DuckCurveToken impl:        ", r.curveTokenImpl);
        console.log("DuckLauncherToken impl:     ", r.launcherTokenImpl);
        console.log("DuckCrowdfundToken impl:    ", r.crowdfundTokenImpl);
    }
}
