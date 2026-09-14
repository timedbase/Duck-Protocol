// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — fresh DuckProtocol deploy to Arc mainnet (5042).
//
// Deploys the Arc build in this directory (Arc/): DuckGenesisHook, the three launch families with a token
// template each, lending and governance. Arc is a stablechain -- USDC is the native gas token (18 decimals)
// and the ERC-20 at ARC_USDC (6 decimals) is the same balance -- so these contracts have no WETH, take only
// ERC-20 quote assets, and treat native USDC as USDC (lib/ArcChain.sol, lib/LaunchRouting.sol). USDC is the
// curated quote asset, and the curve, launcher and crowdfund fees are 1 USDC (1e18 native).
//
// One command, as the deploying owner, from Arc/deploy:
//   forge script script/DeployDuckProtocolArc.s.sol --rpc-url <arc> --account duck-deployer \
//     --sender <owner> --broadcast --slow
// This tree only contains Arc's libraries, so those are the ones forge deploys and links. Drop --broadcast
// for a dry run first. DEPLOYER_ADDRESS (the owner) is required; PLATFORM_WALLET defaults to it.

import {Script, console} from "forge-std/Script.sol";
import {ARC_CHAIN_ID, ARC_USDC} from "duck-lib/ArcChain.sol";

import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckBondingCurveViews} from "duck-bonding-curve/DuckBondingCurveViews.sol";
import {DuckLauncher} from "duck-launcher/DuckLauncher.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {DuckCurveToken} from "duck-lib/DuckCurveToken.sol";
import {DuckLauncherToken} from "duck-lib/DuckLauncherToken.sol";
import {DuckCrowdfundToken} from "duck-lib/DuckCrowdfundToken.sol";
import {DuckGenesisHook} from "duck-shared/DuckGenesisHook.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultFactory} from "duck-lending/DuckVaultFactory.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckTokenGovernor} from "duck-governance/DuckTokenGovernor.sol";
import {DuckTokenGovernorFactory} from "duck-governance/DuckTokenGovernorFactory.sol";
import {TimelockControllerUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {DuckGenesisHookFactory} from "./DuckGenesisHookFactory.sol";
import {DeterministicProxyFactory} from "./DeterministicProxyFactory.sol";

contract DeployDuckProtocolArc is Script {
    error UnsupportedChain(uint256 chainId);

    // Arc infrastructure (Uniswap's sdk-core and universal-router-sdk address tables for chain 5042).
    address constant ARC_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant ARC_POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;
    address constant ARC_STATE_VIEW       = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant ARC_UNIVERSAL_ROUTER = 0x4fcA4a51Ab4F23A7447b3284fBd7D73289A89Fb1;

    // 1 USDC in native units (18 decimals), for every launch family's creation fee.
    uint256 constant LAUNCH_FEE = 1e18;

    uint160 constant GENESIS_PERMISSIONS = 0x2ACC;

    bytes32 constant SALT_PROXY_FACTORY          = keccak256("duckfun.arc.v1.DeterministicProxyFactory");
    bytes32 constant SALT_VAULT_CONFIG_IMPL      = keccak256("duckfun.arc.v1.DuckVaultConfig.impl");
    bytes32 constant SALT_VAULT_CONFIG_PROXY     = keccak256("duckfun.arc.v1.DuckVaultConfig.proxy");
    bytes32 constant SALT_VAULT_IMPL             = keccak256("duckfun.arc.v1.DuckVault.impl");
    bytes32 constant SALT_VAULT_FACTORY_IMPL     = keccak256("duckfun.arc.v1.DuckVaultFactory.impl");
    bytes32 constant SALT_VAULT_FACTORY_PROXY    = keccak256("duckfun.arc.v1.DuckVaultFactory.proxy");
    bytes32 constant SALT_CURVE_TOKEN_IMPL       = keccak256("duckfun.arc.v1.DuckCurveToken.impl");
    bytes32 constant SALT_LAUNCHER_TOKEN_IMPL    = keccak256("duckfun.arc.v1.DuckLauncherToken.impl");
    bytes32 constant SALT_CROWDFUND_TOKEN_IMPL   = keccak256("duckfun.arc.v1.DuckCrowdfundToken.impl");
    bytes32 constant SALT_CURVE_IMPL             = keccak256("duckfun.arc.v1.DuckBondingCurve.impl");
    bytes32 constant SALT_CURVE_PROXY            = keccak256("duckfun.arc.v1.DuckBondingCurve.proxy");
    bytes32 constant SALT_CURVE_VIEWS            = keccak256("duckfun.arc.v1.DuckBondingCurveViews");
    bytes32 constant SALT_LAUNCHER_IMPL          = keccak256("duckfun.arc.v1.DuckLauncher.impl");
    bytes32 constant SALT_LAUNCHER_PROXY         = keccak256("duckfun.arc.v1.DuckLauncher.proxy");
    bytes32 constant SALT_CROWDFUND_IMPL         = keccak256("duckfun.arc.v1.DuckCrowdfund.impl");
    bytes32 constant SALT_CROWDFUND_PROXY        = keccak256("duckfun.arc.v1.DuckCrowdfund.proxy");
    bytes32 constant SALT_GOVERNOR_IMPL          = keccak256("duckfun.arc.v1.DuckTokenGovernor.impl");
    bytes32 constant SALT_TIMELOCK_IMPL          = keccak256("duckfun.arc.v1.TimelockControllerUpgradeable.impl");
    bytes32 constant SALT_GOVERNOR_FACTORY_IMPL  = keccak256("duckfun.arc.v1.DuckTokenGovernorFactory.impl");
    bytes32 constant SALT_GOVERNOR_FACTORY_PROXY = keccak256("duckfun.arc.v1.DuckTokenGovernorFactory.proxy");

    struct Deployment {
        address proxyFactory;
        address vaultConfig;
        address vaultImpl;
        address hookFactory;
        address hook;
        address vaultFactory;
        address curveToken;
        address launcherToken;
        address crowdfundToken;
        address curve;
        address curveViews;
        address launcher;
        address crowdfund;
        address governorFactory;
    }

    DeterministicProxyFactory private _proxyFactory;

    function run() external returns (Deployment memory d) {
        address owner = vm.envAddress("DEPLOYER_ADDRESS");
        address platformWallet = vm.envOr("PLATFORM_WALLET", owner);
        if (platformWallet == owner) console.log("WARNING: PLATFORM_WALLET not set; fees go to the deployer until changed.");
        d = deployAs(owner, platformWallet);
        _log(d, owner, platformWallet);
    }

    // Public so a fork test can run exactly what the script broadcasts.
    function deployAs(address owner, address platformWallet) public returns (Deployment memory d) {
        if (block.chainid != ARC_CHAIN_ID) revert UnsupportedChain(block.chainid);
        vm.startBroadcast(owner);
        _deployCore(d, owner);
        _deployFamilies(d, owner, platformWallet);
        _deployGovernance(d, owner);
        _wire(d, platformWallet);
        vm.stopBroadcast();
        require(uint160(d.hook) & 0x3FFF == GENESIS_PERMISSIONS, "bad hook permission bits");
    }

    function _deployCore(Deployment memory d, address owner) private {
        _proxyFactory = new DeterministicProxyFactory{salt: SALT_PROXY_FACTORY}(owner);
        d.proxyFactory = address(_proxyFactory);

        address configImpl = address(new DuckVaultConfig{salt: SALT_VAULT_CONFIG_IMPL}());
        d.vaultConfig = _proxyFactory.deploy(SALT_VAULT_CONFIG_PROXY, configImpl, abi.encodeCall(DuckVaultConfig.initialize, (owner)));
        d.vaultImpl = address(new DuckVault{salt: SALT_VAULT_IMPL}());

        // Plain CREATE, not salted: salted creations are relayed through the CREATE2 deployer, which would
        // become the factory's only authorized caller and lock the owner out of deploy().
        DuckGenesisHookFactory hookFactory = new DuckGenesisHookFactory();
        d.hookFactory = address(hookFactory);
        bytes32 hookSalt = _mineHookSalt(address(hookFactory), hookFactory.initCodeHash(ARC_POOL_MANAGER));
        d.hook = hookFactory.deploy(hookSalt, ARC_POOL_MANAGER, owner);

        address vaultFactoryImpl = address(new DuckVaultFactory{salt: SALT_VAULT_FACTORY_IMPL}());
        d.vaultFactory = _proxyFactory.deploy(
            SALT_VAULT_FACTORY_PROXY, vaultFactoryImpl,
            abi.encodeCall(DuckVaultFactory.initialize, (owner, d.vaultImpl, d.vaultConfig, d.hook))
        );

        d.curveToken = address(new DuckCurveToken{salt: SALT_CURVE_TOKEN_IMPL}(d.vaultFactory));
        d.launcherToken = address(new DuckLauncherToken{salt: SALT_LAUNCHER_TOKEN_IMPL}(d.vaultFactory));
        d.crowdfundToken = address(new DuckCrowdfundToken{salt: SALT_CROWDFUND_TOKEN_IMPL}(d.vaultFactory));
    }

    function _deployFamilies(Deployment memory d, address owner, address platformWallet) private {
        _deployCurve(d, owner, platformWallet);
        _deployLauncher(d, owner, platformWallet);
        _deployCrowdfund(d, owner, platformWallet);
    }

    function _deployCurve(Deployment memory d, address owner, address platformWallet) private {
        address impl = address(new DuckBondingCurve{salt: SALT_CURVE_IMPL}());
        d.curve = _proxyFactory.deployAndTransferOwnership(
            SALT_CURVE_PROXY, impl,
            abi.encodeCall(DuckBondingCurve.initialize, (ARC_POSITION_MANAGER, ARC_POOL_MANAGER, d.hook, platformWallet, d.curveToken)),
            owner
        );
        DuckBondingCurve curve = DuckBondingCurve(payable(d.curve));
        curve.acceptOwnership();
        curve.setVaultFactory(d.vaultFactory);
        curve.setUniversalRouter(ARC_UNIVERSAL_ROUTER);
        curve.setQuoteTokenAllowed(ARC_USDC, true);
        curve.setCreationFee(LAUNCH_FEE);
        d.curveViews = address(new DuckBondingCurveViews{salt: SALT_CURVE_VIEWS}(d.curve));
    }

    function _deployLauncher(Deployment memory d, address owner, address platformWallet) private {
        address impl = address(new DuckLauncher{salt: SALT_LAUNCHER_IMPL}());
        d.launcher = _proxyFactory.deployAndTransferOwnership(
            SALT_LAUNCHER_PROXY, impl,
            abi.encodeCall(DuckLauncher.initialize, (d.launcherToken, platformWallet, ARC_POSITION_MANAGER, ARC_POOL_MANAGER, d.hook)),
            owner
        );
        DuckLauncher launcher = DuckLauncher(payable(d.launcher));
        launcher.acceptOwnership();
        launcher.setVaultFactory(d.vaultFactory);
        launcher.setUniversalRouter(ARC_UNIVERSAL_ROUTER);
        launcher.setLaunchFee(LAUNCH_FEE);
    }

    function _deployCrowdfund(Deployment memory d, address owner, address platformWallet) private {
        address impl = address(new DuckCrowdfund{salt: SALT_CROWDFUND_IMPL}());
        d.crowdfund = _proxyFactory.deployAndTransferOwnership(
            SALT_CROWDFUND_PROXY, impl,
            abi.encodeCall(DuckCrowdfund.initialize, (d.crowdfundToken, ARC_POOL_MANAGER, ARC_POSITION_MANAGER, d.hook, platformWallet)),
            owner
        );
        DuckCrowdfund crowdfund = DuckCrowdfund(payable(d.crowdfund));
        crowdfund.acceptOwnership();
        crowdfund.setVaultFactory(d.vaultFactory);
        crowdfund.setUniversalRouter(ARC_UNIVERSAL_ROUTER);
        crowdfund.setQuoteAssetAllowed(ARC_USDC, true);
        crowdfund.setCampaignFee(LAUNCH_FEE);
    }

    function _deployGovernance(Deployment memory d, address owner) private {
        address governorImpl = address(new DuckTokenGovernor{salt: SALT_GOVERNOR_IMPL}());
        address timelockImpl = address(new TimelockControllerUpgradeable{salt: SALT_TIMELOCK_IMPL}());
        address governorFactoryImpl = address(new DuckTokenGovernorFactory{salt: SALT_GOVERNOR_FACTORY_IMPL}());
        d.governorFactory = _proxyFactory.deploy(
            SALT_GOVERNOR_FACTORY_PROXY, governorFactoryImpl,
            abi.encodeCall(DuckTokenGovernorFactory.initialize, (owner, governorImpl, timelockImpl, 1, 50_400))
        );
        DuckVaultFactory(d.vaultFactory).setGovernorFactory(d.governorFactory);
    }

    function _wire(Deployment memory d, address platformWallet) private {
        DuckGenesisHook hook = DuckGenesisHook(payable(d.hook));
        hook.addLauncher(d.curve);
        hook.addLauncher(d.launcher);
        hook.addLauncher(d.crowdfund);
        // Not optional: claimFees reverts without a platform wallet.
        hook.setPlatformWallet(platformWallet);
        // The oracle reads pool state through StateView; without it vault pricing has no TWAP.
        hook.setStateView(ARC_STATE_VIEW);

        DuckVaultFactory vaultFactory = DuckVaultFactory(d.vaultFactory);
        vaultFactory.setFamily(d.curve, true);
        vaultFactory.setFamily(d.launcher, true);
        vaultFactory.setFamily(d.crowdfund, true);
    }

    function _mineHookSalt(address factory, bytes32 initCodeHash) internal pure returns (bytes32 salt) {
        for (uint256 nonce = 0; nonce < 1_000_000; nonce++) {
            salt = bytes32(nonce);
            if (uint160(_computeCreate2Address(salt, initCodeHash, factory)) & 0x3FFF == GENESIS_PERMISSIONS) return salt;
        }
        revert("hook salt not found");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer_) internal pure returns (address addr) {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer_))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), initCodeHash)
            addr := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _log(Deployment memory d, address owner, address platformWallet) private pure {
        console.log("=== DuckProtocol on Arc (5042) ===");
        console.log("Owner:                    ", owner);
        console.log("Platform wallet:          ", platformWallet);
        console.log("DeterministicProxyFactory:", d.proxyFactory);
        console.log("DuckVaultConfig:          ", d.vaultConfig);
        console.log("DuckVault impl:           ", d.vaultImpl);
        console.log("DuckGenesisHookFactory:   ", d.hookFactory);
        console.log("DuckGenesisHook:          ", d.hook);
        console.log("DuckVaultFactory:         ", d.vaultFactory);
        console.log("DuckCurveToken impl:      ", d.curveToken);
        console.log("DuckLauncherToken impl:   ", d.launcherToken);
        console.log("DuckCrowdfundToken impl:  ", d.crowdfundToken);
        console.log("DuckBondingCurve:         ", d.curve);
        console.log("DuckBondingCurveViews:    ", d.curveViews);
        console.log("DuckLauncher:             ", d.launcher);
        console.log("DuckCrowdfund:            ", d.crowdfund);
        console.log("DuckTokenGovernorFactory: ", d.governorFactory);
    }
}
