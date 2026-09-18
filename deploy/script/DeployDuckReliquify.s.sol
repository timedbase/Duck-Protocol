// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — deploy DuckReliquify to Robinhood Chain (4663) or Ink (57073).
//
// A brand-new fourth launch family, added to the already-live protocol -- reuses the same
// DeterministicProxyFactory, weth/v4Singleton/v4PositionManager/v4Hook/platformWallet every other
// family already shares (see DEPLOYMENT.md), deployed via the same CREATE2-with-a-named-salt pattern
// as the original DeployDuckProtocol.s.sol so the address comes out identical on both chains for the
// same deployer.
//
// NOT done by this script, required before any migration can reach seedPool():
//   1. DuckGenesisHook(hookAddr).addLauncher(<this proxy>) -- by the hook owner, on each chain.
//      approveMigration() checks this defensively and reverts with HookNotAdded() if it's missing,
//      rather than failing deep inside V4Minting's external call chain.
//   2. reliquify.setUniversalRouter(<chain's Universal Router>) and reliquify.setRoutes(oldToken, ...)
//      for each migration's specific old token (always sold for native/WETH, see the file header on
//      DuckReliquify.sol -- every migration's pool is WETH-paired, unconditionally), once a real
//      migration is proposed and under review -- there's nothing to seed ahead of time, unlike the
//      curated quote-token lists the other three families get at deploy time, since every migration's
//      old token is unique and not known until someone actually proposes one.
//
// Drop --broadcast for a dry run against live state first.

import {Script, console} from "forge-std/Script.sol";

import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {DuckReliquifyToken} from "duck-lib/DuckReliquifyToken.sol";
import {DeterministicProxyFactory} from "./DeterministicProxyFactory.sol";

contract DeployDuckReliquify is Script {

    error UnsupportedChain(uint256 chainId);

    uint256 constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 constant INK_CHAIN_ID       = 57073;

    // All from DEPLOYMENT.md -- already-live shared infrastructure, reused as-is.
    address constant PROXY_FACTORY   = 0x807c02ac02A8E08f62Bf48714Ec6eAcFC722D002;
    address constant VAULT_FACTORY   = 0x006e53d079BB4c2010682a4896D1950965faD5A5;
    address constant PLATFORM_WALLET = 0x1c723Cf0451e6635C748283a3e87413079E7C198;

    address constant RH_WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant RH_V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant RH_V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant RH_HOOK                = 0x483b529fa121c5402778a511A98fB326940042CC;
    address constant RH_UNIVERSAL_ROUTER    = 0x8876789976dEcBfCbBbe364623C63652db8C0904;

    address constant INK_WETH                = 0x4200000000000000000000000000000000000006;
    address constant INK_V4_POOL_MANAGER     = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant INK_V4_POSITION_MANAGER = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address constant INK_HOOK                = 0x5a05a1f0A101237D8c350EFfA54f4b3c9bc142cc;
    address constant INK_UNIVERSAL_ROUTER    = 0x112908daC86e20e7241B0927479Ea3Bf935d1fa0;

    // "v5": after v1 DeployDuckProtocol, v2 UpgradeToGenesis, v3 UpgradeCurveOpenToken,
    // v4 UpgradeRewardConfigFix -- Reliquify is new, not an upgrade of an existing proxy, but keeps
    // the same running version counter for this deploy round's own record-keeping.
    bytes32 constant SALT_RELIQUIFY_IMPL       = keccak256("duckfun.v5.DuckReliquify.impl");
    bytes32 constant SALT_RELIQUIFY_PROXY      = keccak256("duckfun.v5.DuckReliquify.proxy");
    bytes32 constant SALT_RELIQUIFY_TOKEN_IMPL = keccak256("duckfun.v5.DuckReliquifyToken.impl");

    function _weth() private view returns (address) {
        if (block.chainid == ROBINHOOD_CHAIN_ID) return RH_WETH;
        if (block.chainid == INK_CHAIN_ID)       return INK_WETH;
        revert UnsupportedChain(block.chainid);
    }

    function _v4PoolManager() private view returns (address) {
        if (block.chainid == ROBINHOOD_CHAIN_ID) return RH_V4_POOL_MANAGER;
        if (block.chainid == INK_CHAIN_ID)       return INK_V4_POOL_MANAGER;
        revert UnsupportedChain(block.chainid);
    }

    function _v4PositionManager() private view returns (address) {
        if (block.chainid == ROBINHOOD_CHAIN_ID) return RH_V4_POSITION_MANAGER;
        if (block.chainid == INK_CHAIN_ID)       return INK_V4_POSITION_MANAGER;
        revert UnsupportedChain(block.chainid);
    }

    function _v4Hook() private view returns (address) {
        if (block.chainid == ROBINHOOD_CHAIN_ID) return RH_HOOK;
        if (block.chainid == INK_CHAIN_ID)       return INK_HOOK;
        revert UnsupportedChain(block.chainid);
    }

    function _universalRouter() private view returns (address) {
        if (block.chainid == ROBINHOOD_CHAIN_ID) return RH_UNIVERSAL_ROUTER;
        if (block.chainid == INK_CHAIN_ID)       return INK_UNIVERSAL_ROUTER;
        revert UnsupportedChain(block.chainid);
    }

    function run() external returns (address reliquifyAddr, address tokenImplAddr) {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer    = deployerKey != 0 ? vm.addr(deployerKey) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "Set DEPLOYER_ADDRESS (with --account/--ledger) or PRIVATE_KEY");

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast(deployer);
        }

        DeterministicProxyFactory proxyFactory = DeterministicProxyFactory(PROXY_FACTORY);

        // Deployed before the proxy: initialize() requires a nonzero tokenImpl_ up front, same as
        // every other family's initializer.
        tokenImplAddr = address(new DuckReliquifyToken{salt: SALT_RELIQUIFY_TOKEN_IMPL}(VAULT_FACTORY));

        address reliquifyImpl = address(new DuckReliquify{salt: SALT_RELIQUIFY_IMPL}());
        reliquifyAddr = proxyFactory.deployAndTransferOwnership(
            SALT_RELIQUIFY_PROXY, reliquifyImpl,
            abi.encodeCall(DuckReliquify.initialize, (
                _weth(), tokenImplAddr, _v4PoolManager(), _v4PositionManager(), _v4Hook(), PLATFORM_WALLET
            )),
            deployer
        );
        DuckReliquify reliquify = DuckReliquify(payable(reliquifyAddr));
        reliquify.acceptOwnership();
        reliquify.setVaultFactory(VAULT_FACTORY);
        reliquify.setUniversalRouter(_universalRouter());

        vm.stopBroadcast();

        console.log("=== DuckReliquify deployed, chain", block.chainid, "===");
        console.log("DuckReliquify impl:      ", reliquifyImpl);
        console.log("DuckReliquify proxy:     ", reliquifyAddr);
        console.log("DuckReliquifyToken impl: ", tokenImplAddr);
        console.log("");
        console.log("Not done by this script -- do these yourself once verified on a fork:");
        console.log("  DuckGenesisHook.addLauncher(<this proxy>) by the hook owner, on this chain --", _v4Hook());
        console.log("  setRoutes(oldToken, ...) per migration, once proposed -- every pool is always WETH-paired");
    }
}
