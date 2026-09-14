// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// The Arc build end to end on an Arc mainnet (5042) fork: DeployDuckProtocolArc exactly as it broadcasts, then
// each launch family quoted in USDC against Arc's real PoolManager and PositionManager -- paying and being
// paid in native USDC and in the ERC-20, which are one balance.
//
// forge's EVM lacks the chain logic behind Arc's USDC ERC-20, so MockArcUsdc stands in at its address,
// keeping Arc's rule that ERC-20 balances are native balances.
//
//   ARC_RPC_URL=https://rpc.arc-scan.org forge test --match-path test/ArcProtocol.fork.t.sol

import {Test} from "forge-std/Test.sol";

import {DeployDuckProtocolArc} from "../script/DeployDuckProtocolArc.s.sol";
import {MockArcUsdc} from "./utils/MockArcUsdc.sol";
import {ARC_USDC, NATIVE_PER_USDC} from "duck-lib/ArcChain.sol";
import {LaunchRouting} from "duck-lib/LaunchRouting.sol";
import {TokenConfig} from "duck-lib/DuckTypes.sol";
import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckLauncher} from "duck-launcher/DuckLauncher.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {DuckGenesisHook} from "duck-shared/DuckGenesisHook.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";

interface IArcLaunchToken {
    function balanceOf(address account) external view returns (uint256);
    function approve(address spender, uint256 amount) external returns (bool);
    function vault() external view returns (address);
    function rewardCurrency() external view returns (address);
}

