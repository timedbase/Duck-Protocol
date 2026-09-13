// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — move a live DuckProtocol deployment onto DuckGenesisHook.
//
// Run once per chain (Robinhood Chain 4663, Ink 57073) as the owner of the launch contracts, the vault
// factory and the current hook (all the same wallet). In order:
//
//   1. New implementations of DuckBondingCurve, DuckLauncher and DuckCrowdfund -- linked against the
//      reordered V4Minting (register the pool before initializing it) and accepting any hook fee up to
//      10% -- and a UUPS upgrade of each live proxy onto them.
//   2. DuckGenesisHook through DuckGenesisHookFactory at an address mined for permission bits 0x2ACC,
//      wired to the three launchers, WETH, StateView and the current hook's platform wallet.
//   3. Every launch family, and the vault factory, pointed at the new hook. Pools already on DuckHookV4
//      keep it: a pool's hook is part of its key.
//   4. DuckLauncherToken and DuckCrowdfundToken as the launcher's and crowdfund's clone templates.
//      Bonding-curve tokens keep DuckToken and its launch-phase transfer lock.
//
// Linking: V4Minting's bytecode changed, so forge deploys a new copy; pass the five unchanged libraries
// explicitly so they're reused rather than redeployed:
//
//   forge script script/UpgradeToGenesis.s.sol --rpc-url robinhood --account duck-deployer \
//     --sender 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7 --broadcast \
//     --libraries ../lib/BondingCurveMath.sol:BondingCurveMath:0x400B90eF450f6d11612fbf71f88Fe57369d6A033 \
//     --libraries ../lib/BondingCurveMigration.sol:BondingCurveMigration:0x3f173755d000B934A89EDB4188480C130334251e \
//     --libraries ../lib/DuckClones.sol:DuckClones:0x03348aea71EA494E9047CF45a111b8Bd5B2e3294 \
//     --libraries ../lib/LaunchRouting.sol:LaunchRoutingExec:0xE271ded13C8eF087255e89200C7A71E37573EB56 \
//     --libraries ../lib/V4Math.sol:V4Math:0x7Bb7ad0f886895BECbb1542da1E98009612344a7
//
// Drop --broadcast for a dry run against live state first. SET_V4_STATE_VIEW=true also sets StateView
// on the existing DuckHookV4, which has none -- without it that hook's oracle never records, so
// vaults on its pools can't price borrows.

import {Script, console} from "forge-std/Script.sol";

import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckLauncher} from "duck-launcher/DuckLauncher.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {DuckVaultFactory} from "duck-lending/DuckVaultFactory.sol";
import {DuckLauncherToken} from "duck-lib/DuckLauncherToken.sol";
import {DuckCrowdfundToken} from "duck-lib/DuckCrowdfundToken.sol";
import {DuckGenesisHook} from "duck-shared/DuckGenesisHook.sol";
import {DuckGenesisHookFactory} from "./DuckGenesisHookFactory.sol";

interface IUUPSProxy {
    function upgradeToAndCall(address newImplementation, bytes calldata data) external payable;
}

interface ICurrentHook {
    function platformWallet() external view returns (address);
    function setStateView(address stateView_) external;
}

