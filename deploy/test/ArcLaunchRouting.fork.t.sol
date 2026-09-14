// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// StablechainsLaunchRouting on an Arc mainnet (5042) fork. The launch families link a routing library at
// deploy time; on stablechains that's StablechainsLaunchRouting in LaunchRoutingExec's place. This test
// does the same swap on a LaunchRouting harness (etching StablechainsLaunchRouting's code over the linked
// LaunchRoutingExec) and checks Arc's behaviour: native USDC and the USDC ERC-20 at 0x3600... are one
// balance (18 vs 6 decimals), so acquiring USDC with native and disposing USDC for native are unit
// conversions with no swap, and a raw-native quote is refused.
//
//   ARC_RPC_URL=https://rpc.arc-scan.org forge test --match-path test/ArcLaunchRouting.fork.t.sol

import {Test} from "forge-std/Test.sol";
import {LaunchRouting, LaunchRoutingExec} from "duck-lib/LaunchRouting.sol";
import {StablechainsLaunchRouting} from "duck-lib/StablechainsLaunchRouting.sol";

interface IArcUsdc {
    function balanceOf(address) external view returns (uint256);
    function decimals() external view returns (uint8);
}

contract ArcRoutingHarness is LaunchRouting {
    function acquire(address quote, uint256 nativeIn, uint256 minOut, address recipient) external returns (uint256, bool) {
        return _acquireQuoteToken(quote, nativeIn, minOut, recipient);
    }

    function dispose(address quote, uint256 quoteIn, uint256 minNativeOut, address recipient) external returns (uint256, bool) {
        return _disposeQuoteToken(quote, quoteIn, minNativeOut, recipient);
    }

    function requireQuoteSupported(address quote) external pure {
        _requireQuoteSupported(quote);
    }

    receive() external payable {}
}

contract ArcLaunchRoutingForkTest is Test {
    address constant USDC = 0x3600000000000000000000000000000000000000;

    ArcRoutingHarness harness;
    bytes sharedLibraryCode;
    address alice = makeAddr("arc-alice");
    address bob = makeAddr("arc-bob");

    function setUp() public {
        vm.createSelectFork(vm.envOr("ARC_RPC_URL", string("https://rpc.arc-scan.org")));
        assertEq(block.chainid, 5042, "Arc mainnet fork");
        harness = new ArcRoutingHarness();
        sharedLibraryCode = address(LaunchRoutingExec).code;
        // Link StablechainsLaunchRouting where the harness calls LaunchRoutingExec, as an Arc deploy does.
        vm.etch(address(LaunchRoutingExec), address(StablechainsLaunchRouting).code);
    }

    function test_UsdcErc20MirrorsNativeBalance() public {
        assertEq(IArcUsdc(USDC).decimals(), 6);
        vm.deal(alice, 3.25e18 + 777);
        assertEq(IArcUsdc(USDC).balanceOf(alice), 3_250_000, "ERC-20 balance is native / 1e12");
    }

    function test_AcquireKeepsNativeAsUsdcForTheCaller() public {
        vm.deal(address(harness), 1.5e18 + 999);
        (uint256 out, bool ok) = harness.acquire(USDC, 1.5e18 + 999, 1_500_000, address(harness));
        assertTrue(ok);
        assertEq(out, 1_500_000, "1.5 native USDC is 1.5e6 ERC-20 units");
        assertEq(IArcUsdc(USDC).balanceOf(address(harness)), 1_500_000, "no swap: the caller already holds it");
        assertEq(address(harness).balance, 1.5e18 + 999, "native untouched, dust included");
    }

    function test_AcquireForAnotherRecipientForwardsWholeUnits() public {
        vm.deal(address(harness), 2e18 + 5);
        (uint256 out, bool ok) = harness.acquire(USDC, 2e18 + 5, 1, alice);
        assertTrue(ok);
        assertEq(out, 2_000_000);
        assertEq(IArcUsdc(USDC).balanceOf(alice), 2_000_000, "recipient gets the ERC-20 amount");
        assertEq(alice.balance, 2e18, "exactly the whole-unit part moves as native");
        assertEq(address(harness).balance, 5, "sub-1e12 dust stays with the caller");
    }

    function test_AcquireBelowMinOutFailsWithoutMovingFunds() public {
        vm.deal(address(harness), 1e18);
        (uint256 out, bool ok) = harness.acquire(USDC, 1e18, 1_000_001, alice);
        assertFalse(ok);
        assertEq(out, 0);
        assertEq(alice.balance, 0);
    }

    // Skipped in forge: an ERC-20 transfer of Arc's USDC moves native balance through Arc's own execution
    // logic, which forge's local EVM doesn't have (the call runs out of gas there). The same dispose() is
    // checked against the real Arc node instead, with eth_call state overrides (harness code linked to
    // StablechainsLaunchRouting, harness funded): it returns (1.25e18, true).
    function test_DisposePaysNativeThroughAnErc20Transfer() public {
        vm.skip(true);
        vm.deal(address(harness), 4e18);
        (uint256 out, bool ok) = harness.dispose(USDC, 1_250_000, 1.25e18, bob);
        assertTrue(ok);
        assertEq(out, 1.25e18, "reported in native units");
        assertEq(bob.balance, 1.25e18, "recipient receives native");
        assertEq(IArcUsdc(USDC).balanceOf(bob), 1_250_000);
        assertEq(address(harness).balance, 2.75e18, "caller's native went down by the same amount");
    }

    function test_DisposeBelowMinNativeOutFails() public {
        vm.deal(address(harness), 1e18);
        (, bool ok) = harness.dispose(USDC, 500_000, 0.5e18 + 1, bob);
        assertFalse(ok);
        assertEq(bob.balance, 0);
    }

    function test_RawNativeQuoteIsRefusedOnArc() public {
        vm.expectRevert(StablechainsLaunchRouting.NativeQuoteUnsupported.selector);
        harness.requireQuoteSupported(address(0));
        harness.requireQuoteSupported(USDC);
    }

    function test_SharedLibraryAcceptsEveryQuote() public {
        // Put LaunchRoutingExec's own code back: that instance (Robinhood Chain, Ink) never refuses a quote.
        vm.etch(address(LaunchRoutingExec), sharedLibraryCode);
        harness.requireQuoteSupported(address(0));
    }
}
