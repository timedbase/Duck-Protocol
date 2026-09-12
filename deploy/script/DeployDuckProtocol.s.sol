// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — full DuckProtocol deploy to Robinhood Chain (4663) or Ink (57073).
//
// Every contract except DuckHookV4 deploys via CREATE2 with a fixed, named salt, from implementation
// code and (for proxies) empty init data -- so addresses depend only on (deployer EOA, salt,
// implementation), never on chain-specific config. Run from the same deployer on both chains and
// every address comes out identical, even though initialize() wires in different values per chain.
// DeterministicProxyFactory bundles each proxy's deploy and initialize() into one atomic call so
// nobody can front-run the initialize() and take ownership.
//
// DuckHookV4 is the exception: its constructor embeds the chain's PoolManager address, so its own
// address can never match across chains regardless of technique.

import {Script, console} from "forge-std/Script.sol";

import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckBondingCurveViews} from "duck-bonding-curve/DuckBondingCurveViews.sol";
import {DuckLauncher} from "duck-launcher/DuckLauncher.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultFactory} from "duck-lending/DuckVaultFactory.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckTokenGovernor} from "duck-governance/DuckTokenGovernor.sol";
import {DuckTokenGovernorFactory} from "duck-governance/DuckTokenGovernorFactory.sol";
import {TimelockControllerUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {DuckHookFactory} from "./DuckHookFactory.sol";
import {DeterministicProxyFactory} from "./DeterministicProxyFactory.sol";

contract DeployDuckProtocol is Script {

    error UnsupportedChain(uint256 chainId);

    uint256 constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 constant INK_CHAIN_ID       = 57073;

    // Per-chain Uniswap/WETH infrastructure. Unlike everything this script deploys, these already
    // exist and differ per chain, so they're selected at runtime off block.chainid rather than being
    // one hardcoded set -- picking the wrong chain's PoolManager or WETH would not revert, it would
    // silently initialize the whole protocol against addresses that mean nothing on the target
    // chain. Universal Router addresses are verified deployments (see LaunchRouting's header).
    address constant RH_WETH                 = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant RH_V4_POOL_MANAGER      = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant RH_V4_POSITION_MANAGER  = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant RH_UNIVERSAL_ROUTER     = 0x8876789976dEcBfCbBbe364623C63652db8C0904;

    address constant INK_WETH                = 0x4200000000000000000000000000000000000006;
    address constant INK_V4_POOL_MANAGER     = 0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32;
    address constant INK_V4_POSITION_MANAGER = 0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566;
    address constant INK_UNIVERSAL_ROUTER    = 0x112908daC86e20e7241B0927479Ea3Bf935d1fa0;

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

    function _universalRouter() private view returns (address) {
        if (block.chainid == ROBINHOOD_CHAIN_ID) return RH_UNIVERSAL_ROUTER;
        if (block.chainid == INK_CHAIN_ID)       return INK_UNIVERSAL_ROUTER;
        revert UnsupportedChain(block.chainid);
    }

    // Curated from a real on-chain Uniswap liquidity scan (v3 pool-balance reads + v4
    // Quoter-simulated $20,000 swaps): every address below cleared $20,000 of real, usable liquidity
    // against ETH/WETH or a stablecoin at scan time. Native ETH is seeded separately in the launch
    // contracts' own initialize(); WETH is left out since native ETH covers it. See
    // _defaultQuoteTokens below for which list applies where.

    // --- Robinhood Chain (4663) -- 16 of the 19 candidates scanned; LINK and LIT did not clear
    // $20,000 (LINK had no pool with meaningful liquidity, LIT's only pool was worth cents). ---
    address constant RH_BTC   = 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4;
    address constant RH_USDG  = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    address constant RH_TAO   = 0xf3081494B87e8D5fb7960f066E931D1D0e6E3d67;
    address constant RH_U     = 0xcE24439F2D9C6a2289F741120FE202248B666666;
    address constant RH_SPY   = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
    address constant RH_NVDA  = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
    address constant RH_SPCX  = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
    address constant RH_AAPL  = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
    address constant RH_TSLA  = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
    address constant RH_GLD   = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
    address constant RH_GOOGL = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
    address constant RH_QQQ   = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
    address constant RH_MSTR  = 0xec262a75e413fAfD0dF80480274532C79D42da09;
    address constant RH_GME   = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
    address constant RH_AMZN  = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
    address constant RH_MSFT  = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;

    // --- Ink (57073) -- LINK, XAUT0, unwrapped NVDA and SNDK had no pool at all; native USDC had
    // only dust. USDG is included because Ink's tokenized stocks trade against it on v3, and it is
    // reached via the WETH/USDG v3 pool (fee 10000). ---
    address constant INK_BTC          = 0x73E0C0d45E048D25Fc26Fa3159b0aA04BfA4Db98;
    address constant INK_USDT0        = 0x0200C29006150606B650577BBE7B6248F58470c1;
    address constant INK_USDC_BRIDGED = 0xF1815bd50389c46847f0Bda824eC8da914045D14;
    address constant INK_NVDA_WRAPPED = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;
    address constant INK_MSTR_WRAPPED = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB;
    address constant INK_SPY_WRAPPED  = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
    address constant INK_SPCX_WRAPPED = 0x8e2eeD8b8B5E13Ea7BF38e50d7821d2C57309072;
    address constant INK_AAPL_WRAPPED = 0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f;
    address constant INK_NFLX_WRAPPED = 0x7d87fD6A379714194a797c0bBB8B40c30D250856;
    address constant INK_TSLA_WRAPPED = 0xc3FdBe3A68EE5dE461D30415a8165cf9Aefe1171;
    address constant INK_USDG         = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;


    // Named, versioned salts -- one per deployed contract. "v1" so a future redeploy of any single
    // piece can move to a new salt without disturbing everything else's address.
    bytes32 constant SALT_PROXY_FACTORY          = keccak256("duckfun.v1.DeterministicProxyFactory");
    bytes32 constant SALT_VAULT_CONFIG_IMPL      = keccak256("duckfun.v1.DuckVaultConfig.impl");
    bytes32 constant SALT_VAULT_CONFIG_PROXY     = keccak256("duckfun.v1.DuckVaultConfig.proxy");
    bytes32 constant SALT_VAULT_IMPL             = keccak256("duckfun.v1.DuckVault.impl");
    bytes32 constant SALT_VAULT_FACTORY_IMPL     = keccak256("duckfun.v1.DuckVaultFactory.impl");
    bytes32 constant SALT_VAULT_FACTORY_PROXY    = keccak256("duckfun.v1.DuckVaultFactory.proxy");
    bytes32 constant SALT_TOKEN_IMPL             = keccak256("duckfun.v1.DuckToken.impl");
    bytes32 constant SALT_CURVE_IMPL             = keccak256("duckfun.v1.DuckBondingCurve.impl");
    bytes32 constant SALT_CURVE_PROXY            = keccak256("duckfun.v1.DuckBondingCurve.proxy");
    bytes32 constant SALT_CURVE_VIEWS            = keccak256("duckfun.v1.DuckBondingCurveViews");
    bytes32 constant SALT_LAUNCHER_IMPL          = keccak256("duckfun.v1.DuckLauncher.impl");
    bytes32 constant SALT_LAUNCHER_PROXY         = keccak256("duckfun.v1.DuckLauncher.proxy");
    bytes32 constant SALT_CROWDFUND_IMPL         = keccak256("duckfun.v1.DuckCrowdfund.impl");
    bytes32 constant SALT_CROWDFUND_PROXY        = keccak256("duckfun.v1.DuckCrowdfund.proxy");
    bytes32 constant SALT_GOVERNOR_IMPL          = keccak256("duckfun.v1.DuckTokenGovernor.impl");
    bytes32 constant SALT_TIMELOCK_IMPL          = keccak256("duckfun.v1.TimelockControllerUpgradeable.impl");
    bytes32 constant SALT_GOVERNOR_FACTORY_IMPL  = keccak256("duckfun.v1.DuckTokenGovernorFactory.impl");
    bytes32 constant SALT_GOVERNOR_FACTORY_PROXY = keccak256("duckfun.v1.DuckTokenGovernorFactory.proxy");

    // Set once in _deployCore, read by every function that deploys a proxy -- avoids threading it
    // through every _deployX function's parameter list (extra params on already-tight signatures is
    // exactly what triggered stack-too-deep elsewhere in this file before; see _deployCore's comment).
    DeterministicProxyFactory private _proxyFactory;

    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer    = deployerKey != 0 ? vm.addr(deployerKey) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "Set DEPLOYER_ADDRESS (with --account/--ledger) or PRIVATE_KEY");

        address platformWallet = vm.envOr("PLATFORM_WALLET", deployer);
        if (platformWallet == deployer) {
            console.log("WARNING: PLATFORM_WALLET not set, defaulting to the deployer address.");
            console.log("Move fee collection to a treasury/multisig before real funds flow through this.");
        }

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast(deployer);
        }

        (address vaultFactoryAddr, address tokenImplAddr, address hookAddr) =
            _deployCore(deployer);

        (address curveAddr, address launcherAddr, address crowdfundAddr) =
            _deployFamilies(deployer, platformWallet, hookAddr, vaultFactoryAddr, tokenImplAddr);

        _deployGovernanceAndWire(deployer, hookAddr, vaultFactoryAddr, platformWallet, curveAddr, launcherAddr, crowdfundAddr);

        vm.stopBroadcast();

        console.log("");
        console.log("=== DuckProtocol deployment complete ===");
        console.log("Owner (all governance-controlled contracts):", deployer);
        console.log("Platform wallet (fee recipient):             ", platformWallet);
        console.log("");
        console.log("Same deployer + these same salts on a different chain reproduces every address");
        console.log("below except DuckHookV4 -- its PoolManager constructor arg is chain-specific.");
        console.log("");
        console.log("Not done by this script -- do these yourself when ready:");
        console.log("  setRoutes(...) per quote token -- needs real pool fee/tickSpacing per chain");
        console.log("  Transferring ownership off the deployer key to a treasury/multisig");
    }

    // Split into small single-purpose functions rather than one big one: a single function embedding
    // this many contracts' creation code plus proxies and console.log calls hits a genuine via-IR
    // stack-too-deep even with the optimizer on.
    function _deployCore(address deployer)
        private returns (address vaultFactoryAddr, address tokenImplAddr, address hookAddr)
    {
        _proxyFactory = new DeterministicProxyFactory{salt: SALT_PROXY_FACTORY}(deployer);
        console.log("DeterministicProxyFactory:", address(_proxyFactory));

        address configProxy = _deployVaultConfig(deployer);
        address vaultImpl = _deployVaultImpl();
        hookAddr = _deployHook(deployer);
        vaultFactoryAddr = _deployVaultFactory(deployer, vaultImpl, configProxy, hookAddr);
        tokenImplAddr = _deployTokenImpl(vaultFactoryAddr);
    }

    function _deployVaultConfig(address deployer) private returns (address configProxy) {
        address configImpl = address(new DuckVaultConfig{salt: SALT_VAULT_CONFIG_IMPL}());
        configProxy = _proxyFactory.deploy(
            SALT_VAULT_CONFIG_PROXY, configImpl, abi.encodeCall(DuckVaultConfig.initialize, (deployer))
        );
        console.log("DuckVaultConfig impl: ", configImpl);
        console.log("DuckVaultConfig proxy:", configProxy);
    }

    function _deployVaultImpl() private returns (address vaultImpl) {
        vaultImpl = address(new DuckVault{salt: SALT_VAULT_IMPL}());
        console.log("DuckVault impl:       ", vaultImpl);
    }

    function _deployHook(address deployer) private returns (address hookAddr) {
        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(DuckHookV4).creationCode,
            abi.encode(_v4PoolManager())
        ));
        (bytes32 hookSalt, address predictedHook) = _mineHookSalt(address(hookFactory), initCodeHash);
        hookAddr = hookFactory.deploy(hookSalt, _v4PoolManager(), deployer);
        require(hookAddr == predictedHook, "hook address mismatch");
        require(uint160(hookAddr) & 0x3FFF == 0x2CC, "bad hook permission bits");
        console.log("DuckHookFactory:   ", address(hookFactory));
        console.log("DuckHookV4:        ", hookAddr);
    }

    function _deployVaultFactory(address deployer, address vaultImpl, address configProxy, address hookAddr)
        private returns (address vaultFactoryAddr)
    {
        address vaultFactoryImpl = address(new DuckVaultFactory{salt: SALT_VAULT_FACTORY_IMPL}());
        vaultFactoryAddr = _proxyFactory.deploy(
            SALT_VAULT_FACTORY_PROXY, vaultFactoryImpl,
            abi.encodeCall(DuckVaultFactory.initialize, (deployer, vaultImpl, configProxy, hookAddr))
        );
        console.log("DuckVaultFactory impl: ", vaultFactoryImpl);
        console.log("DuckVaultFactory proxy:", vaultFactoryAddr);
    }

    function _deployTokenImpl(address vaultFactoryAddr) private returns (address tokenImplAddr) {
        tokenImplAddr = address(new DuckToken{salt: SALT_TOKEN_IMPL}(vaultFactoryAddr));
        console.log("DuckToken impl:", tokenImplAddr);
    }

    function _deployFamilies(
        address deployer, address platformWallet, address hookAddr, address vaultFactoryAddr, address tokenImplAddr
    ) private returns (address curveAddr, address launcherAddr, address crowdfundAddr) {
        curveAddr = _deployCurve(deployer, platformWallet, hookAddr, vaultFactoryAddr, tokenImplAddr);
        launcherAddr = _deployLauncher(deployer, platformWallet, hookAddr, vaultFactoryAddr, tokenImplAddr);
        crowdfundAddr = _deployCrowdfund(deployer, platformWallet, hookAddr, vaultFactoryAddr, tokenImplAddr);
    }

    function _deployCurve(
        address deployer, address platformWallet, address hookAddr, address vaultFactoryAddr, address tokenImplAddr
    ) private returns (address curveAddr) {
        address curveImpl = address(new DuckBondingCurve{salt: SALT_CURVE_IMPL}());
        curveAddr = _proxyFactory.deployAndTransferOwnership(
            SALT_CURVE_PROXY, curveImpl,
            abi.encodeCall(DuckBondingCurve.initialize, (
                _weth(), _v4PositionManager(), _v4PoolManager(), hookAddr, platformWallet, tokenImplAddr
            )),
            deployer
        );
        DuckBondingCurve curve = DuckBondingCurve(payable(curveAddr));
        curve.acceptOwnership();
        curve.setVaultFactory(vaultFactoryAddr);
        curve.setUniversalRouter(_universalRouter());
        _seedCurveQuoteTokens(curve);
        address curveViews = address(new DuckBondingCurveViews{salt: SALT_CURVE_VIEWS}(curveAddr));
        console.log("DuckBondingCurve impl:  ", curveImpl);
        console.log("DuckBondingCurve proxy: ", curveAddr);
        console.log("DuckBondingCurveViews:  ", curveViews);
    }

    function _deployLauncher(
        address deployer, address platformWallet, address hookAddr, address vaultFactoryAddr, address tokenImplAddr
    ) private returns (address launcherAddr) {
        address launcherImpl = address(new DuckLauncher{salt: SALT_LAUNCHER_IMPL}());
        launcherAddr = _proxyFactory.deployAndTransferOwnership(
            SALT_LAUNCHER_PROXY, launcherImpl,
            abi.encodeCall(DuckLauncher.initialize, (
                _weth(), tokenImplAddr, platformWallet, _v4PositionManager(), _v4PoolManager(), hookAddr
            )),
            deployer
        );
        DuckLauncher launcher = DuckLauncher(payable(launcherAddr));
        launcher.acceptOwnership();
        launcher.setVaultFactory(vaultFactoryAddr);
        launcher.setUniversalRouter(_universalRouter());
        _seedLauncherQuoteTokens(launcher);
        console.log("DuckLauncher impl: ", launcherImpl);
        console.log("DuckLauncher proxy:", launcherAddr);
    }

    function _deployCrowdfund(
        address deployer, address platformWallet, address hookAddr, address vaultFactoryAddr, address tokenImplAddr
    ) private returns (address crowdfundAddr) {
        address crowdfundImpl = address(new DuckCrowdfund{salt: SALT_CROWDFUND_IMPL}());
        crowdfundAddr = _proxyFactory.deployAndTransferOwnership(
            SALT_CROWDFUND_PROXY, crowdfundImpl,
            abi.encodeCall(DuckCrowdfund.initialize, (
                _weth(), tokenImplAddr, _v4PoolManager(), _v4PositionManager(), hookAddr, platformWallet
            )),
            deployer
        );
        DuckCrowdfund crowdfund = DuckCrowdfund(payable(crowdfundAddr));
        crowdfund.acceptOwnership();
        crowdfund.setVaultFactory(vaultFactoryAddr);
        crowdfund.setUniversalRouter(_universalRouter());
        _seedCrowdfundQuoteAssets(crowdfund);
        console.log("DuckCrowdfund impl: ", crowdfundImpl);
        console.log("DuckCrowdfund proxy:", crowdfundAddr);
    }

    function _deployGovernanceAndWire(
        address deployer, address hookAddr, address vaultFactoryAddr, address platformWallet,
        address curveAddr, address launcherAddr, address crowdfundAddr
    ) private {
        _deployGovernance(deployer, vaultFactoryAddr);
        _wireProtocol(hookAddr, vaultFactoryAddr, platformWallet, curveAddr, launcherAddr, crowdfundAddr);
    }

    function _deployGovernance(address deployer, address vaultFactoryAddr) private {
        address governorImpl = address(new DuckTokenGovernor{salt: SALT_GOVERNOR_IMPL}());
        address timelockImpl = address(new TimelockControllerUpgradeable{salt: SALT_TIMELOCK_IMPL}());
        address governorFactoryImpl = address(new DuckTokenGovernorFactory{salt: SALT_GOVERNOR_FACTORY_IMPL}());
        address governorFactoryProxy = _proxyFactory.deploy(
            SALT_GOVERNOR_FACTORY_PROXY, governorFactoryImpl,
            abi.encodeCall(DuckTokenGovernorFactory.initialize, (deployer, governorImpl, timelockImpl, 1, 50_400))
        );
        DuckVaultFactory(vaultFactoryAddr).setGovernorFactory(governorFactoryProxy);
        console.log("DuckTokenGovernor impl:        ", governorImpl);
        console.log("TimelockController impl:       ", timelockImpl);
        console.log("DuckTokenGovernorFactory impl: ", governorFactoryImpl);
        console.log("DuckTokenGovernorFactory proxy:", governorFactoryProxy);
    }

    function _wireProtocol(
        address hookAddr, address vaultFactoryAddr, address platformWallet,
        address curveAddr, address launcherAddr, address crowdfundAddr
    ) private {
        DuckHookV4 hook = DuckHookV4(payable(hookAddr));
        hook.addLauncher(curveAddr);
        hook.addLauncher(launcherAddr);
        hook.addLauncher(crowdfundAddr);
        hook.setWeth(_weth());
        // Not optional: the platform cut reverts on a zero platformWallet, so leaving this unset
        // would make claimFees revert for every pool (and block CTO applications too).
        hook.setPlatformWallet(platformWallet);

        DuckVaultFactory vaultFactory = DuckVaultFactory(vaultFactoryAddr);
        vaultFactory.setFamily(curveAddr, true);
        vaultFactory.setFamily(launcherAddr, true);
        vaultFactory.setFamily(crowdfundAddr, true);
    }

    // The Universal Router itself is wired at deploy time (setUniversalRouter, per chain), but no
    // default ROUTES are seeded -- that would mean guessing pool fee/tickSpacing instead of reading
    // them off a real pool. Set them via setRoutes on each launch contract once scanned; until then
    // buyWithNative/sellForNative have nothing to route through and revert with RouteUnavailable.

    // The curated lists above are meaningless -- or actively wrong, if unrelated code sits at the
    // same address -- on any chain they weren't scanned for. Gate seeding on chain ID rather than
    // guess equivalents; set real ones via setQuoteTokenAllowed/setQuoteAssetAllowed once scanned.
    function _seedCurveQuoteTokens(DuckBondingCurve curve) internal {
        address[] memory tokens = _defaultQuoteTokens();
        if (tokens.length == 0) {
            console.log("No curated default quote tokens for this chain -- set them via curve.setQuoteTokenAllowed(...) once scanned.");
            return;
        }
        for (uint256 i; i < tokens.length; i++) {
            curve.setQuoteTokenAllowed(tokens[i], true);
        }
    }

    // The launcher seeds only native ETH in its own initialize(); its ERC20 quote tokens come from
    // the same per-chain curated list the curve and crowdfund use, so all three stay in lockstep.
    function _seedLauncherQuoteTokens(DuckLauncher launcher) internal {
        address[] memory tokens = _defaultQuoteTokens();
        if (tokens.length == 0) {
            console.log("No curated default quote tokens for this chain -- set them via launcher.addQuoteToken(...) once scanned.");
            return;
        }
        for (uint256 i; i < tokens.length; i++) {
            launcher.addQuoteToken(tokens[i]);
        }
    }

    function _seedCrowdfundQuoteAssets(DuckCrowdfund crowdfund) internal {
        address[] memory tokens = _defaultQuoteTokens();
        if (tokens.length == 0) {
            console.log("No curated default quote assets for this chain -- set them via crowdfund.setQuoteAssetAllowed(...) once scanned.");
            return;
        }
        for (uint256 i; i < tokens.length; i++) {
            crowdfund.setQuoteAssetAllowed(tokens[i], true);
        }
    }

    function _defaultQuoteTokens() private view returns (address[] memory tokens) {
        if (block.chainid == ROBINHOOD_CHAIN_ID) {
            tokens = new address[](16);
            tokens[0]  = RH_BTC;
            tokens[1]  = RH_USDG;
            tokens[2]  = RH_TAO;
            tokens[3]  = RH_U;
            tokens[4]  = RH_SPY;
            tokens[5]  = RH_NVDA;
            tokens[6]  = RH_SPCX;
            tokens[7]  = RH_AAPL;
            tokens[8]  = RH_TSLA;
            tokens[9]  = RH_GLD;
            tokens[10] = RH_GOOGL;
            tokens[11] = RH_QQQ;
            tokens[12] = RH_MSTR;
            tokens[13] = RH_GME;
            tokens[14] = RH_AMZN;
            tokens[15] = RH_MSFT;
        } else if (block.chainid == INK_CHAIN_ID) {
            tokens = new address[](11);
            tokens[0] = INK_BTC;
            tokens[1] = INK_USDT0;
            tokens[2] = INK_USDC_BRIDGED;
            tokens[3] = INK_NVDA_WRAPPED;
            tokens[4] = INK_MSTR_WRAPPED;
            tokens[5] = INK_SPY_WRAPPED;
            tokens[6] = INK_SPCX_WRAPPED;
            tokens[7] = INK_AAPL_WRAPPED;
            tokens[8] = INK_NFLX_WRAPPED;
            tokens[9] = INK_TSLA_WRAPPED;
            tokens[10] = INK_USDG;
        }
        // else: tokens stays empty -- unknown chain, nothing curated yet.
    }

    function _mineHookSalt(address factory, bytes32 initCodeHash)
        internal pure returns (bytes32 salt, address predicted)
    {
        for (uint256 nonce = 0; nonce < 200_000; nonce++) {
            salt = bytes32(nonce);
            predicted = _computeCreate2Address(salt, initCodeHash, factory);
            if (uint160(predicted) & 0x3FFF == 0x2CC) return (salt, predicted);
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
}