contract UpgradeToGenesis is Script {

    error UnsupportedChain(uint256 chainId);

    uint256 constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 constant INK_CHAIN_ID       = 57073;

    // Same on both chains (CREATE2 from the same deployer, see DeployDuckProtocol).
    address constant CURVE         = 0xcE71ce995C2A3657aF9bEC45bA1Ee2E8fA2ef5eF;
    address constant LAUNCHER      = 0x5F37c68f9937A0524Cc441b4E1080Ca4F089693B;
    address constant CROWDFUND     = 0xdA868A545aB058D14a70C46CA7760226e7Dcf7b9;
    address constant VAULT_FACTORY = 0x006e53d079BB4c2010682a4896D1950965faD5A5;
    address constant OWNER         = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;

    address constant RH_WETH                 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant RH_V4_POOL_MANAGER      = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant RH_V4_POSITION_MANAGER  = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant RH_V4_STATE_VIEW        = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant RH_CURRENT_HOOK         = 0x483b529fa121c5402778a511A98fB326940042CC;

    address constant INK_WETH                = 0x4200000000000000000000000000000000000006;
    address constant INK_V4_POOL_MANAGER     = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant INK_V4_POSITION_MANAGER = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address constant INK_V4_STATE_VIEW       = 0x76Fd297e2D437cd7f76d50F01AfE6160f86e9990;
    address constant INK_CURRENT_HOOK        = 0x5a05a1f0A101237D8c350EFfA54f4b3c9bc142cc;

    // "v2" alongside DeployDuckProtocol's "v1" salts, so these never collide with the originals.
    bytes32 constant SALT_CURVE_IMPL           = keccak256("duckfun.v2.DuckBondingCurve.impl");
    bytes32 constant SALT_LAUNCHER_IMPL        = keccak256("duckfun.v2.DuckLauncher.impl");
    bytes32 constant SALT_CROWDFUND_IMPL       = keccak256("duckfun.v2.DuckCrowdfund.impl");
    bytes32 constant SALT_LAUNCHER_TOKEN_IMPL  = keccak256("duckfun.v2.DuckLauncherToken.impl");
    bytes32 constant SALT_CROWDFUND_TOKEN_IMPL = keccak256("duckfun.v2.DuckCrowdfundToken.impl");

    uint160 constant GENESIS_PERMISSIONS = 0x2ACC;

    struct ChainConfig {
        address weth;
        address poolManager;
        address positionManager;
        address stateView;
        address currentHook;
    }

    struct Result {
        address hook;
        address hookFactory;
        address curveImpl;
        address launcherImpl;
        address crowdfundImpl;
        address launcherTokenImpl;
        address crowdfundTokenImpl;
    }

    function run() external returns (Result memory result) {
        address owner = vm.envOr("OWNER", OWNER);
        result = upgradeAs(owner, vm.envOr("SET_V4_STATE_VIEW", false));
        _log(result);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function upgradeAs(address owner, bool setCurrentHookStateView) public returns (Result memory r) {
        ChainConfig memory cfg = _config();

        vm.startBroadcast(owner);

        // 1. launch contract implementations + proxy upgrades
        r.curveImpl     = address(new DuckBondingCurve{salt: SALT_CURVE_IMPL}());
        r.launcherImpl  = address(new DuckLauncher{salt: SALT_LAUNCHER_IMPL}());
        r.crowdfundImpl = address(new DuckCrowdfund{salt: SALT_CROWDFUND_IMPL}());
        IUUPSProxy(CURVE).upgradeToAndCall(r.curveImpl, "");
        IUUPSProxy(LAUNCHER).upgradeToAndCall(r.launcherImpl, "");
        IUUPSProxy(CROWDFUND).upgradeToAndCall(r.crowdfundImpl, "");

        // 2. the hook
        // Plain CREATE, not a salted one: salted creations are relayed through the CREATE2 deployer, which
        // would become the factory's only authorized caller and lock the owner out of deploy().
        DuckGenesisHookFactory factory = new DuckGenesisHookFactory();
        r.hookFactory = address(factory);
        bytes32 hookSalt = _mineHookSalt(address(factory), factory.initCodeHash(cfg.poolManager));
        r.hook = factory.deploy(hookSalt, cfg.poolManager, owner);
        DuckGenesisHook hook = DuckGenesisHook(payable(r.hook));
        hook.addLauncher(CURVE);
        hook.addLauncher(LAUNCHER);
        hook.addLauncher(CROWDFUND);
        hook.setWeth(cfg.weth);
        // Same fee recipient as the hook being replaced. Not optional: claimFees reverts without one.
        hook.setPlatformWallet(ICurrentHook(cfg.currentHook).platformWallet());
        hook.setStateView(cfg.stateView);

        // 3. new pools and new vaults use the new hook
        DuckBondingCurve(payable(CURVE)).setDexConfig(cfg.positionManager, cfg.poolManager, r.hook);
        DuckCrowdfund(payable(CROWDFUND)).setDexConfig(cfg.positionManager, cfg.poolManager, r.hook);
        DuckLauncher(payable(LAUNCHER)).addDex(cfg.positionManager, cfg.poolManager, r.hook);
        DuckVaultFactory(VAULT_FACTORY).setHook(r.hook);

        // 4. per-family token templates
        r.launcherTokenImpl  = address(new DuckLauncherToken{salt: SALT_LAUNCHER_TOKEN_IMPL}(VAULT_FACTORY));
        r.crowdfundTokenImpl = address(new DuckCrowdfundToken{salt: SALT_CROWDFUND_TOKEN_IMPL}(VAULT_FACTORY));
        DuckLauncher(payable(LAUNCHER)).setTokenImpl(r.launcherTokenImpl);
        DuckCrowdfund(payable(CROWDFUND)).setTokenImpl(r.crowdfundTokenImpl);

        if (setCurrentHookStateView) ICurrentHook(cfg.currentHook).setStateView(cfg.stateView);

        vm.stopBroadcast();

        require(uint160(r.hook) & 0x3FFF == GENESIS_PERMISSIONS, "bad hook permission bits");
    }

    function _config() private view returns (ChainConfig memory) {
        if (block.chainid == ROBINHOOD_CHAIN_ID) {
            return ChainConfig(RH_WETH, RH_V4_POOL_MANAGER, RH_V4_POSITION_MANAGER, RH_V4_STATE_VIEW, RH_CURRENT_HOOK);
        }
        if (block.chainid == INK_CHAIN_ID) {
            return ChainConfig(INK_WETH, INK_V4_POOL_MANAGER, INK_V4_POSITION_MANAGER, INK_V4_STATE_VIEW, INK_CURRENT_HOOK);
        }
        revert UnsupportedChain(block.chainid);
    }

    function _mineHookSalt(address factory, bytes32 initCodeHash) internal pure returns (bytes32 salt) {
        for (uint256 nonce = 0; nonce < 1_000_000; nonce++) {
            salt = bytes32(nonce);
            if (uint160(_computeCreate2Address(salt, initCodeHash, factory)) & 0x3FFF == GENESIS_PERMISSIONS) return salt;
        }
        revert("hook salt not found");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer_)
        internal pure returns (address addr)
    {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer_))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), initCodeHash)
            addr := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _log(Result memory r) private view {
        console.log("=== DuckGenesis upgrade, chain", block.chainid, "===");
        console.log("DuckGenesisHook:          ", r.hook);
        console.log("DuckGenesisHookFactory:   ", r.hookFactory);
        console.log("DuckBondingCurve impl:    ", r.curveImpl);
        console.log("DuckLauncher impl:        ", r.launcherImpl);
        console.log("DuckCrowdfund impl:       ", r.crowdfundImpl);
        console.log("DuckLauncherToken impl:   ", r.launcherTokenImpl);
        console.log("DuckCrowdfundToken impl:  ", r.crowdfundTokenImpl);
        console.log("Then: HOOK_FEE_ANY_RATE: true in the interface, and add the new hook to the indexer.");
    }
}
