// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckLauncher} from "duck-launcher/DuckLauncher.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultFactory} from "duck-lending/DuckVaultFactory.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";
import {PoolKey, SwapParams, ModifyLiquidityParams} from "duck-lib/LaunchRouting.sol";

interface IStateViewFork2 {
    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

interface IPoolManagerSwapFork {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feeDelta);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

interface IERC20Fork {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

contract DuckProtocolLauncherForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant V4_STATE_VIEW       = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    uint24  constant FEE_TIER            = 0;
    int24   constant TICK_SPACING        = 200;

    DuckLauncher launcher;
    DuckHookV4 hook;
    DuckToken tokenImpl;
    DuckVaultFactory vaultFactory;

    address owner   = makeAddr("dpl-owner");
    address platform = makeAddr("dpl-platform");
    address creator = makeAddr("dpl-creator");
    address trader  = makeAddr("dpl-trader");

    uint256 private _tokenSaltNonceCursor;
    address private _cbExpected;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        vm.etch(owner, "");
        vm.etch(platform, "");
        vm.etch(creator, "");
        vm.etch(trader, "");

        vm.startPrank(owner);

        DuckVaultConfig configImpl = new DuckVaultConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl), abi.encodeCall(DuckVaultConfig.initialize, (owner))
        );
        DuckVault vaultImpl = new DuckVault();

        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(DuckHookV4).creationCode, abi.encode(V4_POOL_MANAGER)));
        (bytes32 hookSalt,) = _mineHookSalt(address(hookFactory), initCodeHash);
        address hookAddr = hookFactory.deploy(hookSalt, V4_POOL_MANAGER, owner);
        hook = DuckHookV4(payable(hookAddr));
        require(uint160(hookAddr) & 0x3FFF == 0x2CC, "bad hook permission bits");

        DuckVaultFactory vaultFactoryImpl = new DuckVaultFactory();
        ERC1967Proxy vaultFactoryProxy = new ERC1967Proxy(
            address(vaultFactoryImpl),
            abi.encodeCall(DuckVaultFactory.initialize, (owner, address(vaultImpl), address(configProxy), hookAddr))
        );
        vaultFactory = DuckVaultFactory(address(vaultFactoryProxy));

        tokenImpl = new DuckToken(address(vaultFactory));

        DuckLauncher launcherImpl = new DuckLauncher();
        ERC1967Proxy launcherProxy = new ERC1967Proxy(
            address(launcherImpl),
            abi.encodeCall(DuckLauncher.initialize, (
                WETH, address(tokenImpl), platform,
                V4_POSITION_MANAGER, V4_POOL_MANAGER, hookAddr
            ))
        );
        launcher = DuckLauncher(payable(address(launcherProxy)));
        launcher.setVaultFactory(address(vaultFactory));

        hook.addLauncher(address(launcher));
        hook.setWeth(WETH);
        hook.setPlatformWallet(platform);
        vaultFactory.setFamily(address(launcher), true);

        vm.stopPrank();

        vm.deal(creator, 1_000 ether);
        vm.deal(trader, 1_000 ether);
    }

    function _mineHookSalt(address factory, bytes32 initCodeHash) internal pure returns (bytes32 salt, address predicted) {
        for (uint256 nonce = 0; nonce < 200_000; nonce++) {
            salt = bytes32(nonce);
            predicted = _computeCreate2Address(salt, initCodeHash, factory);
            if (uint160(predicted) & 0x3FFF == 0x2CC) return (salt, predicted);
        }
        revert("hook salt not found");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer) internal pure returns (address addr) {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), initCodeHash)
            addr := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _saltFor(address creator_, bytes32 userSalt) internal pure returns (bytes32 salt) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, creator_)
            mstore(add(ptr, 32), userSalt)
            salt := keccak256(ptr, 64)
        }
    }

    function _mineTokenSalt(address creator_) internal returns (bytes32 userSalt) {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            address(tokenImpl),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 initCodeHash = keccak256(initCode);
        uint256 nonce = _tokenSaltNonceCursor;
        for (uint256 i = 0; i < 1_000_000; i++) {
            userSalt = bytes32(nonce + i);
            bytes32 salt = _saltFor(creator_, userSalt);
            address predicted = _computeCreate2Address(salt, initCodeHash, address(launcher));
            if (uint16(uint160(predicted)) == 0x8888) {
                _tokenSaltNonceCursor = nonce + i + 1;
                return userSalt;
            }
        }
        revert("token salt not found");
    }

    function _baseLaunchParams(bytes32 salt) internal pure returns (DuckLauncher.LaunchParams memory p) {
        p.name             = "Duck Token";
        p.symbol           = "DUCK";
        p.metaURI          = "";
        p.feeWallet        = address(0);
        p.positionManager  = V4_POSITION_MANAGER;
        p.quoteToken       = address(0);
        p.vanitySalt       = salt;
        p.launchMarketCap  = 5 ether;
        p.minQuoteOut      = 0;
        p.minTokensOut     = 0;
        p.hookFeeBps       = 0;
        p.creatorBps       = 9000;
        p.vaultBps         = 1000;
        p.revertOnInstantBuyFailure = false;
    }

    function test_NonDefaultSupplyTierProducesRealCorrectSupply() public {
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));
        p.supplyTier = 6;

        vm.prank(creator);
        (address token,) = launcher.launch{value: 0.0005 ether}(p);

        assertEq(DuckToken(payable(token)).totalSupply(), 1_000_000_000_000_000e18, "tier 4 must resolve to 1Q on the real deployed token");
    }

    function test_NativeQuotedLaunchLinksVaultToWeth() public {
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));

        vm.prank(creator);
        (address token, bytes32 poolId) = launcher.launch{value: 0.0005 ether}(p);

        address vault = DuckToken(payable(token)).vault();
        assertTrue(vault != address(0), "vault must be created at launch");
        assertTrue(DuckVault(payable(vault)).enabled(), "linkPool must have succeeded, not been silently swallowed");
        assertEq(DuckVault(payable(vault)).currency(), WETH, "vault currency must normalize to WETH even for a native-quoted pool");
        assertEq(DuckVault(payable(vault)).poolId(), poolId);

        (uint160 sqrtPriceX96,,,) = IStateViewFork2(V4_STATE_VIEW).getSlot0(poolId);
        assertGt(sqrtPriceX96, 0);
    }

    function test_PermissionlessQuoteTokenLaunchWorksForArbitraryNonWhitelistedToken() public {
        MockErc20Fork arbitrary = new MockErc20Fork();
        assertFalse(launcher.quoteTokens(address(arbitrary)), "must not be on the curated allowlist");

        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));
        p.quoteToken = address(arbitrary);
        p.launchMarketCap = 10 ether;

        vm.prank(creator);
        (address token, bytes32 poolId) = launcher.launch{value: 0.0005 ether}(p);

        address vault = DuckToken(payable(token)).vault();
        assertTrue(DuckVault(payable(vault)).enabled(), "an arbitrary, never-whitelisted quote token must still link a real pool/vault");
        assertEq(DuckVault(payable(vault)).currency(), address(arbitrary));
        assertEq(DuckVault(payable(vault)).poolId(), poolId);
    }

    function test_MalformedDecimalsQuoteTokenDoesNotBrickLaunchOnlySkipsVaultLink() public {
        MockDirtyDecimalsErc20Fork broken = new MockDirtyDecimalsErc20Fork();

        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));
        p.quoteToken = address(broken);
        p.launchMarketCap = 10 ether;

        vm.prank(creator);
        (address token,) = launcher.launch{value: 0.0005 ether}(p);

        assertTrue(token != address(0), "launch itself must succeed despite the broken quote token");
        address vault = DuckToken(payable(token)).vault();
        assertTrue(vault != address(0), "vault must still be created (that call never touches the quote token)");
        assertFalse(DuckVault(payable(vault)).enabled(), "vault linking must be skipped, not reverted, for an unreadable decimals()");
    }

    function test_Erc20QuotedLaunchLinksVaultCorrectly() public {
        address USDG = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
        vm.prank(owner);
        launcher.addQuoteToken(USDG);

        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));
        p.quoteToken = USDG;
        p.launchMarketCap = 10_000e6;

        vm.prank(creator);
        (address token,) = launcher.launch{value: 0.0005 ether}(p);

        address vault = DuckToken(payable(token)).vault();
        assertTrue(DuckVault(payable(vault)).enabled());
        assertEq(DuckVault(payable(vault)).currency(), USDG);
        assertEq(DuckVault(payable(vault)).currencyDecimals(), 6);
    }

    function test_RealSellSwapAccruesHookFeeAndSplitsToVault() public {
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));
        p.launchMarketCap = 100 ether;

        vm.prank(creator);
        (address token, bytes32 poolId) = launcher.launch{value: 0.0005 ether + 0.05 ether}(p);

        uint256 creatorTokens = DuckToken(payable(token)).balanceOf(creator);
        assertGt(creatorTokens, 0, "instant buy should have landed tokens on the creator to sell");

        vm.prank(creator);
        DuckToken(payable(token)).transfer(trader, creatorTokens);

        address vault = DuckToken(payable(token)).vault();
        uint256 reservesBefore = DuckVault(payable(vault)).totalReserves();

        bool tokenIsC0 = token < address(0);
        PoolKey memory key = PoolKey({
            currency0: tokenIsC0 ? token : address(0),
            currency1: tokenIsC0 ? address(0) : token,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });
        vm.prank(trader);
        uint256 sellAmount = creatorTokens / 10;
        IERC20Fork(token).approve(address(this), sellAmount);
        // Advance a block: this trade and the launch's own instantBuy above represent two genuinely
        // separate real-world transactions (different traders), which would always carry different
        // tx.origin in practice -- the hook's SameBlockSwap guard keys on tx.origin, which Foundry's
        // single-arg vm.prank doesn't vary.
        vm.roll(block.number + 1);
        _sell(key, token, tokenIsC0, sellAmount, trader);

        (,,,, uint256 hookFeeBps, uint16 vaultBps) = _readPoolInfo(poolId);
        assertGt(hookFeeBps, 0);
        assertEq(vaultBps, 1000);
        assertGt(hook.accruedFees(poolId), 0, "the sell should have accrued a hook fee");

        hook.claimFees(poolId);

        uint256 reservesAfter = DuckVault(payable(vault)).totalReserves();
        assertGt(reservesAfter, reservesBefore, "vault must have received its 10% cut of the hook fee");
    }

    // Pins the exact new split introduced this session: 25% platform / 5% holders / 70% remainder
    // shared between vault and creator via vaultBps -- each computed directly off the ORIGINAL total,
    // not chained off a shrinking remainder, so they must sum to exactly the claimed amount modulo
    // integer-division dust. Claimed by the creator themselves so the separate claimer-reward path
    // (see test_NonCreatorClaimerEarnsOnePercentCarvedFromPlatform) doesn't also fire here.
    function test_HookFeeSplitsExactly25PlatformFiveHolderRestVaultCreator() public {
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));
        p.launchMarketCap = 100 ether;
        p.hookFeeBps = 1000; // 10%, within the new 2-10% creator-configurable range
        p.creatorBps = 5000; // 50% of the 70% remainder to creator, rest to vault
        p.vaultBps = 5000;   // 50% of the 70% remainder to vault, rest to creator

        vm.prank(creator);
        (address token, bytes32 poolId) = launcher.launch{value: 0.0005 ether + 0.05 ether}(p);

        uint256 creatorTokens = DuckToken(payable(token)).balanceOf(creator);
        vm.prank(creator);
        DuckToken(payable(token)).transfer(trader, creatorTokens);

        bool tokenIsC0 = token < address(0);
        PoolKey memory key = PoolKey({
            currency0: tokenIsC0 ? token : address(0),
            currency1: tokenIsC0 ? address(0) : token,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });
        uint256 sellAmount = creatorTokens / 10;
        vm.prank(trader);
        IERC20Fork(token).approve(address(this), sellAmount);
        vm.roll(block.number + 1);
        _sell(key, token, tokenIsC0, sellAmount, trader);

        uint256 amount = hook.accruedFees(poolId);
        assertGt(amount, 0, "the sell should have accrued a real hook fee");

        address vault = DuckToken(payable(token)).vault();
        uint256 platformBefore = platform.balance;
        uint256 creatorBefore = creator.balance;
        uint256 vaultReservesBefore = DuckVault(payable(vault)).totalReserves();
        uint256 roundPoolBefore = DuckToken(payable(token)).roundPool();

        vm.prank(creator);
        hook.claimFees(poolId);

        uint256 platformCut = (amount * 2500) / 10_000;
        uint256 holderCut = (amount * 500) / 10_000;
        uint256 remainder = amount - platformCut - holderCut;
        uint256 vaultCut = (remainder * 5000) / 10_000;
        uint256 creatorCut = remainder - vaultCut;

        assertEq(platform.balance - platformBefore, platformCut, "platform must receive exactly 25% of the total hook fee when the creator claims their own fees");
        assertEq(DuckToken(payable(token)).roundPool() - roundPoolBefore, holderCut, "holders must receive exactly 5% of the total hook fee");
        assertEq(DuckVault(payable(vault)).totalReserves() - vaultReservesBefore, vaultCut, "vault must receive exactly its vaultBps share of the 70% remainder");
        assertEq(creator.balance - creatorBefore, creatorCut, "creator must receive exactly the rest -- the three cuts must sum to the full claimed amount");
    }

    // The keeper incentive: whoever actually calls claimFees earns 1% of the total, carved out of the
    // PLATFORM's own share (25% -> 24%) -- holders and the vault/creator split are untouched either
    // way. The creator earns no such bonus for claiming their own fees.
    function test_NonCreatorClaimerEarnsOnePercentCarvedFromPlatform() public {
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));
        p.launchMarketCap = 100 ether;
        p.hookFeeBps = 1000;
        p.creatorBps = 5000;
        p.vaultBps = 5000;

        vm.prank(creator);
        (address token, bytes32 poolId) = launcher.launch{value: 0.0005 ether + 0.05 ether}(p);

        uint256 creatorTokens = DuckToken(payable(token)).balanceOf(creator);
        vm.prank(creator);
        DuckToken(payable(token)).transfer(trader, creatorTokens);

        bool tokenIsC0 = token < address(0);
        PoolKey memory key = PoolKey({
            currency0: tokenIsC0 ? token : address(0),
            currency1: tokenIsC0 ? address(0) : token,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });
        uint256 sellAmount = creatorTokens / 10;
        vm.prank(trader);
        IERC20Fork(token).approve(address(this), sellAmount);
        vm.roll(block.number + 1);
        _sell(key, token, tokenIsC0, sellAmount, trader);

        uint256 amount = hook.accruedFees(poolId);
        assertGt(amount, 0, "the sell should have accrued a real hook fee");

        address stranger = makeAddr("dpl-stranger");
        uint256 platformBefore = platform.balance;
        uint256 strangerBefore = stranger.balance;

        vm.prank(stranger);
        hook.claimFees(poolId);

        uint256 platformCut = (amount * 2400) / 10_000; // 24%, not 25%, since a non-creator claimed
        uint256 claimerCut = (amount * 100) / 10_000;    // the 1% carved out of the platform's share

        assertEq(platform.balance - platformBefore, platformCut, "platform must receive only 24% when someone other than the creator triggers the claim");
        assertEq(stranger.balance - strangerBefore, claimerCut, "the caller must receive exactly 1% of the total claimed amount");
    }

    // Vault/lending is opt-in: a creator who sets vaultBps = 0 at launch gets no vault deployed for
    // that token at all, not just a vault that happens to receive a zero cut.
    function test_VaultBpsZeroSkipsVaultDeploymentEntirely() public {
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));
        p.creatorBps = 10_000;
        p.vaultBps = 0;

        vm.prank(creator);
        (address token,) = launcher.launch{value: 0.0005 ether}(p);

        assertEq(DuckToken(payable(token)).vault(), address(0), "vaultBps == 0 must mean no vault is ever deployed");
    }

    // The whole point of minting directly against the PoolManager instead of through a
    // PositionManager-minted, DEAD-burned NFT: liquidity must be permanently locked with no NFT ever
    // needed to enforce that. This proves the lock is also enforced at the hook level, independent of
    // whether any of our own contracts happen to expose a way to call modifyLiquidity with a negative
    // delta -- a real removal attempt against the real PoolManager, on the pool's real full range,
    // must revert with the hook's own error, not just fail for some incidental reason.
    function test_AttemptingToRemoveLiquidityAlwaysReverts() public {
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));

        vm.prank(creator);
        (address token,) = launcher.launch{value: 0.0005 ether}(p);

        bool tokenIsC0 = token < address(0);
        PoolKey memory key = PoolKey({
            currency0: tokenIsC0 ? token : address(0),
            currency1: tokenIsC0 ? address(0) : token,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });

        // v4-core wraps a reverting hook call in its own CustomRevert error rather than letting the
        // hook's own selector surface directly (confirmed via trace: DuckHookV4.beforeRemoveLiquidity
        // itself reverts with exactly LiquidityRemovalDisabled() underneath), so match any revert here
        // rather than a specific selector.
        vm.expectRevert();
        _attemptRemoveLiquidity(key, -887_200, 887_200, -1);
    }

    // The launcher accepts any hook fee up to 10% (DuckGenesisHook's ceiling), with 0 still meaning the
    // hook's 2% default -- only rates above 10% are the launcher's to reject. This suite's hook is
    // DuckHookV4, which still enforces its own 2/4/6/8/10 menu, so a rate below the ceiling is checked
    // against a menu value here; arbitrary rates are covered end to end in DuckGenesisUpgrade.fork.t.sol.
    function test_HookFeeBpsAcceptsAnyRateUpToTenPercent() public {
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));

        p.hookFeeBps = 1001; // just above the 10% ceiling
        vm.prank(creator);
        vm.expectRevert(DuckLauncher.InvalidHookFeeBps.selector);
        launcher.launch{value: 0.0005 ether}(p);

        p.hookFeeBps = 1100;
        vm.prank(creator);
        vm.expectRevert(DuckLauncher.InvalidHookFeeBps.selector);
        launcher.launch{value: 0.0005 ether}(p);

        p.vanitySalt = _mineTokenSalt(creator);
        p.hookFeeBps = 1000; // exactly the ceiling -- must succeed
        vm.prank(creator);
        (address token,) = launcher.launch{value: 0.0005 ether}(p);
        assertTrue(token != address(0));
    }

    // Everything above exercises the reward mechanism with a handful of holders -- fine for
    // correctness, but the gas cost of a real batch only actually shows up with enough real holders
    // to force several processBatch() calls. This launches one real token, spreads it across 500
    // distinct real wallets (450 realistically small, 50 comfortably above MIN_HOLDING_BPS), accrues a
    // real fee via a real sell, claims it, and then drives the entire distribution round purely
    // through direct processBatch() calls -- exactly the path anyone (or DuckKeeper, on its schedule)
    // would take in production, since processBatch is not wired into _transfer at all -- measuring
    // what each call actually costs along the way.
    function test_RewardDistributionAcross500RealHolders() public {
        DuckLauncher.LaunchParams memory p = _baseLaunchParams(_mineTokenSalt(creator));
        p.launchMarketCap = 2 ether; // low, so the fixed 0.05 ether instant buy nets enough of the
            // token's total supply to fund a couple of genuinely-eligible holders under the fixed
            // 0.25%-of-total-supply floor

        vm.prank(creator);
        (address token, bytes32 poolId) = launcher.launch{value: 0.0005 ether + 0.05 ether}(p);

        uint256 creatorTokens = DuckToken(payable(token)).balanceOf(creator);
        assertGt(creatorTokens, 0, "instant buy should have landed tokens on the creator to distribute");

        // 496 realistically-small holders (each well under the 0.25%-of-total-supply floor -- not
        // literally 1 wei, just genuinely minor positions) plus 4 comfortably-eligible ones splitting
        // the bulk of the distributable supply. The floor is fixed at 0.25% of the token's total
        // supply (2,500,000e18 out of a 1,000,000,000e18 supply here), independent of how much of that
        // supply the creator's own instant buy actually captured -- creatorTokens is a small enough
        // slice of the full launched supply that only a handful of wallets can be funded far enough
        // above the floor to be genuinely eligible; concentrating the real share into a small subset
        // is also the more realistic shape for a real token anyway (many small holders, few large
        // ones).
        uint256 smallCount = 496;
        uint256 eligibleCount = 4;
        uint256 n = smallCount + eligibleCount;
        address[] memory wallets = new address[](n);

        uint256 traderSlice = creatorTokens / 4;
        uint256 distributable = creatorTokens - traderSlice;
        uint256 smallWalletTotal = distributable / 100; // 1% of distributable spread across all small holders
        uint256 perSmallWallet = smallWalletTotal / smallCount;
        uint256 perEligibleWallet = (distributable - smallWalletTotal) / eligibleCount;

        vm.startPrank(creator);
        DuckToken(payable(token)).transfer(trader, traderSlice);
        for (uint256 i; i < n; ++i) {
            wallets[i] = address(uint160(uint256(keccak256(abi.encode("realHolder500", i)))));
            uint256 amount = i < smallCount ? perSmallWallet : perEligibleWallet;
            DuckToken(payable(token)).transfer(wallets[i], amount);
        }
        vm.stopPrank();

        bool tokenIsC0 = token < address(0);
        PoolKey memory key = PoolKey({
            currency0: tokenIsC0 ? token : address(0),
            currency1: tokenIsC0 ? address(0) : token,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });
        vm.prank(trader);
        IERC20Fork(token).approve(address(this), traderSlice);
        vm.roll(block.number + 1); // separate real transaction from the launch's own instantBuy
        _sell(key, token, tokenIsC0, traderSlice / 2, trader);

        assertGt(hook.accruedFees(poolId), 0, "the real sell should have accrued a real hook fee");
        hook.claimFees(poolId);
        assertGt(DuckToken(payable(token)).roundPool(), 0, "5% of the claimed fee should have landed in the reward pool");

        // Past the 12h interval, with nothing having called processBatch() yet -- drive the entire
        // round purely through direct processBatch() calls, exactly like production (manual or
        // DuckKeeper-driven; no transfer anywhere in this loop).
        vm.warp(block.timestamp + 12 hours + 1);

        uint256 batchSize = DuckToken(payable(token)).BATCH_SIZE();
        uint256 expectedMinBatches = (n + batchSize - 1) / batchSize; // ceil(n / batchSize)
        uint256 batchesObserved;
        uint256 totalGasAcrossBatches;

        while (DuckToken(payable(token)).distributing() || batchesObserved == 0) {
            uint256 gasBefore = gasleft();
            DuckToken(payable(token)).processBatch();
            uint256 gasUsed = gasBefore - gasleft();
            totalGasAcrossBatches += gasUsed;
            emit log_named_uint("gas used by processBatch() (one batch)", gasUsed);

            batchesObserved++;
            assertLt(batchesObserved, expectedMinBatches + 3, "round should finish within a small margin of the expected batch count");
        }

        emit log_named_uint("batches required to fully distribute 500 real holders", batchesObserved);
        emit log_named_uint("total gas spent across all processBatch() calls", totalGasAcrossBatches);

        assertFalse(DuckToken(payable(token)).distributing(), "round must fully finish");
        assertGe(batchesObserved, expectedMinBatches,
            "500 real holders must genuinely require multiple batches -- confirms the batching, not a fluke of a small holder count");

        // Spot-check eligibility at scale: a realistically-small holder must never be paid; a
        // comfortably-eligible one (well above the fixed 0.25% floor) must be.
        assertEq(wallets[0].balance, 0, "a small holder well under MIN_HOLDING_BPS must never be paid");
        assertGt(wallets[n - 2].balance, 0, "a comfortably-eligible holder must actually be paid");
    }

    function _readPoolInfo(bytes32 poolId) internal view returns (
        address token, address quoteCurrency, bool tokenIsCurrency0, address poolCreator, uint256 hookFeeBps, uint16 vaultBps
    ) {
        (
            address token_, address quoteCurrency_, bool tokenIsCurrency0_, address creator_,
            , , uint256 hookFeeBps_, , uint16 vaultBps_,
        ) = hook.pools(poolId);
        return (token_, quoteCurrency_, tokenIsCurrency0_, creator_, hookFeeBps_, vaultBps_);
    }

    function _sell(PoolKey memory key, address token, bool tokenIsC0, uint256 amountIn, address trader_) internal {
        _cbExpected = V4_POOL_MANAGER;
        IPoolManagerSwapFork(V4_POOL_MANAGER).unlock(abi.encode(uint8(1), abi.encode(key, token, tokenIsC0, amountIn, trader_)));
        _cbExpected = address(0);
    }

    // Proves beforeRemoveLiquidity actually blocks removal end-to-end: calls the real PoolManager's
    // modifyLiquidity() directly with a negative delta, exactly the way a legitimate LP withdrawal
    // would, and expects the whole unlock() to revert with the hook's LiquidityRemovalDisabled.
    function _attemptRemoveLiquidity(PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) internal {
        _cbExpected = V4_POOL_MANAGER;
        IPoolManagerSwapFork(V4_POOL_MANAGER).unlock(abi.encode(uint8(2), abi.encode(key, tickLower, tickUpper, liquidityDelta)));
        _cbExpected = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == _cbExpected, "unauthorized callback");
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (op == 2) {
            (PoolKey memory key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) =
                abi.decode(payload, (PoolKey, int24, int24, int256));
            IPoolManagerSwapFork(msg.sender).modifyLiquidity(
                key,
                ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)}),
                ""
            );
            return "";
        }

        (PoolKey memory key, address token, bool tokenIsC0, uint256 amountIn, address trader_) =
            abi.decode(payload, (PoolKey, address, bool, uint256, address));

        int256 delta = IPoolManagerSwapFork(msg.sender).swap(
            key,
            SwapParams({
                zeroForOne: tokenIsC0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: tokenIsC0 ? 4295128739 + 1 : 1461446703485210103287273052203988822378723970342 - 1
            }),
            ""
        );

        (bool ok,) = token.call(abi.encodeWithSelector(0x23b872dd, trader_, address(this), amountIn));
        require(ok, "transferFrom failed");
        IPoolManagerSwapFork(msg.sender).sync(token);
        (bool ok2,) = token.call(abi.encodeWithSelector(0xa9059cbb, msg.sender, amountIn));
        require(ok2, "transfer to pool manager failed");
        IPoolManagerSwapFork(msg.sender).settle();

        address quote = tokenIsC0 ? key.currency1 : key.currency0;
        int128 quoteDelta = tokenIsC0 ? int128(delta) : int128(delta >> 128);
        uint256 amountOut = uint256(uint128(quoteDelta));
        IPoolManagerSwapFork(msg.sender).take(quote, trader_, amountOut);

        return "";
    }

    // Needed for the un-pranked hook.claimFees(poolId) calls in this file: the test contract itself
    // is msg.sender there, so it earns the 1% claimer reward as native ETH -- same receive() already
    // present in the sibling DuckProtocol.fork.t.sol / DuckProtocolLending.fork.t.sol / (now)
    // DuckProtocolGovernance.fork.t.sol.
    receive() external payable {}
}

contract MockDirtyDecimalsErc20Fork {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function decimals() external pure returns (uint256) {
        return type(uint256).max;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockErc20Fork {
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
