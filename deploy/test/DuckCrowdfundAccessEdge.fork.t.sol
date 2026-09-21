// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {DuckCrowdfundAccessForkTest} from "./DuckCrowdfundAccess.fork.t.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {IERC20Fork3} from "./DuckProtocolCrowdfund.fork.t.sol";

// Edge cases and attacks for the crowdfund access modes. Kept apart from the functional suite it inherits from.
//
//  - a golden vector built by OpenZeppelin's own JavaScript Merkle library (what the frontend will use) verifies on-chain
//  - generated trees of many shapes (1..17 leaves, odd sizes, uneven proof depths): every member gets in, others don't
//  - a reentrant quote token / attacker contract cannot use reentrancy to get past a cap
//  - tampered proofs, mode confusion, timing, enum abuse
//  - fuzz tests checked against an independent oracle
contract DuckCrowdfundAccessEdgeForkTest is DuckCrowdfundAccessForkTest {
    bytes32[] internal saltPool;
    uint256 internal saltIdx;

    function setUp() public override {
        super.setUp();
        // Mining a vanity salt is by far the slowest step of a launch, so mine a pool once. Every test and fuzz run
        // starts from this state and draws salts from the start of the pool again.
        for (uint256 i; i < 24; ++i) saltPool.push(_mineTokenSalt(creator));
    }

    function _launchAccess(DuckCrowdfund.AccessParams memory a, uint256 goal, address quote, uint256 startTime) internal returns (uint256 id) {
        DuckCrowdfund.LaunchParams memory p = DuckCrowdfund.LaunchParams({
            name: "Edge Raise", symbol: "EDGE", metaURI: "", dexQuoteAsset: quote, goalNativeWei: goal, startTime: startTime,
            vanitySalt: saltPool[saltIdx++], hookFeeBps: 0, creatorBps: 10_000, vaultBps: 0, burnBps: 0, supplyTier: 0
        });
        vm.prank(creator);
        (id,) = crowdfund.launchWithAccess{value: 0.0005 ether}(p, a);
    }
    function _wl(bytes32 r, uint256 maxPerWallet) internal pure returns (DuckCrowdfund.AccessParams memory) {
        return DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Whitelist, maxPerWallet: maxPerWallet, whitelistRoot: r, whitelistURI: "ipfs://x"});
    }
    function _op(uint256 cap) internal pure returns (DuckCrowdfund.AccessParams memory) {
        return DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: cap, whitelistRoot: bytes32(0), whitelistURI: ""});
    }

    // ================================================================================================ golden vector

    function _v0() internal pure returns (address who, uint256 alloc, bytes32[] memory proof) {
        who = 0x1111111111111111111111111111111111111111; alloc = 2000000000000000000;
        proof = new bytes32[](2);
        proof[0] = bytes32(hex"9694aad26366c1a13937d53fdcb3c150ebe7e3e53fa12303e176e187ae22ebe6"); proof[1] = bytes32(hex"f63859d69ba74fd67145b4af8b50f2e4b7dac93778440b45d8204b4a767dd0cc");
    }
    function _v1() internal pure returns (address who, uint256 alloc, bytes32[] memory proof) {
        who = 0x2222222222222222222222222222222222222222; alloc = 0;
        proof = new bytes32[](3);
        proof[0] = bytes32(hex"0b1d90b0e7d29c2588d86c1e1bb8a158475b96163427fae174b972cffb49e8b2"); proof[1] = bytes32(hex"ff483dc090f279fd8cb50b2866181b0b5880159bbc5818a2b945fe4ac5ff9b5a"); proof[2] = bytes32(hex"7ba02cf4b55c42f8fd672e5a65b3efd7caf4ac8714a487184618702638513e3d");
    }
    function _v2() internal pure returns (address who, uint256 alloc, bytes32[] memory proof) {
        who = 0x3333333333333333333333333333333333333333; alloc = 5000000000000000000;
        proof = new bytes32[](2);
        proof[0] = bytes32(hex"3dc412b05bc780519fa9fef313bfb123ad198b5f9ca0edd3f61d7ddb104be2c2"); proof[1] = bytes32(hex"f63859d69ba74fd67145b4af8b50f2e4b7dac93778440b45d8204b4a767dd0cc");
    }
    function _v3() internal pure returns (address who, uint256 alloc, bytes32[] memory proof) {
        who = 0x4444444444444444444444444444444444444444; alloc = 1000000000000000000;
        proof = new bytes32[](2);
        proof[0] = bytes32(hex"57cb6d5c5f3673560078a5c756817663764f42dee17eeb9732f639c3153d8076"); proof[1] = bytes32(hex"7ba02cf4b55c42f8fd672e5a65b3efd7caf4ac8714a487184618702638513e3d");
    }
    function _v4() internal pure returns (address who, uint256 alloc, bytes32[] memory proof) {
        who = 0x5555555555555555555555555555555555555555; alloc = 300000000000000000;
        proof = new bytes32[](3);
        proof[0] = bytes32(hex"0d02b43834e4ef903a8525caf00ef0d8cc8867a465e14e1533f7c53aa730641b"); proof[1] = bytes32(hex"ff483dc090f279fd8cb50b2866181b0b5880159bbc5818a2b945fe4ac5ff9b5a"); proof[2] = bytes32(hex"7ba02cf4b55c42f8fd672e5a65b3efd7caf4ac8714a487184618702638513e3d");
    }

    bytes32 constant GOLDEN_ROOT   = bytes32(hex"c411cf60ff907cde4774cdd0333b5659177f17c1c6d7d547dafa0e7c55c79279");
    bytes32 constant SINGLE_ROOT   = bytes32(hex"3dc412b05bc780519fa9fef313bfb123ad198b5f9ca0edd3f61d7ddb104be2c2");

    function test_GoldenVector_EveryMemberOfAJsBuiltTreeVerifiesAndContributes() public {
        uint256 id = _launchAccess(_wl(GOLDEN_ROOT, 0), 100 ether, address(0), 0);
        assertEq(id, 0, "the vector was built for campaign id 0");
        address w; uint256 alloc; bytes32[] memory proof;
        for (uint256 i; i < 5; ++i) {
            if (i == 0) (w, alloc, proof) = _v0();
            else if (i == 1) (w, alloc, proof) = _v1();
            else if (i == 2) (w, alloc, proof) = _v2();
            else if (i == 3) (w, alloc, proof) = _v3();
            else (w, alloc, proof) = _v4();
            assertTrue(crowdfund.isWhitelisted(id, w, alloc, proof), "the view accepts the JS proof");
            vm.deal(w, 10 ether);
            vm.prank(w);
            crowdfund.contributeWhitelisted{value: alloc == 0 ? 0.1 ether : alloc}(id, 0, alloc, proof);
            assertEq(crowdfund.contributed(id, w), alloc == 0 ? 0.1 ether : alloc);
        }
    }

    function test_GoldenVector_ProofOfOneLeafDoesNotWorkForAnother() public {
        uint256 id = _launchAccess(_wl(GOLDEN_ROOT, 0), 100 ether, address(0), 0);
        (address w1,, bytes32[] memory p1) = _v0();
        (address w3, uint256 a3,) = _v2();
        vm.deal(w3, 10 ether);
        vm.prank(w3);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, a3, p1); // wallet 3 with wallet 1's proof
        assertFalse(crowdfund.isWhitelisted(id, w1, 999 ether, p1));
    }

    function test_SingleLeafTree_EmptyProofIsValid_AndOnlyForThatLeaf() public {
        uint256 id = _launchAccess(_wl(SINGLE_ROOT, 0), 100 ether, address(0), 0); // built for wallet 0x1111.. alloc 2 ETH, id 0
        (address w, uint256 alloc,) = _v0();
        vm.deal(w, 10 ether);
        vm.prank(w); crowdfund.contributeWhitelisted{value: 2 ether}(id, 0, alloc, new bytes32[](0));
        vm.deal(stranger, 10 ether);
        vm.prank(stranger);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, alloc, new bytes32[](0));
        vm.prank(w);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, 3 ether, new bytes32[](0)); // right wallet, wrong allocation
    }

    // ================================================================================================ generated trees

    // Standard commutative Merkle tree over `leaves`, an odd node at the end of a level is promoted unchanged.
    function _buildTree(bytes32[] memory leaves) internal pure returns (bytes32 root, bytes32[][] memory proofs) {
        uint256 n = leaves.length;
        proofs = new bytes32[][](n);
        uint256[] memory pos = new uint256[](n);
        uint256[] memory depth = new uint256[](n);
        bytes32[][] memory tmp = new bytes32[][](n);
        for (uint256 i; i < n; ++i) { pos[i] = i; tmp[i] = new bytes32[](32); }
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            uint256 len = level.length;
            for (uint256 i; i < n; ++i) {
                uint256 sib = pos[i] ^ 1;
                if (sib < len) tmp[i][depth[i]++] = level[sib];
                pos[i] /= 2;
            }
            bytes32[] memory next = new bytes32[]((len + 1) / 2);
            for (uint256 j; j < len / 2; ++j) next[j] = _pair(level[2 * j], level[2 * j + 1]);
            if (len % 2 == 1) next[len / 2] = level[len - 1];
            level = next;
        }
        root = level[0];
        for (uint256 i; i < n; ++i) {
            proofs[i] = new bytes32[](depth[i]);
            for (uint256 k; k < depth[i]; ++k) proofs[i][k] = tmp[i][k];
        }
    }

    function _member(uint256 i) internal pure returns (address) { return address(uint160(0xA000 + i)); }
    function _alloc(uint256 i) internal pure returns (uint256) { return i % 3 == 0 ? 0 : (i % 3) * 1 ether; }

    function test_GeneratedTrees_AllSizes_EveryMemberVerifies_NonMembersDoNot() public {
        uint8[10] memory sizes = [1, 2, 3, 4, 5, 7, 8, 9, 16, 17];
        for (uint256 s; s < sizes.length; ++s) {
            uint256 n = sizes[s];
            uint256 id = crowdfund.campaignCount();
            bytes32[] memory leaves = new bytes32[](n);
            for (uint256 i; i < n; ++i) leaves[i] = _leaf(id, _member(i), _alloc(i));
            (bytes32 root_, bytes32[][] memory proofs) = _buildTree(leaves);
            _launchAccess(_wl(root_, 0), 1_000 ether, address(0), 0);
            for (uint256 i; i < n; ++i) {
                assertTrue(crowdfund.isWhitelisted(id, _member(i), _alloc(i), proofs[i]), "member verifies");
                // the same proof never verifies a different allocation or a different wallet
                assertFalse(crowdfund.isWhitelisted(id, _member(i), _alloc(i) + 1, proofs[i]));
                assertFalse(crowdfund.isWhitelisted(id, address(uint160(0xB000 + i)), _alloc(i), proofs[i]));
            }
            // and a member really can contribute (first and last leaf)
            address first = _member(0); address last = _member(n - 1);
            vm.deal(first, 5 ether); vm.deal(last, 5 ether);
            vm.prank(first); crowdfund.contributeWhitelisted{value: 0.1 ether}(id, 0, _alloc(0), proofs[0]);
            vm.prank(last); crowdfund.contributeWhitelisted{value: 0.1 ether}(id, 0, _alloc(n - 1), proofs[n - 1]);
        }
    }

    // ================================================================================================ tampering

    function test_TamperedProofs_AllRevert() public {
        uint256 id = crowdfund.campaignCount();
        bytes32[] memory leaves = new bytes32[](8);
        for (uint256 i; i < 8; ++i) leaves[i] = _leaf(id, _member(i), _alloc(i));
        (bytes32 root_, bytes32[][] memory proofs) = _buildTree(leaves);
        _launchAccess(_wl(root_, 0), 100 ether, address(0), 0);
        address w = _member(3); vm.deal(w, 10 ether);
        bytes32[] memory good = proofs[3];
        assertEq(good.length, 3);

        // flip one bit in each proof element
        for (uint256 k; k < good.length; ++k) {
            bytes32[] memory bad = new bytes32[](good.length);
            for (uint256 j; j < good.length; ++j) bad[j] = good[j];
            bad[k] = bytes32(uint256(good[k]) ^ 1);
            vm.prank(w); vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
            crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, _alloc(3), bad);
        }
        // truncated, extended, reordered proofs
        bytes32[] memory shorter = new bytes32[](2); shorter[0] = good[0]; shorter[1] = good[1];
        vm.prank(w); vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, _alloc(3), shorter);
        bytes32[] memory longer = new bytes32[](4); for (uint256 j; j < 3; ++j) longer[j] = good[j]; longer[3] = keccak256("extra");
        vm.prank(w); vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, _alloc(3), longer);
        bytes32[] memory swapped = new bytes32[](3); swapped[0] = good[1]; swapped[1] = good[0]; swapped[2] = good[2];
        vm.prank(w); vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, _alloc(3), swapped);
        // sanity: the untouched proof still works
        vm.prank(w); crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, _alloc(3), good);
    }

    // An interior node of the tree presented as if it were a leaf: the double hash makes this impossible.
    function test_InteriorNodeCannotBePassedOffAsALeaf() public {
        uint256 id = crowdfund.campaignCount();
        bytes32[] memory leaves = new bytes32[](2);
        leaves[0] = _leaf(id, _member(0), 1 ether); leaves[1] = _leaf(id, _member(1), 1 ether);
        (bytes32 root_,) = _buildTree(leaves);
        _launchAccess(_wl(root_, 0), 100 ether, address(0), 0);
        // root_ is an interior node (the parent of two leaves). Try to use its two children as a 'proof' that some
        // wallet's leaf hashes to the root: the leaf must be double-hashed, so no (wallet, allocation) reproduces it.
        bytes32[] memory p = new bytes32[](1); p[0] = leaves[1];
        address attacker = makeAddr("interior-attacker"); vm.deal(attacker, 10 ether);
        vm.prank(attacker); vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, 1 ether, p);
    }

    // ================================================================================================ mode confusion / inputs

    function test_ModeConfusion_AllCombinations() public {
        uint256 openId = _launchAccess(_op(0), 10 ether, address(0), 0);
        bytes32 r = keccak256("r");
        uint256 wlId = _launchAccess(_wl(r, 0), 10 ether, address(0), 0);
        bytes32[] memory none = new bytes32[](0);
        vm.deal(w1, 10 ether);
        vm.startPrank(w1);
        vm.expectRevert(DuckCrowdfund.NotWhitelistCampaign.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(openId, 0, 0, none);
        vm.expectRevert(DuckCrowdfund.WhitelistRequired.selector);
        crowdfund.contribute{value: 1 ether}(wlId, 0);
        vm.expectRevert(DuckCrowdfund.CampaignNotFound.selector);
        crowdfund.contribute{value: 1 ether}(77, 0);
        vm.expectRevert(DuckCrowdfund.CampaignNotFound.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(77, 0, 0, none);
        vm.stopPrank();
        assertFalse(crowdfund.isWhitelisted(openId, w1, 0, none), "an open campaign whitelists nobody");
        assertFalse(crowdfund.isWhitelisted(77, w1, 0, none));
        (DuckCrowdfund.AccessMode m, uint256 c, bytes32 rr) = crowdfund.getCampaignAccess(77);
        assertEq(uint8(m), 0); assertEq(c, 0); assertEq(rr, bytes32(0));
    }

    function test_InvalidEnumValueIsRejectedByTheAbiDecoder() public {
        DuckCrowdfund.LaunchParams memory p = DuckCrowdfund.LaunchParams({
            name: "Edge", symbol: "EDGE", metaURI: "", dexQuoteAsset: address(0), goalNativeWei: 1 ether, startTime: 0,
            vanitySalt: saltPool[saltIdx++], hookFeeBps: 0, creatorBps: 10_000, vaultBps: 0, burnBps: 0, supplyTier: 0
        });
        // hand-encode AccessParams with mode = 2 (no such mode)
        bytes memory data = abi.encodeWithSelector(
            crowdfund.launchWithAccess.selector, p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: 0, whitelistRoot: bytes32(0), whitelistURI: ""})
        );
        // the AccessParams struct is the second head slot's target; its first word is the mode. Find and corrupt it.
        uint256 offsetToA;
        assembly { offsetToA := mload(add(data, add(0x20, 0x24))) } // head slot 1 (after the 4-byte selector)
        uint256 modePos = 4 + offsetToA; // start of the struct, relative to the start of the arguments
        assembly { mstore(add(add(data, 0x20), modePos), 2) }
        vm.prank(creator);
        (bool ok,) = address(crowdfund).call{value: 0.0005 ether}(data);
        assertFalse(ok, "mode 2 must not decode");
        assertEq(crowdfund.campaignCount(), 0);
    }

    function test_ValueAndAmountValidationHappenBeforeAnyCapLogic() public {
        uint256 id = _launchAccess(_op(1 ether), 10 ether, address(0), 0);
        vm.startPrank(w1);
        vm.expectRevert(DuckCrowdfund.ZeroAmount.selector);
        crowdfund.contribute{value: 0}(id, 0);
        vm.stopPrank();
    }

    function test_TimingRulesStillApplyToWhitelistedWallets() public {
        uint256 id = crowdfund.campaignCount();
        bytes32[] memory leaves = new bytes32[](1); leaves[0] = _leaf(id, w1, 1 ether);
        (bytes32 r,) = _buildTree(leaves);
        _launchAccess(_wl(r, 0), 10 ether, address(0), block.timestamp + 1 hours);
        bytes32[] memory none = new bytes32[](0);
        vm.deal(w1, 10 ether);
        vm.prank(w1); vm.expectRevert(DuckCrowdfund.NotLiveYet.selector);
        crowdfund.contributeWhitelisted{value: 0.5 ether}(id, 0, 1 ether, none);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(w1); crowdfund.contributeWhitelisted{value: 0.5 ether}(id, 0, 1 ether, none);
        vm.warp(block.timestamp + 2 hours + 1);
        vm.prank(w1); vm.expectRevert(DuckCrowdfund.DeadlinePassed.selector);
        crowdfund.contributeWhitelisted{value: 0.1 ether}(id, 0, 1 ether, none);
    }

    // ================================================================================================ cap edge cases

    function test_CapOfOneWei_AndExactBoundaries() public {
        uint256 id = _launchAccess(_op(1), 10 ether, address(0), 0);
        vm.deal(w1, 1 ether);
        vm.startPrank(w1);
        crowdfund.contribute{value: 1}(id, 0);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 1, 1));
        crowdfund.contribute{value: 1}(id, 0);
        vm.stopPrank();
        assertEq(crowdfund.remainingAllowance(id, w1, 0), 0);
    }

    function test_SharedMaxIsACeiling_EvenWithSeveralLeavesForOneWallet() public {
        uint256 id = crowdfund.campaignCount();
        // w1 has three leaves: 5 ETH, 1 ETH and 0 (no allocation). The campaign ceiling is 2 ETH.
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = _leaf(id, w1, 5 ether); leaves[1] = _leaf(id, w1, 1 ether); leaves[2] = _leaf(id, w1, 0);
        (bytes32 r, bytes32[][] memory pr) = _buildTree(leaves);
        _launchAccess(_wl(r, 2 ether), 100 ether, address(0), 0);
        vm.deal(w1, 100 ether);
        vm.startPrank(w1);
        // the 5 ETH allocation is cut down to the 2 ETH ceiling
        crowdfund.contributeWhitelisted{value: 2 ether}(id, 0, 5 ether, pr[0]);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 2 ether, 2 ether));
        crowdfund.contributeWhitelisted{value: 1 wei}(id, 0, 5 ether, pr[0]);
        // the smaller leaf cannot be used to get around it, and the no-allocation leaf is capped at the ceiling too
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 1 ether, 2 ether));
        crowdfund.contributeWhitelisted{value: 1 wei}(id, 0, 1 ether, pr[1]);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 2 ether, 2 ether));
        crowdfund.contributeWhitelisted{value: 1 wei}(id, 0, 0, pr[2]);
        vm.stopPrank();
        assertEq(crowdfund.contributed(id, w1), 2 ether);
    }

    function test_AllocationBelowTheCeilingIsTheCap_AndABlankCeilingLeavesAllocationsAlone() public {
        // ceiling 4 ETH, allocation 1 ETH -> cap 1 ETH
        uint256 id = crowdfund.campaignCount();
        bytes32[] memory leaves = new bytes32[](1); leaves[0] = _leaf(id, w1, 1 ether);
        (bytes32 r,) = _buildTree(leaves);
        _launchAccess(_wl(r, 4 ether), 100 ether, address(0), 0);
        vm.deal(w1, 10 ether);
        vm.startPrank(w1);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 1 ether, 0));
        crowdfund.contributeWhitelisted{value: 1 ether + 1}(id, 0, 1 ether, new bytes32[](0));
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, 1 ether, new bytes32[](0));
        vm.stopPrank();
        // blank ceiling, allocation 6 ETH -> cap 6 ETH
        uint256 id2 = crowdfund.campaignCount();
        bytes32[] memory l2 = new bytes32[](1); l2[0] = _leaf(id2, w2, 6 ether);
        (bytes32 r2,) = _buildTree(l2);
        _launchAccess(_wl(r2, 0), 100 ether, address(0), 0);
        vm.deal(w2, 10 ether);
        vm.prank(w2); crowdfund.contributeWhitelisted{value: 6 ether}(id2, 0, 6 ether, new bytes32[](0));
        assertEq(crowdfund.contributed(id2, w2), 6 ether);
    }

    function test_DuplicateLeavesInTheListAreHarmless() public {
        uint256 id = crowdfund.campaignCount();
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = _leaf(id, w1, 1 ether); leaves[1] = _leaf(id, w1, 1 ether); leaves[2] = _leaf(id, w2, 1 ether);
        (bytes32 r, bytes32[][] memory pr) = _buildTree(leaves);
        _launchAccess(_wl(r, 0), 100 ether, address(0), 0);
        vm.deal(w1, 10 ether);
        vm.startPrank(w1);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, 1 ether, pr[0]);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 1 ether, 1 ether));
        crowdfund.contributeWhitelisted{value: 1 wei}(id, 0, 1 ether, pr[1]); // the duplicate does not double the allowance
        vm.stopPrank();
    }

    // ================================================================================================ ERC-20 paths

    function test_Erc20WhitelistCampaign_NativeValueIsRefused_AndPlainContributeRevertsBeforeAnyTransfer() public {
        vm.prank(owner); crowdfund.setQuoteAssetAllowed(USDG, true);
        uint256 id = crowdfund.campaignCount();
        bytes32[] memory leaves = new bytes32[](1); leaves[0] = _leaf(id, w1, 500e6);
        (bytes32 r,) = _buildTree(leaves);
        _launchAccess(_wl(r, 0), 50_000e6, USDG, 0);
        _giveUsdg(w1, 1_000e6);
        vm.deal(w1, 1 ether);
        vm.startPrank(w1);
        IERC20Fork3(USDG).approve(address(crowdfund), 1_000e6);
        bytes32[] memory none = new bytes32[](0);
        vm.expectRevert(DuckCrowdfund.NativeNotAccepted.selector);
        crowdfund.contributeWhitelisted{value: 1}(id, 500e6, 500e6, none);
        uint256 before = IERC20Fork3(USDG).balanceOf(w1);
        vm.expectRevert(DuckCrowdfund.WhitelistRequired.selector);
        crowdfund.contribute(id, 100e6);
        assertEq(IERC20Fork3(USDG).balanceOf(w1), before, "nothing was pulled");
        crowdfund.contributeWhitelisted(id, 500e6, 500e6, none);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 500e6, 500e6));
        crowdfund.contributeWhitelisted(id, 1, 500e6, none);
        vm.stopPrank();
    }

    // ================================================================================================ reentrancy attack

    function test_ReentrantQuoteToken_CannotUseReentrancyToPassTheCap() public {
        MaliciousQuote token = new MaliciousQuote();
        vm.prank(owner); crowdfund.setQuoteAssetAllowed(address(token), true);
        uint256 id = _launchAccess(_op(100), 10_000, address(token), 0);

        ReentrantAttacker atk = new ReentrantAttacker(crowdfund, id, 100);
        token.setHook(address(atk));
        atk.attack(); // contributes exactly its cap; inside the token's transferFrom it tries again before the first credit lands

        assertEq(crowdfund.contributed(id, address(atk)), 100, "the cap held");
        assertEq(atk.reenterAttempts(), 1, "the attacker did try to re-enter");
        assertEq(atk.reenterSucceeded(), 0, "the reentrant call was rejected");
        (,,,,, uint256 raised,,,) = crowdfund.getCampaignCore(id);
        assertEq(raised, 100, "the total is one contribution, not two");
    }

    // Informational: what the access checks cost a contributor, against the original open, uncapped path.
    function test_GasReport_ContributeBeforeAndAfterTheAccessChecks() public {
        uint256 legacyId;
        vm.prank(creator);
        (legacyId,) = crowdfund.launch{value: 0.0005 ether}("Duck Raise", "DRAISE", "", address(0), 10 ether, 0, saltPool[saltIdx++], 0, 9000, 1000, 0, 0);
        uint256 cappedId = _launchAccess(_op(5 ether), 10 ether, address(0), 0);
        uint256 wlId = crowdfund.campaignCount();
        bytes32[] memory leaves = new bytes32[](8);
        for (uint256 i; i < 8; ++i) leaves[i] = _leaf(wlId, _member(i), 1 ether);
        (bytes32 r, bytes32[][] memory pr) = _buildTree(leaves);
        _launchAccess(_wl(r, 0), 10 ether, address(0), 0);
        address a = _member(0); vm.deal(a, 10 ether); vm.deal(w1, 10 ether);

        vm.prank(w1); uint256 g0 = gasleft(); crowdfund.contribute{value: 0.1 ether}(legacyId, 0); uint256 open = g0 - gasleft();
        vm.prank(w2); vm.deal(w2, 1 ether); g0 = gasleft(); crowdfund.contribute{value: 0.1 ether}(cappedId, 0); uint256 capped = g0 - gasleft();
        vm.prank(a); g0 = gasleft(); crowdfund.contributeWhitelisted{value: 0.1 ether}(wlId, 0, 1 ether, pr[0]); uint256 wl = g0 - gasleft();
        emit log_named_uint("contribute, open campaign launched with launch()", open);
        emit log_named_uint("contribute, open campaign with a cap", capped);
        emit log_named_uint("contributeWhitelisted, 8-wallet list (proof depth 3)", wl);
    }

    // ================================================================================================ fuzz

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_OpenCap_NeverExceeded_AndTotalsAddUp(uint96 capSeed, uint96[6] memory amountSeeds, uint8 who) public {
        uint256 cap = bound(uint256(capSeed), 1, 5 ether);
        uint256 id = _launchAccess(_op(cap), 1_000 ether, address(0), 0);
        address[3] memory wallets = [w1, w2, w3];
        uint256[3] memory expected;
        uint256 total;
        for (uint256 i; i < 6; ++i) {
            address w = wallets[(uint256(who) + i) % 3];
            uint256 amt = bound(uint256(amountSeeds[i]), 1, 3 ether);
            vm.deal(w, amt);
            vm.prank(w);
            if (expected[(uint256(who) + i) % 3] + amt > cap) {
                vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, cap, expected[(uint256(who) + i) % 3]));
                crowdfund.contribute{value: amt}(id, 0);
            } else {
                crowdfund.contribute{value: amt}(id, 0);
                expected[(uint256(who) + i) % 3] += amt;
                total += amt;
            }
        }
        for (uint256 k; k < 3; ++k) {
            assertEq(crowdfund.contributed(id, wallets[k]), expected[k]);
            assertLe(crowdfund.contributed(id, wallets[k]), cap);
        }
        (,,,,, uint256 raised,,,) = crowdfund.getCampaignCore(id);
        assertEq(raised, total, "totalRaised is exactly the sum of what was accepted");
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_WhitelistEffectiveCap_MatchesTheSpec(uint96 allocSeed, uint96 maxSeed, uint96 amtSeed) public {
        uint256 alloc = uint256(allocSeed) % 4 ether;            // 0 allowed
        uint256 maxCap = uint256(maxSeed) % 4 ether;             // 0 allowed
        uint256 amt = bound(uint256(amtSeed), 1, 6 ether);
        uint256 id = crowdfund.campaignCount();
        bytes32[] memory leaves = new bytes32[](2); leaves[0] = _leaf(id, w1, alloc); leaves[1] = _leaf(id, w2, 7 ether);
        (bytes32 r, bytes32[][] memory pr) = _buildTree(leaves);
        _launchAccess(_wl(r, maxCap), 1_000 ether, address(0), 0);
        // independent statement of the rule: the campaign max is a hard ceiling; an allocation can only lower it; zero means unset
        uint256 cap = alloc == 0 ? maxCap : (maxCap == 0 ? alloc : (alloc < maxCap ? alloc : maxCap));
        vm.deal(w1, amt);
        vm.prank(w1);
        if (cap != 0 && amt > cap) {
            vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, cap, 0));
            crowdfund.contributeWhitelisted{value: amt}(id, 0, alloc, pr[0]);
            assertEq(crowdfund.contributed(id, w1), 0);
        } else {
            crowdfund.contributeWhitelisted{value: amt}(id, 0, alloc, pr[0]);
            assertEq(crowdfund.contributed(id, w1), amt);
        }
        uint256 rem = crowdfund.remainingAllowance(id, w1, alloc);
        if (cap == 0) assertEq(rem, type(uint256).max);
        else assertEq(rem, crowdfund.contributed(id, w1) >= cap ? 0 : cap - crowdfund.contributed(id, w1));
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_AnyChangeToTheProofOrLeafFailsVerification(uint8 n, uint8 target, uint8 mutate, uint256 flip) public {
        uint256 size = bound(uint256(n), 2, 17);
        uint256 t = uint256(target) % size;
        uint256 id = crowdfund.campaignCount();
        bytes32[] memory leaves = new bytes32[](size);
        for (uint256 i; i < size; ++i) leaves[i] = _leaf(id, _member(i), _alloc(i));
        (bytes32 root_, bytes32[][] memory proofs) = _buildTree(leaves);
        _launchAccess(_wl(root_, 0), 1_000 ether, address(0), 0);
        assertTrue(crowdfund.isWhitelisted(id, _member(t), _alloc(t), proofs[t]));

        uint256 kind = uint256(mutate) % 4;
        if (kind == 0) {                                   // a different allocation
            assertFalse(crowdfund.isWhitelisted(id, _member(t), _alloc(t) + 1 + (flip % 1e18), proofs[t]));
        } else if (kind == 1) {                            // a different wallet
            assertFalse(crowdfund.isWhitelisted(id, address(uint160(0xC000 + (flip % 1000))), _alloc(t), proofs[t]));
        } else if (kind == 2 && proofs[t].length > 0) {    // one proof element altered
            bytes32[] memory bad = new bytes32[](proofs[t].length);
            for (uint256 j; j < bad.length; ++j) bad[j] = proofs[t][j];
            uint256 at = flip % bad.length;
            bad[at] = bytes32(uint256(bad[at]) ^ (1 << (flip % 256)));
            assertFalse(crowdfund.isWhitelisted(id, _member(t), _alloc(t), bad));
        } else {                                           // another member's proof
            uint256 other = (t + 1 + (flip % (size - 1))) % size;
            if (proofs[other].length != proofs[t].length || keccak256(abi.encode(proofs[other])) != keccak256(abi.encode(proofs[t])))
                assertFalse(crowdfund.isWhitelisted(id, _member(t), _alloc(t), proofs[other]));
        }
    }
}

// A quote token whose transferFrom calls back into the contributor before returning, the classic reentrancy vector.
contract MaliciousQuote {
    address public hook;
    function setHook(address h) external { hook = h; }
    function decimals() external pure returns (uint8) { return 18; }
    function balanceOf(address) external pure returns (uint256) { return type(uint256).max; }
    function transferFrom(address from, address, uint256) external returns (bool) {
        if (from == hook && hook != address(0)) ReentrantAttacker(hook).onTransferFrom();
        return true;
    }
}

contract ReentrantAttacker {
    DuckCrowdfund public immutable cf;
    uint256 public immutable id;
    uint256 public immutable amount;
    uint256 public reenterAttempts;
    uint256 public reenterSucceeded;
    bool private inside;
    constructor(DuckCrowdfund cf_, uint256 id_, uint256 amount_) { cf = cf_; id = id_; amount = amount_; }
    function attack() external { cf.contribute(id, amount); }
    function onTransferFrom() external {
        if (inside) return;
        inside = true;
        reenterAttempts++;
        try cf.contribute(id, amount) { reenterSucceeded++; } catch {}
    }
}
