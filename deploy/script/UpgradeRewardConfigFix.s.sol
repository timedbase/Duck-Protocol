// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — fix the reward-currency mismatch and the "hidden owner" pattern.
//
// Two independent fixes, bundled into one upgrade because they touch the same three contracts:
//
//   1. BondingCurveMigration/DuckCrowdfund used to call setRewardConfig with the token's ORIGINAL,
//      unwrapped quote asset (address(0) for native), while the real pool always uses WETH (migration
//      wraps native into it before seeding). That mismatch made every native-quoted token's holder-
//      reward deposit revert with ZeroAmount() forever, silently caught as HolderRewardSkipped on
//      every claim -- confirmed against FEG's real event history before this fix was written.
//   2. Reward config used to be set later, by a separate setRewardConfig call restricted to a
//      `mintManager` address that lived on indefinitely after the token's real owner had already
//      renounced -- exactly the "hidden owner" pattern token scanners flag (GoPlus flagged FEG for
//      this). DuckOpenToken.initToken now takes hook_/currency_/poolManager_ directly and sets reward
//      config inline, in the same transaction as everything else -- no privileged address survives.
//
// Run once per chain (Robinhood Chain 4663, Ink 57073) as the owner of the launch contracts. In order:
//   1. New implementations of DuckBondingCurve, DuckLauncher and DuckCrowdfund (each pulls in a fresh
//      copy of every library it links against, including the fixed BondingCurveMigration -- forge does
//      NOT reliably respect --libraries for selective reuse in this project, confirmed against the
//      curve-open-token upgrade's own broadcast receipt, which deployed fresh copies of three libraries
//      its own script comment said would be reused. Redeploying everything fresh costs a little extra
//      gas and removes that whole class of doubt.) -- and a UUPS upgrade of each live proxy onto them.
//   2. New DuckCurveToken/DuckLauncherToken/DuckCrowdfundToken clone templates (their base,
//      DuckOpenToken, changed), wired into each launch contract via setTokenImpl.
//
// The hook (DuckGenesisHook) is NOT touched by this upgrade -- its own code was already correct; the
// bug was entirely in what the migration/crowdfund/launcher contracts told the token to expect.
//
//   forge script script/UpgradeRewardConfigFix.s.sol --rpc-url robinhood --account duck-deployer \
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

interface IUUPSProxyRC {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

contract UpgradeRewardConfigFix is Script {
    address constant CURVE         = 0xcE71ce995C2A3657aF9bEC45bA1Ee2E8fA2ef5eF;
    address constant LAUNCHER      = 0x5F37c68f9937A0524Cc441b4E1080Ca4F089693B;
    address constant CROWDFUND     = 0xdA868A545aB058D14a70C46CA7760226e7Dcf7b9;
    address constant VAULT_FACTORY = 0x006e53d079BB4c2010682a4896D1950965faD5A5;
    address constant OWNER         = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    // "v4": after DeployDuckProtocol's "v1", UpgradeToGenesis's "v2" and UpgradeCurveOpenToken's "v3".
    bytes32 constant SALT_CURVE_IMPL           = keccak256("duckfun.v4.DuckBondingCurve.impl");
    bytes32 constant SALT_LAUNCHER_IMPL        = keccak256("duckfun.v4.DuckLauncher.impl");
    bytes32 constant SALT_CROWDFUND_IMPL       = keccak256("duckfun.v4.DuckCrowdfund.impl");
    bytes32 constant SALT_CURVE_TOKEN_IMPL     = keccak256("duckfun.v4.DuckCurveToken.impl");
    bytes32 constant SALT_LAUNCHER_TOKEN_IMPL  = keccak256("duckfun.v4.DuckLauncherToken.impl");
    bytes32 constant SALT_CROWDFUND_TOKEN_IMPL = keccak256("duckfun.v4.DuckCrowdfundToken.impl");

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
        IUUPSProxyRC(CURVE).upgradeToAndCall(r.curveImpl, "");
        IUUPSProxyRC(LAUNCHER).upgradeToAndCall(r.launcherImpl, "");
        IUUPSProxyRC(CROWDFUND).upgradeToAndCall(r.crowdfundImpl, "");

        r.curveTokenImpl     = address(new DuckCurveToken{salt: SALT_CURVE_TOKEN_IMPL}(VAULT_FACTORY));
        r.launcherTokenImpl  = address(new DuckLauncherToken{salt: SALT_LAUNCHER_TOKEN_IMPL}(VAULT_FACTORY));
        r.crowdfundTokenImpl = address(new DuckCrowdfundToken{salt: SALT_CROWDFUND_TOKEN_IMPL}(VAULT_FACTORY));
        DuckBondingCurve(payable(CURVE)).setTokenImpl(r.curveTokenImpl);
        DuckLauncher(payable(LAUNCHER)).setTokenImpl(r.launcherTokenImpl);
        DuckCrowdfund(payable(CROWDFUND)).setTokenImpl(r.crowdfundTokenImpl);

        vm.stopBroadcast();
    }

    function _log(Result memory r) private view {
        console.log("=== Reward-config fix upgrade, chain", block.chainid, "===");
        console.log("DuckBondingCurve impl:      ", r.curveImpl);
        console.log("DuckLauncher impl:          ", r.launcherImpl);
        console.log("DuckCrowdfund impl:         ", r.crowdfundImpl);
        console.log("DuckCurveToken impl:        ", r.curveTokenImpl);
        console.log("DuckLauncherToken impl:     ", r.launcherTokenImpl);
        console.log("DuckCrowdfundToken impl:    ", r.crowdfundTokenImpl);
    }
}
