// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {ArcProtocolForkTest} from "./ArcProtocol.fork.t.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {ARC_USDC} from "duck-lib/ArcChain.sol";

// Access modes on Arc, where the quote is USDC: contributions are counted in whole ERC-20 USDC units (6 decimals), and
// a native-USDC contribution is converted before the cap is checked, so both forms count toward the same cap.
// Inherits the Arc fork suite, so every original test also runs against the modified crowdfund.
contract DuckCrowdfundAccessForkTest is ArcProtocolForkTest {
    address w1 = makeAddr("arc-acc-w1"); // allocation 20 USDC
    address w2 = makeAddr("arc-acc-w2"); // allocation 0 -> the campaign's maxPerWallet
    address w3 = makeAddr("arc-acc-w3"); // allocation 50 USDC
    address stranger = makeAddr("arc-acc-stranger");

    bytes32[3] leaves;
    bytes32 root;
    uint256 nextSalt;
    uint256 constant A1 = 20e6; uint256 constant A2 = 0; uint256 constant A3 = 50e6;

    function _leaf(uint256 id, address a, uint256 alloc) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(id, a, alloc))));
    }
    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
    // Three leaves: root = H(H(l0,l1), l2). Proofs: l0 -> [l1, l2], l1 -> [l0, l2], l2 -> [H(l0,l1)].
    function _tree(uint256 id) internal {
        leaves[0] = _leaf(id, w1, A1); leaves[1] = _leaf(id, w2, A2); leaves[2] = _leaf(id, w3, A3);
        root = _pair(_pair(leaves[0], leaves[1]), leaves[2]);
    }
    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        if (i == 2) { p = new bytes32[](1); p[0] = _pair(leaves[0], leaves[1]); return p; }
        p = new bytes32[](2); p[0] = leaves[i ^ 1]; p[1] = leaves[2];
    }

    function _launch(DuckCrowdfund.AccessParams memory a, uint256 goal) internal returns (uint256 id) {
        bytes32 salt = _mineSalt(d.crowdfund, creator, crowdfund.tokenImpl(), nextSalt);
        nextSalt = uint256(salt) + 1;
        vm.deal(creator, 1e18);
        DuckCrowdfund.LaunchParams memory p = DuckCrowdfund.LaunchParams({
            name: "Arc Raise", symbol: "ARAISE", metaURI: "", dexQuoteAsset: ARC_USDC, goalNativeWei: goal, startTime: 0,
            vanitySalt: salt, hookFeeBps: 300, creatorBps: 10_000, vaultBps: 0, burnBps: 0, supplyTier: 0
        });
        vm.prank(creator);
        (id,) = crowdfund.launchWithAccess{value: 1e18}(p, a);
    }
    function _open(uint256 cap) internal pure returns (DuckCrowdfund.AccessParams memory) {
        return DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: cap, whitelistRoot: bytes32(0), whitelistURI: ""});
    }

    function test_Open_CapCountsNativeAndErc20UsdcTogether() public {
        uint256 id = _launch(_open(60e6), 1_000e6);
        vm.deal(w1, 200e18);
        vm.startPrank(w1);
        crowdfund.contribute{value: 50e18}(id, 0); // 50 USDC as native
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 60e6, 50e6));
        crowdfund.contribute{value: 11e18}(id, 0);
        usdc.approve(d.crowdfund, 100e6);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 60e6, 50e6));
        crowdfund.contribute(id, 11e6); // the same amount as ERC-20 is refused the same way
        crowdfund.contribute(id, 10e6); // exactly the cap
        vm.stopPrank();
        assertEq(crowdfund.contributed(id, w1), 60e6);
        assertEq(crowdfund.remainingAllowance(id, w1, 0), 0);
    }

    function test_Open_BlankCapIsUnlimitedAndOriginalLaunchStaysOpen() public {
        uint256 id = _launch(_open(0), 1_000e6);
        vm.deal(w1, 500e18);
        vm.prank(w1); crowdfund.contribute{value: 400e18}(id, 0);
        assertEq(crowdfund.contributed(id, w1), 400e6);

        (uint256 old,,) = _campaign(100e6, 5_000_000); // the original launch()
        (DuckCrowdfund.AccessMode mode, uint256 cap, bytes32 r) = crowdfund.getCampaignAccess(old);
        assertEq(uint8(mode), uint8(DuckCrowdfund.AccessMode.Open)); assertEq(cap, 0); assertEq(r, bytes32(0));
    }

    function test_Whitelist_ProofsAllocationsAndNativeValueSafety() public {
        uint256 id = crowdfund.campaignCount();
        _tree(id);
        uint256 c = _launch(DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Whitelist, maxPerWallet: 30e6, whitelistRoot: root, whitelistURI: "ipfs://list"}), 1_000e6);
        assertEq(c, id);

        vm.deal(w1, 100e18); vm.deal(w2, 100e18); vm.deal(stranger, 100e18);

        // w1: allocation 20 USDC wins over the campaign's 30
        vm.prank(w1); crowdfund.contributeWhitelisted{value: 15e18}(id, 0, A1, _proof(0));
        vm.prank(w1);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, A1, 15e6));
        crowdfund.contributeWhitelisted{value: 6e18}(id, 0, A1, _proof(0));

        // w2: allocation 0 -> the campaign's 30 USDC
        vm.prank(w2); crowdfund.contributeWhitelisted{value: 30e18}(id, 0, A2, _proof(1));
        vm.prank(w2);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 30e6, 30e6));
        crowdfund.contributeWhitelisted{value: 1e18}(id, 0, A2, _proof(1));

        // a stranger with someone else's valid proof, and w1 with an inflated allocation: no value moves
        uint256 before = stranger.balance;
        vm.prank(stranger);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 5e18}(id, 0, A1, _proof(0));
        assertEq(stranger.balance, before);
        vm.prank(w1);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1e18}(id, 0, 999e6, _proof(0));

        // plain contribute is refused on a whitelist campaign
        vm.prank(w1);
        vm.expectRevert(DuckCrowdfund.WhitelistRequired.selector);
        crowdfund.contribute{value: 1e18}(id, 0);

        assertTrue(crowdfund.isWhitelisted(id, w3, A3, _proof(2)));
        assertFalse(crowdfund.isWhitelisted(id, stranger, A3, _proof(2)));
    }

    // The campaign-wide maximum is a hard ceiling: an allocation can lower a wallet's cap below it but never raise it above.
    function test_Whitelist_SharedMaxIsAHardCeiling() public {
        uint256 id = crowdfund.campaignCount();
        _tree(id);
        _launch(DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Whitelist, maxPerWallet: 30e6, whitelistRoot: root, whitelistURI: "ipfs://list"}), 1_000e6);
        vm.deal(w3, 200e18); vm.deal(w1, 200e18);
        // w3's allocation is 50 USDC, the ceiling is 30
        vm.prank(w3); crowdfund.contributeWhitelisted{value: 30e18}(id, 0, A3, _proof(2));
        vm.prank(w3);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 30e6, 30e6));
        crowdfund.contributeWhitelisted{value: 1e18}(id, 0, A3, _proof(2));
        // w1's allocation (20) is under the ceiling, so it is the cap
        assertEq(crowdfund.remainingAllowance(id, w1, A1), 20e6);
        assertEq(crowdfund.remainingAllowance(id, w2, A2), 30e6);
    }

    function test_Whitelist_RaiseSucceedsAndClaims() public {
        uint256 id = crowdfund.campaignCount();
        _tree(id);
        _launch(DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Whitelist, maxPerWallet: 0, whitelistRoot: root, whitelistURI: "ipfs://list"}), 100e6);
        vm.deal(w3, 100e18); vm.deal(w1, 100e18);
        vm.prank(w3); crowdfund.contributeWhitelisted{value: 50e18}(id, 0, A3, _proof(2));
        vm.prank(w1); crowdfund.contributeWhitelisted{value: 20e18}(id, 0, A1, _proof(0));
        vm.prank(w2); // a wallet with a valid leaf but nothing sent yet, contributing ERC-20 USDC
        vm.deal(w2, 100e18);
        usdc.approve(d.crowdfund, 30e6);
        vm.prank(w2); crowdfund.contributeWhitelisted(id, 30e6, A2, _proof(1));
        vm.warp(block.timestamp + crowdfund.campaignDuration());
        crowdfund.finalize(id);
        (,,,,,, bool finalized, bool succeeded, address token) = crowdfund.getCampaignCore(id);
        assertTrue(finalized && succeeded, "the raise met its goal");
        vm.prank(w3); crowdfund.claim(id);
        assertGt(IArcToken(token).balanceOf(w3), 0);
    }

    function test_Launch_RejectsInconsistentAccessConfig() public {
        vm.deal(creator, 1e18);
        DuckCrowdfund.LaunchParams memory p = DuckCrowdfund.LaunchParams({
            name: "Arc Raise", symbol: "ARAISE", metaURI: "", dexQuoteAsset: ARC_USDC, goalNativeWei: 100e6, startTime: 0,
            vanitySalt: bytes32(0), hookFeeBps: 300, creatorBps: 10_000, vaultBps: 0, burnBps: 0, supplyTier: 0
        });
        vm.prank(creator);
        vm.expectRevert(DuckCrowdfund.InvalidAccessConfig.selector);
        crowdfund.launchWithAccess{value: 1e18}(p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Whitelist, maxPerWallet: 0, whitelistRoot: bytes32(0), whitelistURI: ""}));
        vm.prank(creator);
        vm.expectRevert(DuckCrowdfund.InvalidAccessConfig.selector);
        crowdfund.launchWithAccess{value: 1e18}(p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: 0, whitelistRoot: keccak256("x"), whitelistURI: ""}));
    }
}

interface IArcToken { function balanceOf(address) external view returns (uint256); }
