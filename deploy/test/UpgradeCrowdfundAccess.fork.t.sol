// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {UpgradeCrowdfundAccess} from "../script/UpgradeCrowdfundAccess.s.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";

// The upgrade exactly as the script broadcasts it, against the LIVE Robinhood crowdfund and its real campaign #0 (FEG).
contract UpgradeCrowdfundAccessForkTest is Test {
    address constant PROXY = 0xdA868A545aB058D14a70C46CA7760226e7Dcf7b9;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    DuckCrowdfund live = DuckCrowdfund(payable(PROXY));

    function setUp() public { vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL")); }

    function test_Upgrade_KeepsEveryPieceOfLiveState_AndOldCampaignsReadAsOpen() public {
        uint256 count = live.campaignCount();
        assertGt(count, 0, "the live crowdfund has FEG's campaign");
        (address creator, address quote, uint256 goal, uint256 startTime, uint256 deadline, uint256 raised, bool finalized, bool succeeded, address token) = live.getCampaignCore(0);
        (string memory name, string memory symbol,,, uint256 cBps, uint256 lBps, uint256 hookFee, uint16 vaultBps, uint256 supply) = live.getCampaignMeta(0);
        uint256 contributedBefore = live.contributed(0, creator);
        uint256 claimableBefore = live.previewClaimable(0, creator);
        address ownerBefore = live.owner(); uint256 feeBefore = live.campaignFee(); address hookBefore = live.v4Hook();
        address tokenImplBefore = live.tokenImpl(); uint256 durationBefore = live.campaignDuration(); address platformBefore = live.platformWallet();

        address impl = new UpgradeCrowdfundAccess().upgradeAs(OWNER);
        assertEq(address(uint160(uint256(vm.load(PROXY, IMPL_SLOT)))), impl, "the proxy points at the new implementation");

        assertEq(live.campaignCount(), count);
        (address c2, address q2, uint256 g2, uint256 s2, uint256 d2, uint256 r2, bool f2, bool su2, address t2) = live.getCampaignCore(0);
        assertEq(c2, creator); assertEq(q2, quote); assertEq(g2, goal); assertEq(s2, startTime); assertEq(d2, deadline);
        assertEq(r2, raised); assertEq(f2, finalized); assertEq(su2, succeeded); assertEq(t2, token);
        (string memory n2, string memory sy2,,, uint256 cb2, uint256 lb2, uint256 hf2, uint16 vb2, uint256 sp2) = live.getCampaignMeta(0);
        assertEq(n2, name); assertEq(sy2, symbol); assertEq(cb2, cBps); assertEq(lb2, lBps); assertEq(hf2, hookFee); assertEq(vb2, vaultBps); assertEq(sp2, supply);
        assertEq(live.contributed(0, creator), contributedBefore);
        assertEq(live.previewClaimable(0, creator), claimableBefore);
        assertEq(live.owner(), ownerBefore); assertEq(live.campaignFee(), feeBefore); assertEq(live.v4Hook(), hookBefore);
        assertEq(live.tokenImpl(), tokenImplBefore); assertEq(live.campaignDuration(), durationBefore); assertEq(live.platformWallet(), platformBefore);

        // The campaign that already existed reads as Open with no cap, i.e. exactly as it behaved.
        (DuckCrowdfund.AccessMode mode, uint256 cap, bytes32 root) = live.getCampaignAccess(0);
        assertEq(uint8(mode), uint8(DuckCrowdfund.AccessMode.Open)); assertEq(cap, 0); assertEq(root, bytes32(0));
        assertEq(live.remainingAllowance(0, makeAddr("anyone"), 0), type(uint256).max);
        emit log_named_decimal_uint("FEG campaign raised (kept)", raised, 18);
    }

    function test_OnLiveState_OpenCapAndWhitelistCampaignsWork() public {
        new UpgradeCrowdfundAccess().upgradeAs(OWNER);
        address maker = makeAddr("live-maker"); address a = makeAddr("live-a"); address b = makeAddr("live-b"); address stranger = makeAddr("live-stranger");
        vm.deal(maker, 10 ether); vm.deal(a, 10 ether); vm.deal(b, 10 ether); vm.deal(stranger, 10 ether);
        uint256 fee = live.campaignFee();

        // Open with a 1 ETH cap
        uint256 openId = live.campaignCount();
        DuckCrowdfund.LaunchParams memory openP = _params(maker, 5 ether); // built before the prank: it makes an external call
        vm.prank(maker);
        live.launchWithAccess{value: fee}(openP, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: 1 ether, whitelistRoot: bytes32(0), whitelistURI: ""}));
        vm.prank(a); live.contribute{value: 0.7 ether}(openId, 0);
        vm.prank(a);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 1 ether, 0.7 ether));
        live.contribute{value: 0.4 ether}(openId, 0);

        // Whitelist: a = 0.5 ETH allocation, b = shared 0.25 ETH max
        uint256 wlId = live.campaignCount();
        bytes32 la = keccak256(bytes.concat(keccak256(abi.encode(wlId, a, uint256(0.5 ether)))));
        bytes32 lb = keccak256(bytes.concat(keccak256(abi.encode(wlId, b, uint256(0)))));
        bytes32 wlRoot = la < lb ? keccak256(abi.encodePacked(la, lb)) : keccak256(abi.encodePacked(lb, la));
        DuckCrowdfund.LaunchParams memory wlP = _params(maker, 5 ether);
        vm.prank(maker);
        live.launchWithAccess{value: fee}(wlP, DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Whitelist, maxPerWallet: 0.25 ether, whitelistRoot: wlRoot, whitelistURI: "ipfs://list"}));
        bytes32[] memory pa = new bytes32[](1); pa[0] = lb;
        bytes32[] memory pb = new bytes32[](1); pb[0] = la;
        vm.prank(a); live.contributeWhitelisted{value: 0.5 ether}(wlId, 0, 0.5 ether, pa);
        vm.prank(b); live.contributeWhitelisted{value: 0.25 ether}(wlId, 0, 0, pb);
        vm.prank(b);
        vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, 0.25 ether, 0.25 ether));
        live.contributeWhitelisted{value: 1 wei}(wlId, 0, 0, pb);
        vm.prank(stranger);
        vm.expectRevert(DuckCrowdfund.InvalidProof.selector);
        live.contributeWhitelisted{value: 0.1 ether}(wlId, 0, 0.5 ether, pa);
        vm.prank(a);
        vm.expectRevert(DuckCrowdfund.WhitelistRequired.selector);
        live.contribute{value: 0.1 ether}(wlId, 0);

        // The original launch() still works on the upgraded live proxy, and yields an Open, uncapped campaign
        uint256 oldId = live.campaignCount();
        DuckCrowdfund.LaunchParams memory p = _params(maker, 5 ether);
        vm.prank(maker);
        live.launch{value: fee}(p.name, p.symbol, p.metaURI, p.dexQuoteAsset, p.goalNativeWei, p.startTime, p.vanitySalt, p.hookFeeBps, p.creatorBps, p.vaultBps, p.burnBps, p.supplyTier);
        (DuckCrowdfund.AccessMode mode, uint256 cap,) = live.getCampaignAccess(oldId);
        assertEq(uint8(mode), uint8(DuckCrowdfund.AccessMode.Open)); assertEq(cap, 0);
    }

    function test_OnlyTheOwnerCanUpgrade() public {
        address impl = address(new DuckCrowdfund());
        vm.prank(makeAddr("not-owner"));
        vm.expectRevert();
        live.upgradeToAndCall(impl, "");
    }

    // ---- helpers ------------------------------------------------------------------------------------------

    uint256 private _cursor;

    function _params(address maker, uint256 goal) internal returns (DuckCrowdfund.LaunchParams memory) {
        return DuckCrowdfund.LaunchParams({
            name: "Live Raise", symbol: "LRAISE", metaURI: "", dexQuoteAsset: address(0), goalNativeWei: goal, startTime: 0,
            vanitySalt: _mineSalt(maker), hookFeeBps: 200, creatorBps: 10_000, vaultBps: 0, burnBps: 0, supplyTier: 0
        });
    }

    // The crowdfund only accepts a token clone whose address ends in 0x8888. Scratch memory is reused every iteration:
    // allocating per iteration (abi.encode in a loop) runs the test out of memory long before a suffix turns up.
    function _mineSalt(address maker) internal returns (bytes32 userSalt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", live.tokenImpl(), hex"5af43d82803e903d91602b57fd5bf3"));
        address family = address(live);
        uint256 from = _cursor;
        bool found;
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            for { let i := from } lt(i, add(from, 2000000)) { i := add(i, 1) } {
                mstore(ptr, maker)
                mstore(add(ptr, 0x20), i)
                let salt := keccak256(ptr, 0x40)
                mstore8(add(ptr, 0x40), 0xff)
                mstore(add(ptr, 0x41), shl(96, family))
                mstore(add(ptr, 0x55), salt)
                mstore(add(ptr, 0x75), initCodeHash)
                if eq(and(keccak256(add(ptr, 0x40), 0x55), 0xffff), 0x8888) { userSalt := i found := 1 break }
            }
        }
        require(found, "salt not found");
        _cursor = uint256(userSalt) + 1;
    }
}
