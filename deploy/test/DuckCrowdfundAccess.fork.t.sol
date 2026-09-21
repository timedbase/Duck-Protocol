// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {DuckProtocolCrowdfundForkTest, IERC20Fork3} from "./DuckProtocolCrowdfund.fork.t.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";

// Access modes for a crowdfund: Open (anyone, optional per-wallet cap) or Whitelist (a Merkle list, optional
// per-wallet allocation, optional shared cap). Inherits the existing crowdfund fork suite, so every original
// launch/contribute/finalize/claim/refund test also runs against the modified contract.
contract DuckCrowdfundAccessForkTest is DuckProtocolCrowdfundForkTest {
    address w1 = makeAddr("acc-w1"); // allocation 2 ETH
    address w2 = makeAddr("acc-w2"); // allocation 0: falls back to the campaign's maxPerWallet
    address w3 = makeAddr("acc-w3"); // allocation 5 ETH
    address w4 = makeAddr("acc-w4"); // allocation 1 ETH
    address stranger = makeAddr("acc-stranger");

    bytes32[4] leaves;
    bytes32 root;
    uint256 constant A1 = 2 ether; uint256 constant A2 = 0; uint256 constant A3 = 5 ether; uint256 constant A4 = 1 ether;

    // ---- helpers --------------------------------------------------------------------------------------

    function _leaf(uint256 id, address account, uint256 allocation) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(id, account, allocation))));
    }
    function _pair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }
    // A 4-leaf tree for campaign `id`: root = H(H(l0,l1), H(l2,l3)).
    function _tree(uint256 id) internal {
        leaves[0] = _leaf(id, w1, A1); leaves[1] = _leaf(id, w2, A2); leaves[2] = _leaf(id, w3, A3); leaves[3] = _leaf(id, w4, A4);
        root = _pair(_pair(leaves[0], leaves[1]), _pair(leaves[2], leaves[3]));
    }
    function _proof(uint256 i) internal view returns (bytes32[] memory p) {
        p = new bytes32[](2);
        p[0] = leaves[i ^ 1];
        p[1] = i < 2 ? _pair(leaves[2], leaves[3]) : _pair(leaves[0], leaves[1]);
    }

    function _params(address quote, uint256 goal) internal returns (DuckCrowdfund.LaunchParams memory p) {
        p = DuckCrowdfund.LaunchParams({
            name: "Duck Raise", symbol: "DRAISE", metaURI: "", dexQuoteAsset: quote, goalNativeWei: goal, startTime: 0,
            vanitySalt: _mineTokenSalt(creator), hookFeeBps: 0, creatorBps: 9000, vaultBps: 1000, burnBps: 0, supplyTier: 0
        });
    }

    function _launchOpen(uint256 maxPerWallet, uint256 goal) internal returns (uint256 id) {
        DuckCrowdfund.LaunchParams memory p = _params(address(0), goal);
        vm.prank(creator);
        (id,) = crowdfund.launchWithAccess{value: 0.0005 ether}(
            p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: maxPerWallet, whitelistRoot: bytes32(0), whitelistURI: ""})
        );
    }

    // Launches a whitelist campaign whose id is `crowdfund.campaignCount()` and whose tree was built for that id.
    function _launchWhitelist(uint256 maxPerWallet, uint256 goal) internal returns (uint256 id) {
        id = crowdfund.campaignCount();
        _tree(id);
        DuckCrowdfund.LaunchParams memory p = _params(address(0), goal);
        vm.prank(creator);
        (uint256 got,) = crowdfund.launchWithAccess{value: 0.0005 ether}(
            p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Whitelist, maxPerWallet: maxPerWallet, whitelistRoot: root, whitelistURI: "ipfs://list"})
        );
        assertEq(got, id);
    }

    function setUp() public virtual override {
        super.setUp();
        vm.deal(w1, 100 ether); vm.deal(w2, 100 ether); vm.deal(w3, 100 ether); vm.deal(w4, 100 ether); vm.deal(stranger, 100 ether);
    }

    // ---- open campaigns ---------------------------------------------------------------------------------

    function test_OriginalLaunch_IsOpenAndUncapped() public {
        vm.prank(creator);
        (uint256 id,) = crowdfund.launch{value: 0.0005 ether}("Duck Raise", "DRAISE", "", address(0), 10 ether, 0, _mineTokenSalt(creator), 0, 9000, 1000, 0, 0);
        (DuckCrowdfund.AccessMode mode, uint256 cap, bytes32 r) = crowdfund.getCampaignAccess(id);
        assertEq(uint8(mode), uint8(DuckCrowdfund.AccessMode.Open));
        assertEq(cap, 0); assertEq(r, bytes32(0));
        vm.prank(stranger); crowdfund.contribute{value: 50 ether}(id, 0); // no cap at all
        assertEq(crowdfund.contributed(id, stranger), 50 ether);
        assertEq(crowdfund.remainingAllowance(id, stranger, 0), type(uint256).max);
    }

    function test_OpenWithCap_EnforcedPerWallet_AndAtTheBoundary() public {
        uint256 id = _launchOpen(1 ether, 10 ether);
        vm.startPrank(w1);
        crowdfund.contribute{value: 0.6 ether}(id, 0);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 1 ether, 0.6 ether));
        crowdfund.contribute{value: 0.5 ether}(id, 0);
        assertEq(crowdfund.remainingAllowance(id, w1, 0), 0.4 ether);
        crowdfund.contribute{value: 0.4 ether}(id, 0); // exactly the cap is fine
        assertEq(crowdfund.remainingAllowance(id, w1, 0), 0);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 1 ether, 1 ether));
        crowdfund.contribute{value: 1 wei}(id, 0);
        vm.stopPrank();
        // the cap is per wallet: another wallet has its own
        vm.prank(w2); crowdfund.contribute{value: 1 ether}(id, 0);
        assertEq(crowdfund.contributed(id, w1), 1 ether);
        assertEq(crowdfund.contributed(id, w2), 1 ether);
    }

    function test_OpenWithBlankCap_ViaLaunchWithAccess_IsUnlimited() public {
        uint256 id = _launchOpen(0, 10 ether);
        vm.prank(w1); crowdfund.contribute{value: 80 ether}(id, 0);
        assertEq(crowdfund.contributed(id, w1), 80 ether);
    }

    function test_OpenCampaign_RefusesWhitelistedEntryPoint() public {
        uint256 id = _launchOpen(0, 10 ether);
        _tree(id);
        vm.prank(w1);
        vm.expectRevert(DuckCrowdfund.NotWhitelistCampaign.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, A1, _proof(0));
    }

    // ---- whitelist campaigns ----------------------------------------------------------------------------

    function test_Whitelist_AllocationIsThatWalletsCap() public {
        uint256 id = _launchWhitelist(3 ether, 10 ether);
        vm.startPrank(w1); // allocation 2 ETH beats the campaign's 3 ETH default
        crowdfund.contributeWhitelisted{value: 1.5 ether}(id, 0, A1, _proof(0));
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, A1, 1.5 ether));
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, A1, _proof(0));
        crowdfund.contributeWhitelisted{value: 0.5 ether}(id, 0, A1, _proof(0));
        vm.stopPrank();
        assertEq(crowdfund.remainingAllowance(id, w1, A1), 0);
    }

    function test_Whitelist_ZeroAllocationFallsBackToTheCampaignCap() public {
        uint256 id = _launchWhitelist(3 ether, 10 ether);
        vm.startPrank(w2);
        crowdfund.contributeWhitelisted{value: 3 ether}(id, 0, A2, _proof(1));
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 3 ether, 3 ether));
        crowdfund.contributeWhitelisted{value: 1 wei}(id, 0, A2, _proof(1));
        vm.stopPrank();
    }

    function test_Whitelist_ZeroAllocationAndBlankCapIsUnlimitedForThatWallet() public {
        uint256 id = _launchWhitelist(0, 200 ether);
        vm.prank(w2); crowdfund.contributeWhitelisted{value: 90 ether}(id, 0, A2, _proof(1));
        assertEq(crowdfund.contributed(id, w2), 90 ether);
    }

    function test_Whitelist_WrongProofsRevertBeforeAnyMoneyMoves() public {
        uint256 id = _launchWhitelist(3 ether, 10 ether);
        uint256 before = stranger.balance;

        // not on the list at all, with someone else's valid proof
        vm.prank(stranger);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, A1, _proof(0));

        // on the list, but claiming a bigger allocation than the list gave them
        vm.prank(w1);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, 50 ether, _proof(0));

        // on the list, with another wallet's proof
        vm.prank(w1);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, A1, _proof(2));

        // an empty proof
        vm.prank(w1);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(id, 0, A1, new bytes32[](0));

        assertEq(stranger.balance, before, "a rejected contribution moves no value");
        assertEq(crowdfund.contributed(id, w1), 0);
        assertEq(crowdfund.contributed(id, stranger), 0);
    }

    function test_Whitelist_ProofFromAnotherCampaignDoesNotVerify() public {
        uint256 idA = _launchWhitelist(3 ether, 10 ether);
        // capture campaign A's proof for w1, then launch campaign B with a tree built for B
        bytes32[] memory proofA = _proof(0);
        uint256 idB = _launchWhitelist(3 ether, 10 ether);
        assertTrue(idB != idA);
        vm.prank(w1);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(idB, 0, A1, proofA);
        // and B's own proof works
        vm.prank(w1); crowdfund.contributeWhitelisted{value: 1 ether}(idB, 0, A1, _proof(0));
    }

    function test_Whitelist_PlainContributeIsRefused() public {
        uint256 id = _launchWhitelist(3 ether, 10 ether);
        vm.prank(w1);
        vm.expectRevert(DuckCrowdfund.WhitelistRequired.selector);
        crowdfund.contribute{value: 1 ether}(id, 0);
    }

    function test_Whitelist_UnknownCampaign() public {
        vm.prank(w1);
        vm.expectRevert(DuckCrowdfund.CampaignNotFound.selector);
        crowdfund.contributeWhitelisted{value: 1 ether}(99, 0, A1, new bytes32[](0));
    }

    function test_Whitelist_IsWhitelistedViewMatchesTheContract() public {
        uint256 id = _launchWhitelist(0, 10 ether);
        assertTrue(crowdfund.isWhitelisted(id, w3, A3, _proof(2)));
        assertFalse(crowdfund.isWhitelisted(id, stranger, A3, _proof(2)));
        assertFalse(crowdfund.isWhitelisted(id, w3, A1, _proof(2)));
        (DuckCrowdfund.AccessMode mode, uint256 cap, bytes32 r) = crowdfund.getCampaignAccess(id);
        assertEq(uint8(mode), uint8(DuckCrowdfund.AccessMode.Whitelist)); assertEq(cap, 0); assertEq(r, root);
    }

    function test_Whitelist_FullRaiseFinalizesAndWhitelistedContributorsClaim() public {
        uint256 id = _launchWhitelist(3 ether, 10 ether);
        vm.prank(w3); crowdfund.contributeWhitelisted{value: 5 ether}(id, 0, A3, _proof(2));
        vm.prank(w2); crowdfund.contributeWhitelisted{value: 3 ether}(id, 0, A2, _proof(1));
        vm.prank(w1); crowdfund.contributeWhitelisted{value: 2 ether}(id, 0, A1, _proof(0));
        vm.warp(block.timestamp + 2 hours + 1);
        crowdfund.finalize(id);
        (bool finalized, bool succeeded, address token) = _readCampaignOutcome(id);
        assertTrue(finalized); assertTrue(succeeded, "the raise met its goal");
        uint256 expected = crowdfund.previewClaimable(id, w3);
        assertGt(expected, 0);
        vm.prank(w3); crowdfund.claim(id);
        assertEq(DuckToken(payable(token)).balanceOf(w3), expected, "claims are pro-rata by contribution, unchanged by access rules");
    }

    function test_Whitelist_FailedRaiseStillRefunds() public {
        uint256 id = _launchWhitelist(3 ether, 100 ether);
        vm.prank(w1); crowdfund.contributeWhitelisted{value: 2 ether}(id, 0, A1, _proof(0));
        vm.warp(block.timestamp + 2 hours + 1);
        crowdfund.finalize(id);
        uint256 before = w1.balance;
        vm.prank(w1); crowdfund.claimRefund(id);
        assertEq(w1.balance - before, 2 ether);
    }

    // ---- launch validation ------------------------------------------------------------------------------

    function test_Launch_RejectsInconsistentAccessConfig() public {
        DuckCrowdfund.LaunchParams memory p = _params(address(0), 10 ether);
        // whitelist without a list
        vm.prank(creator);
        vm.expectRevert(DuckCrowdfund.InvalidAccessConfig.selector);
        crowdfund.launchWithAccess{value: 0.0005 ether}(p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Whitelist, maxPerWallet: 0, whitelistRoot: bytes32(0), whitelistURI: ""}));
        // an open campaign carrying a list
        vm.prank(creator);
        vm.expectRevert(DuckCrowdfund.InvalidAccessConfig.selector);
        crowdfund.launchWithAccess{value: 0.0005 ether}(p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: 0, whitelistRoot: keccak256("x"), whitelistURI: ""}));
        vm.prank(creator);
        vm.expectRevert(DuckCrowdfund.InvalidAccessConfig.selector);
        crowdfund.launchWithAccess{value: 0.0005 ether}(p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: 0, whitelistRoot: bytes32(0), whitelistURI: "ipfs://x"}));
    }

    function test_Launch_StillEnforcesTheNormalRulesAndFee() public {
        DuckCrowdfund.LaunchParams memory p = _params(address(0), 10 ether);
        vm.prank(creator);
        vm.expectRevert(DuckCrowdfund.WrongFee.selector);
        crowdfund.launchWithAccess{value: 0}(p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: 0, whitelistRoot: bytes32(0), whitelistURI: ""}));
        p.creatorBps = 5000; // 5000 + 1000 + 0 != 10000
        vm.prank(creator);
        vm.expectRevert(DuckCrowdfund.InvalidVaultBps.selector);
        crowdfund.launchWithAccess{value: 0.0005 ether}(p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: 0, whitelistRoot: bytes32(0), whitelistURI: ""}));
    }

    function test_Launch_AnnouncesTheAccessConfig() public {
        _tree(0);
        DuckCrowdfund.LaunchParams memory p = _params(address(0), 10 ether);
        vm.expectEmit(true, false, false, true, address(crowdfund));
        emit DuckCrowdfund.CampaignAccessSet(0, DuckCrowdfund.AccessMode.Whitelist, 3 ether, root, "ipfs://list");
        vm.prank(creator);
        crowdfund.launchWithAccess{value: 0.0005 ether}(p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Whitelist, maxPerWallet: 3 ether, whitelistRoot: root, whitelistURI: "ipfs://list"}));
    }

    // ---- ERC-20 quote asset -----------------------------------------------------------------------------

    function test_Erc20Quote_CapIsInTheAssetsOwnUnitsAndChecksBeforeAnyTransfer() public {
        vm.prank(owner); crowdfund.setQuoteAssetAllowed(USDG, true);
        DuckCrowdfund.LaunchParams memory p = _params(USDG, 50_000e6);
        vm.prank(creator);
        (uint256 id,) = crowdfund.launchWithAccess{value: 0.0005 ether}(
            p, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: 1_000e6, whitelistRoot: bytes32(0), whitelistURI: ""})
        );
        _giveUsdg(w1, 5_000e6);
        vm.startPrank(w1);
        IERC20Fork3(USDG).approve(address(crowdfund), 5_000e6);
        crowdfund.contribute(id, 600e6);
        uint256 held = IERC20Fork3(USDG).balanceOf(w1);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 1_000e6, 600e6));
        crowdfund.contribute(id, 500e6);
        assertEq(IERC20Fork3(USDG).balanceOf(w1), held, "nothing pulled on a rejected contribution");
        crowdfund.contribute(id, 400e6);
        vm.stopPrank();
        assertEq(crowdfund.contributed(id, w1), 1_000e6);
    }
}
