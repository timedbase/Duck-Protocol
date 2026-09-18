// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — deploy DuckReliquify to Arc (5042).
//
// A brand-new fourth launch family, added to the already-live Arc protocol -- reuses the same
// v4Singleton/v4PositionManager/v4Hook/platformWallet/universalRouter every other Arc family already
// shares (read live off the deployed DuckCrowdfund proxy rather than re-guessed). Deployed via a
// plain-CREATE ERC1967Proxy (impls are CREATE2-salted) (constructor-time initialize(), atomic -- no front-running window)
// rather than DeterministicProxyFactory: unlike the shared tree, Arc has no cross-chain
// address-matching goal for this deploy (it's a single, standalone chain), so the extra indirection
// isn't needed here.
//
// Every migration is ALWAYS paired with Arc's canonical USDC (ARC_USDC) -- hardcoded, not a
// per-migration or leader choice (Arc has no native pool currency at all; DuckGenesisHook rejects
// address(0) outright, so ARC_USDC is the direct Arc equivalent of the shared tree's "always ETH").
//
// NOT done by this script, required before any migration can reach seedPool():
//   1. DuckGenesisHook(hookAddr).addLauncher(<this proxy>) -- by the hook owner, on Arc.
//      approveMigration() checks this defensively and reverts with HookNotAdded() if it's missing.
//   1b. DuckVaultFactory(VAULT_FACTORY).setFamily(<this proxy>, true) -- by the factory owner, on Arc.
//      approveMigration() creates a vault for the new token, which reverts UnknownFamily otherwise.
//   2. reliquify.setRoutes(oldToken, ...) per migration once proposed, and reliquify.setRoutes(ARC_USDC, ...)
//      once (shared by every migration) if no earlier one has already configured it.
//
// Drop --broadcast for a dry run against live state first.

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {DuckReliquifyToken} from "duck-lib/DuckReliquifyToken.sol";

interface IDuckCrowdfundReadArc {
    function v4Hook() external view returns (address);
    function platformWallet() external view returns (address);
    function universalRouter() external view returns (address);
}

contract DeployDuckReliquify is Script {

    address constant ARC_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant ARC_POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;
    // Read live off the already-deployed crowdfund proxy rather than re-guessed -- reused as-is.
    address constant CROWDFUND     = 0x0c8f0f1353f2d963D03C3eC558D20b151DaF7214;
    address constant VAULT_FACTORY = 0xE3D4d83307E6f5A2C7B4b85436eAacAfd1B873C3;

    // "v1" -- Reliquify's own family, new to Arc (not an upgrade of an existing proxy).
    bytes32 constant SALT_RELIQUIFY_IMPL       = keccak256("duckfun.arc.v1.DuckReliquify.impl");
    bytes32 constant SALT_RELIQUIFY_TOKEN_IMPL = keccak256("duckfun.arc.v1.DuckReliquifyToken.impl");

    function run() external returns (address reliquifyAddr, address tokenImplAddr) {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer    = deployerKey != 0 ? vm.addr(deployerKey) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "Set DEPLOYER_ADDRESS (with --account/--ledger) or PRIVATE_KEY");

        address hookAddr        = IDuckCrowdfundReadArc(CROWDFUND).v4Hook();
        address platformWallet  = IDuckCrowdfundReadArc(CROWDFUND).platformWallet();
        address universalRouter = IDuckCrowdfundReadArc(CROWDFUND).universalRouter();

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast(deployer);
        }

        // Deployed before the proxy: initialize() requires a nonzero tokenImpl_ up front, same as
        // every other family's initializer.
        tokenImplAddr = address(new DuckReliquifyToken{salt: SALT_RELIQUIFY_TOKEN_IMPL}(VAULT_FACTORY));

        address reliquifyImpl = address(new DuckReliquify{salt: SALT_RELIQUIFY_IMPL}());
        // Plain CREATE (no salt), deliberately: a salted deploy goes through the CREATE2 deployer, which
        // would then be initialize()'s msg.sender and so the proxy's owner. Constructor-time init from a
        // real broadcast tx keeps the deployer as owner and is still atomic.
        reliquifyAddr = address(new ERC1967Proxy(
            reliquifyImpl,
            abi.encodeCall(DuckReliquify.initialize, (
                tokenImplAddr, ARC_POOL_MANAGER, ARC_POSITION_MANAGER, hookAddr, platformWallet
            ))
        ));
        DuckReliquify reliquify = DuckReliquify(payable(reliquifyAddr));
        reliquify.setVaultFactory(VAULT_FACTORY);
        reliquify.setUniversalRouter(universalRouter);

        vm.stopBroadcast();

        console.log("=== DuckReliquify deployed to Arc (5042) ===");
        console.log("DuckReliquify impl:      ", reliquifyImpl);
        console.log("DuckReliquify proxy:     ", reliquifyAddr);
        console.log("DuckReliquifyToken impl: ", tokenImplAddr);
        console.log("");
        console.log("Not done by this script -- do these yourself once verified on a fork:");
        console.log("  DuckGenesisHook.addLauncher(<this proxy>) by the hook owner --", hookAddr);
        console.log("  DuckVaultFactory.setFamily(<this proxy>, true) by the factory owner -- else approveMigration reverts UnknownFamily");
        console.log("  setRoutes(oldToken, ...) per migration, and setRoutes(ARC_USDC, ...) once, if needed");
    }
}