contract ArcProtocolForkTest is Test {
    address constant POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;

    address owner    = makeAddr("arc-owner");
    address platform = makeAddr("arc-platform");
    address creator  = makeAddr("arc-creator");
    address alice    = makeAddr("arc-alice");
    address bob      = makeAddr("arc-bob");

    DeployDuckProtocolArc.Deployment d;
    DuckBondingCurve curve;
    DuckLauncher launcher;
    DuckCrowdfund crowdfund;
    DuckGenesisHook hook;
    MockArcUsdc usdc = MockArcUsdc(ARC_USDC);

    function setUp() public virtual {
        vm.createSelectFork(vm.envOr("ARC_RPC_URL", string("https://rpc.arc-scan.org")));
        assertEq(block.chainid, 5042, "Arc mainnet fork");
        vm.etch(ARC_USDC, address(new MockArcUsdc()).code);
        vm.allowCheatcodes(ARC_USDC);

        d = new DeployDuckProtocolArc().deployAs(owner, platform);
        curve = DuckBondingCurve(payable(d.curve));
        launcher = DuckLauncher(payable(d.launcher));
        crowdfund = DuckCrowdfund(payable(d.crowdfund));
        hook = DuckGenesisHook(payable(d.hook));
    }

    function test_DeployWiresTheArcBuild() public view {
        assertEq(uint160(d.hook) & 0x3FFF, 0x2ACC, "hook permission bits");
        assertTrue(hook.isLauncher(d.curve) && hook.isLauncher(d.launcher) && hook.isLauncher(d.crowdfund));
        assertEq(hook.owner(), owner);
        assertEq(hook.platformWallet(), platform);
        assertEq(curve.owner(), owner);
        assertEq(launcher.owner(), owner);
        assertEq(crowdfund.owner(), owner);
        assertEq(curve.creationFee(), 1e18, "1 USDC");
        assertEq(launcher.launchFee(), 1e18, "1 USDC");
        assertEq(crowdfund.campaignFee(), 1e18, "1 USDC");
        assertTrue(curve.quoteTokenAllowed(ARC_USDC));
        assertTrue(launcher.quoteTokens(ARC_USDC));
        assertTrue(crowdfund.quoteAssetAllowed(ARC_USDC));
    }

    function test_NativeQuoteIsRefusedByEveryFamily() public {
        vm.deal(creator, 10e18);

        vm.prank(creator);
        vm.expectRevert(LaunchRouting.NativeQuoteUnsupported.selector);
        curve.createToken{value: 1e18}(_curveParams(address(0), bytes32(0)));

        bytes32 salt = _mineSalt(d.launcher, creator, launcher.tokenImpl(), 0);
        vm.prank(creator);
        vm.expectRevert(LaunchRouting.NativeQuoteUnsupported.selector);
        launcher.launch{value: 1e18}(_launchParams(address(0), salt));

        vm.prank(creator);
        vm.expectRevert(LaunchRouting.NativeQuoteUnsupported.selector);
        crowdfund.launch{value: 1e18}("Arc Raise", "ARAISE", "", address(0), 100e6, 0, bytes32(0), 300, 10_000, 0, 0, 0);
    }

    function test_CurveTradesUsdcAsNativeAndErc20ThenMigrates() public {
        bytes32 salt = _mineSalt(d.curve, creator, curve.tokenImpl(), 0);
        vm.deal(creator, 3e18);
        uint256 platformNative = platform.balance;
        vm.prank(creator);
        address token = curve.createToken{value: 3e18}(_curveParams(ARC_USDC, salt));
        assertEq(platform.balance - platformNative, 1e18, "1 USDC creation fee");
        assertEq(creator.balance, 0, "the other 2 USDC went into the early buy");
        assertGt(IArcLaunchToken(token).balanceOf(creator), 0, "early buy filled");

        // Native in: on a USDC curve buyWithNative is a unit conversion, not a swap.
        vm.deal(alice, 100e18);
        vm.prank(alice);
        curve.buyWithNative{value: 100e18}(token, 100e6, 1, block.timestamp);
        uint256 aliceTokens = IArcLaunchToken(token).balanceOf(alice);
        assertGt(aliceTokens, 0);
        assertEq(alice.balance, 0);

        // ERC-20 in: the same USDC, approved and pulled.
        vm.deal(bob, 50e18);
        vm.startPrank(bob);
        usdc.approve(d.curve, 50e6);
        curve.buy(token, 50e6, 1, block.timestamp);
        vm.stopPrank();
        assertEq(bob.balance, 0, "bob paid 50 USDC as the ERC-20");
        assertGt(IArcLaunchToken(token).balanceOf(bob), 0);

        // Native out: sellForNative pays alice in native USDC, in whole USDC units.
        vm.startPrank(alice);
        IArcLaunchToken(token).approve(d.curve, aliceTokens / 2);
        curve.sellForNative(token, aliceTokens / 2, 0, 1, block.timestamp);
        vm.stopPrank();
        assertGt(alice.balance, 0, "paid in native");
        assertEq(alice.balance % NATIVE_PER_USDC, 0);

        // A buy past the target migrates the curve into a USDC pool on DuckGenesisHook, refunding the excess.
        vm.deal(bob, 6_000e18);
        vm.prank(bob);
        curve.buyWithNative{value: 6_000e18}(token, 0, 1, block.timestamp);
        TokenConfig memory tc = curve.getTokenConfig(token);
        assertTrue(tc.migrated, "migrated on the target-crossing buy");
        assertGt(bob.balance, 0, "unused USDC refunded");

        (address poolToken, address quoteCurrency,,,, bool registered,,,,) = hook.pools(tc.poolId);
        assertTrue(registered, "pool registered on the hook");
        assertEq(poolToken, token);
        assertEq(quoteCurrency, ARC_USDC);
        assertEq(IArcLaunchToken(token).rewardCurrency(), ARC_USDC, "holder rewards in USDC");

        DuckVault vault = DuckVault(payable(IArcLaunchToken(token).vault()));
        assertTrue(vault.enabled(), "vault linked at migration");
        assertEq(vault.currency(), ARC_USDC);
        assertEq(vault.currencyDecimals(), 6);
    }

    function test_LauncherInstantBuyWithNativeUsdcAndHookFeesInUsdc() public {
        bytes32 salt = _mineSalt(d.launcher, creator, launcher.tokenImpl(), 0);
        vm.deal(creator, 11e18);
        uint256 platformNative = platform.balance;
        vm.prank(creator);
        (address token, bytes32 poolId) = launcher.launch{value: 11e18}(_launchParams(ARC_USDC, salt));
        assertEq(creator.balance, 0);
        assertEq(platform.balance - platformNative, 1e18, "1 USDC launch fee");
        assertGt(IArcLaunchToken(token).balanceOf(creator), 0, "10 native USDC bought in at launch");

        uint256 accrued = hook.accruedFees(poolId);
        assertGt(accrued, 0, "hook fee taken in USDC");

        uint256 platformBefore = usdc.balanceOf(platform);
        uint256 creatorBefore = usdc.balanceOf(creator);
        vm.prank(alice);
        hook.claimFees(poolId);
        assertEq(hook.accruedFees(poolId), 0);
        assertGt(usdc.balanceOf(platform), platformBefore, "platform cut paid in USDC");
        assertGt(usdc.balanceOf(alice), 0, "claimer reward paid in USDC");
        assertGt(usdc.balanceOf(creator), creatorBefore, "creator share paid in USDC");
        assertGt(usdc.balanceOf(token), 0, "holder reward deposited in USDC");
    }

    function test_CrowdfundTakesNativeAndErc20UsdcAndRefundsNative() public {
        (uint256 id, address token, bytes32 salt) = _campaign(100e6, 0);

        vm.deal(alice, 61e18);
        vm.prank(alice);
        vm.expectRevert(DuckCrowdfund.InexactNativeAmount.selector);
        crowdfund.contribute{value: 1e18 + 1}(id, 0);

        vm.prank(alice);
        crowdfund.contribute{value: 60e18}(id, 0);
        vm.deal(bob, 50e18);
        vm.startPrank(bob);
        usdc.approve(d.crowdfund, 50e6);
        crowdfund.contribute(id, 50e6);
        vm.stopPrank();
        assertEq(crowdfund.contributed(id, alice), 60e6, "native counted in USDC units");
        assertEq(crowdfund.contributed(id, bob), 50e6);

        vm.warp(block.timestamp + crowdfund.campaignDuration());
        crowdfund.finalize(id);
        (,,,,,, bool finalized, bool succeeded,) = crowdfund.getCampaignCore(id);
        assertTrue(finalized && succeeded, "raise seeded its USDC pool");
        vm.prank(alice);
        crowdfund.claim(id);
        assertGt(IArcLaunchToken(token).balanceOf(alice), 0);

        // A raise that misses its goal refunds a native contribution as native.
        (uint256 id2,,) = _campaign(1_000e6, uint256(salt) + 1);
        vm.deal(alice, 10e18);
        vm.prank(alice);
        crowdfund.contribute{value: 10e18}(id2, 0);
        assertEq(alice.balance, 0);
        vm.warp(block.timestamp + crowdfund.campaignDuration());
        crowdfund.finalize(id2);
        vm.prank(alice);
        crowdfund.claimRefund(id2);
        assertEq(alice.balance, 10e18, "refunded in full");
    }

    // ---------------------------------------------------------------- helpers

    function _curveParams(address quote, bytes32 salt) internal pure returns (DuckBondingCurve.BaseParams memory p) {
        p.name = "Arc Duck";
        p.symbol = "ADUCK";
        p.supplyTier = 0;
        p.curveBps = 8_000;
        p.liquidityBps = 2_000;
        p.quoteToken = quote;
        p.startVirtualQuote = 1_000e6;
        p.migrationTargetQuote = 5_000e6;
        p.hookFeeBps = 300;
        p.creatorBps = 7_000;
        p.vaultBps = 3_000;
        p.salt = salt;
    }

    function _launchParams(address quote, bytes32 salt) internal pure returns (DuckLauncher.LaunchParams memory p) {
        p.name = "Arc Launch";
        p.symbol = "ALAUNCH";
        p.positionManager = POSITION_MANAGER;
        p.quoteToken = quote;
        p.vanitySalt = salt;
        p.supplyTier = 0;
        p.launchMarketCap = 10_000e6;
        p.minTokensOut = 1;
        p.hookFeeBps = 300;
        p.creatorBps = 10_000;
        p.revertOnInstantBuyFailure = true;
    }

    function _campaign(uint256 goal, uint256 saltFrom) internal returns (uint256 id, address token, bytes32 salt) {
        salt = _mineSalt(d.crowdfund, creator, crowdfund.tokenImpl(), saltFrom);
        vm.deal(creator, 1e18);
        vm.prank(creator);
        (id, token) = crowdfund.launch{value: 1e18}("Arc Raise", "ARAISE", "", ARC_USDC, goal, 0, salt, 300, 10_000, 0, 0, 0);
    }

    // Every family clones its token template with CREATE2 under keccak256(abi.encode(sender, userSalt)) and
    // requires the 0x8888 vanity suffix. Hashed in one reused memory region: allocating per attempt runs a
    // long search out of memory.
    function _mineSalt(address family, address sender, address impl, uint256 from) internal pure returns (bytes32 userSalt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3"
        ));
        bool found;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            for { let i := from } lt(i, add(from, 2000000)) { i := add(i, 1) } {
                mstore(ptr, sender)
                mstore(add(ptr, 0x20), i)
                let salt := keccak256(ptr, 0x40)
                mstore8(add(ptr, 0x40), 0xff)
                mstore(add(ptr, 0x41), shl(96, family))
                mstore(add(ptr, 0x55), salt)
                mstore(add(ptr, 0x75), initCodeHash)
                if eq(and(keccak256(add(ptr, 0x40), 0x55), 0xffff), 0x8888) {
                    userSalt := i
                    found := 1
                    break
                }
            }
        }
        require(found, "token salt not found");
    }
}
