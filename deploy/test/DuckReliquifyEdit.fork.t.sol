// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {OwnableUnauthorizedAccount} from "./DuckReliquifyEdit.errors.sol";

import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {DuckReliquifyToken} from "duck-lib/DuckReliquifyToken.sol";
import {Route, RouteShape} from "duck-lib/LaunchRouting.sol";

interface IERC20Edit {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}
interface IHookEdit { function owner() external view returns (address); function platformWallet() external view returns (address); function addLauncher(address) external; }
interface IVaultFactoryEdit { function owner() external view returns (address); function setFamily(address, bool) external; }

// Allocation edits on a live migration: the leader proposes (which pauses), the platform approves or rejects, and after a
// 24 hour delay the leader applies; after the seed only the owner edits; the owner can finalize a seeded migration and rescue
// the reserve. Everything is bounded by one rule: undeposited allocation <= reserved. Runs against the real Robinhood
// stack (real hook, vault factory, pool and router) like the other Reliquify fork suites.
contract DuckReliquifyEditForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER    = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant HOOK                = 0x18bd65Fb1c44DD629caD7c7F5B96aD2bCAF76ACC;
    address constant VAULT_FACTORY       = 0x006e53d079BB4c2010682a4896D1950965faD5A5;
    address constant OLD_TOKEN           = 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4; // BTC, 8 decimals
    address constant DEAD                = 0x000000000000000000000000000000000000dEaD;

    DuckReliquify reliquify;
    address leader    = makeAddr("ed-leader");
    address holder1   = makeAddr("ed-holder1");
    address holder2   = makeAddr("ed-holder2");
    address holder3   = makeAddr("ed-holder3");
    address newcomer1 = makeAddr("ed-newcomer1");
    address newcomer2 = makeAddr("ed-newcomer2");
    address other     = makeAddr("ed-other");
    address treasury  = makeAddr("ed-treasury");
    uint256 constant H1 = 3e7; uint256 constant H2 = 3e7; uint256 constant H3 = 4e7; // eligible 1e8

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        DuckReliquifyToken tokenImpl = new DuckReliquifyToken(VAULT_FACTORY);
        DuckReliquify impl = new DuckReliquify();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(DuckReliquify.initialize, (WETH, address(tokenImpl), V4_POOL_MANAGER, V4_POSITION_MANAGER, HOOK, IHookEdit(HOOK).platformWallet()))
        );
        reliquify = DuckReliquify(payable(address(proxy)));
        reliquify.setUniversalRouter(UNIVERSAL_ROUTER);
        reliquify.setVaultFactory(VAULT_FACTORY);
        vm.prank(IHookEdit(HOOK).owner()); IHookEdit(HOOK).addLauncher(address(reliquify));
        vm.prank(IVaultFactoryEdit(VAULT_FACTORY).owner()); IVaultFactoryEdit(VAULT_FACTORY).setFamily(address(reliquify), true);

        Route[] memory routes = new Route[](1);
        address[] memory path = new address[](2); path[0] = WETH; path[1] = OLD_TOKEN;
        uint24[] memory fees = new uint24[](1); fees[0] = 3000;
        routes[0] = Route({shape: RouteShape.V3_STYLE, enabled: true, path: path, fees: fees, hook: address(0), fee: 0, tickSpacing: 0});
        reliquify.setRoutes(OLD_TOKEN, routes);

        address[6] memory who = [holder1, holder2, holder3, newcomer1, newcomer2, other];
        for (uint256 i; i < who.length; ++i) deal(OLD_TOKEN, who[i], 1e9);
    }

    // ---- helpers --------------------------------------------------------------------------------------------

    function _live() internal returns (uint256 id, address newToken) {
        vm.prank(leader);
        id = reliquify.proposeMigration(OLD_TOKEN, 200, 10_000, 0, 0);
        address[] memory a = new address[](3); a[0] = holder1; a[1] = holder2; a[2] = holder3;
        uint256[] memory b = new uint256[](3); b[0] = H1; b[1] = H2; b[2] = H3;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, a, b);
        reliquify.finalizeSnapshot(id);
        vm.stopPrank();
        newToken = reliquify.approveMigration(id, "Edit Token", "EDT", "");
    }

    function _deposit(uint256 id, address who, uint256 amt) internal {
        vm.startPrank(who);
        IERC20Edit(OLD_TOKEN).approve(address(reliquify), amt);
        reliquify.depositPreSeed(id, amt);
        vm.stopPrank();
    }

    function _seed(uint256 id) internal {
        _deposit(id, holder1, H1); _deposit(id, holder2, H2); // 6e7 of 1e8 clears the 50% threshold
        reliquify.seedPool(id, 0);
    }

    // Two-wallet edit, sorted ascending as the contract requires.
    function _two(address x, uint256 cx, address y, uint256 cy) internal pure returns (address[] memory a, uint256[] memory c) {
        a = new address[](2); c = new uint256[](2);
        if (x < y) { a[0] = x; c[0] = cx; a[1] = y; c[1] = cy; } else { a[0] = y; c[0] = cy; a[1] = x; c[1] = cx; }
    }
    function _sorted(address[] memory a, uint256[] memory c) internal pure returns (address[] memory, uint256[] memory) {
        for (uint256 i = 1; i < a.length; ++i) {
            for (uint256 j = i; j > 0 && a[j - 1] > a[j]; --j) { (a[j - 1], a[j]) = (a[j], a[j - 1]); (c[j - 1], c[j]) = (c[j], c[j - 1]); }
        }
        return (a, c);
    }

    // Moves 1e7 of undeposited allocation from holder3 to newcomer1: net zero, always valid on a fresh migration.
    function _move() internal view returns (address[] memory a, uint256[] memory c) {
        return _two(holder3, H3 - 1e7, newcomer1, 1e7);
    }

    function _propose(uint256 id) internal returns (address[] memory a, uint256[] memory c) {
        (a, c) = _move();
        vm.prank(leader); reliquify.proposeAllocationEdit(id, a, c);
    }

    function _approveAndWait(uint256 id) internal {
        reliquify.approveAllocationEdit(id);
        vm.warp(block.timestamp + 24 hours);
    }

    function _pendingApproved(uint256 id) internal view returns (bool ap) { (,,,, ap,) = reliquify.pendingEdit(id); }
    function _pendingHash(uint256 id) internal view returns (bytes32 h) { (h,,,,,) = reliquify.pendingEdit(id); }
    function _pausedByEdit(uint256 id) internal view returns (bool p) { (,,,,, p) = reliquify.pendingEdit(id); }
    function _undeposited(uint256 id) internal view returns (uint256 u, uint256 r, uint256 s) {
        (,,, uint256 eligible, uint256 totalDep, uint256 reserved,) = reliquify.getMigration(id);
        u = eligible - totalDep; r = reserved; s = r > u ? r - u : 0;
    }

    // ================================================================================================ proposing

    function test_Propose_PausesTheMigrationAndRecordsThePendingEdit() public {
        (uint256 id,) = _live();
        (address[] memory a, uint256[] memory c) = _move();
        bytes32 h = keccak256(abi.encode(a, c));
        vm.expectEmit(true, false, false, true, address(reliquify));
        emit DuckReliquify.AllocationEditProposed(id, h, 2, uint64(block.timestamp + 24 hours));
        vm.expectEmit(true, true, false, true, address(reliquify));
        emit DuckReliquify.AllocationEditData(id, h, a, c);
        vm.prank(leader); reliquify.proposeAllocationEdit(id, a, c);

        assertTrue(reliquify.paused(id), "proposing pauses the migration");
        (bytes32 dh, uint64 at, uint64 ready, uint32 count, bool ap, bool byEdit) = reliquify.pendingEdit(id);
        assertEq(dh, h); assertEq(at, block.timestamp); assertEq(ready, block.timestamp + 24 hours); assertEq(count, 2);
        assertFalse(ap); assertTrue(byEdit);
        vm.prank(holder1); vm.expectRevert(DuckReliquify.Paused.selector);
        reliquify.depositPreSeed(id, 1);
        // nothing changes until it is applied
        assertEq(reliquify.eligibleBalance(id, holder3), H3); assertEq(reliquify.eligibleBalance(id, newcomer1), 0);
    }

    function test_Propose_OnlyTheLeader_OnlyWhileLive() public {
        (address[] memory a, uint256[] memory c) = _move();
        vm.prank(leader); uint256 pid = reliquify.proposeMigration(OLD_TOKEN, 200, 10_000, 0, 0);
        vm.prank(leader); vm.expectRevert(DuckReliquify.WrongStatus.selector); // still Proposed
        reliquify.proposeAllocationEdit(pid, a, c);

        (uint256 id,) = _live();
        vm.prank(holder1); vm.expectRevert(DuckReliquify.NotLeader.selector);
        reliquify.proposeAllocationEdit(id, a, c);
        vm.expectRevert(DuckReliquify.NotLeader.selector); // the owner does not propose; it reviews
        reliquify.proposeAllocationEdit(id, a, c);
        vm.expectRevert(DuckReliquify.MigrationNotFound.selector);
        reliquify.proposeAllocationEdit(99, a, c);

        _seed(id); // Seeded: the leader can no longer edit
        vm.prank(leader); vm.expectRevert(DuckReliquify.WrongStatus.selector);
        reliquify.proposeAllocationEdit(id, a, c);
    }

    function test_Propose_RejectsAnythingThatBreaksTheRuleUpFront() public {
        (uint256 id,) = _live();
        // empty, and mismatched lengths
        vm.startPrank(leader);
        vm.expectRevert(DuckReliquify.InvalidEdit.selector);
        reliquify.proposeAllocationEdit(id, new address[](0), new uint256[](0));
        vm.expectRevert(DuckReliquify.InvalidEdit.selector);
        reliquify.proposeAllocationEdit(id, new address[](2), new uint256[](1));
        // not strictly ascending: a duplicate, and descending
        (address[] memory a, uint256[] memory c) = _move();
        address[] memory dup = new address[](2); dup[0] = a[0]; dup[1] = a[0];
        vm.expectRevert(DuckReliquify.InvalidEdit.selector);
        reliquify.proposeAllocationEdit(id, dup, c);
        address[] memory desc = new address[](2); desc[0] = a[1]; desc[1] = a[0];
        vm.expectRevert(DuckReliquify.InvalidEdit.selector);
        reliquify.proposeAllocationEdit(id, desc, c);
        // the zero address is not a wallet (it is never above address(0))
        address[] memory z = new address[](1); z[0] = address(0); uint256[] memory zc = new uint256[](1);
        vm.expectRevert(DuckReliquify.InvalidEdit.selector);
        reliquify.proposeAllocationEdit(id, z, zc);
        // raising a wallet without lowering another exceeds what is reserved (1e8 reserved, 1e8 already allocated)
        (address[] memory ra, uint256[] memory rc) = _two(holder3, H3, newcomer1, 1);
        vm.expectRevert(abi.encodeWithSelector(DuckReliquify.ExceedsReserved.selector, 1e8 + 1, 1e8));
        reliquify.proposeAllocationEdit(id, ra, rc);
        // everything to zero
        address[] memory all = new address[](3); all[0] = holder1; all[1] = holder2; all[2] = holder3;
        (all,) = _sorted(all, new uint256[](3));
        vm.expectRevert(DuckReliquify.ZeroAmount.selector);
        reliquify.proposeAllocationEdit(id, all, new uint256[](3));
        // too large
        address[] memory big = new address[](401); uint256[] memory bc = new uint256[](401);
        for (uint256 i; i < 401; ++i) big[i] = address(uint160(0x10000 + i));
        vm.expectRevert(DuckReliquify.EditTooLarge.selector);
        reliquify.proposeAllocationEdit(id, big, bc);
        vm.stopPrank();
        assertFalse(reliquify.paused(id), "a rejected proposal pauses nothing");
    }

    function test_Propose_CannotGoBelowWhatAWalletHasDeposited() public {
        (uint256 id,) = _live();
        _deposit(id, holder3, 2e7);
        (address[] memory a, uint256[] memory c) = _two(holder3, 1e7, newcomer1, 3e7);
        vm.prank(leader); vm.expectRevert(abi.encodeWithSelector(DuckReliquify.BelowDeposited.selector, holder3, 2e7));
        reliquify.proposeAllocationEdit(id, a, c);
        // exactly what it deposited is fine, and frees the remainder for someone else
        (a, c) = _two(holder3, 2e7, newcomer1, 2e7);
        vm.prank(leader); reliquify.proposeAllocationEdit(id, a, c);
    }

    function test_Propose_ExcludedWalletCannotBeEdited() public {
        vm.prank(leader); uint256 id = reliquify.proposeMigration(OLD_TOKEN, 200, 10_000, 0, 0);
        address[] memory a = new address[](4); a[0] = holder1; a[1] = holder2; a[2] = holder3; a[3] = other;
        uint256[] memory b = new uint256[](4); b[0] = H1; b[1] = H2; b[2] = H3; b[3] = 5e6;
        address[] memory ex = new address[](1); ex[0] = other;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, a, b); reliquify.submitExclusions(id, ex); reliquify.finalizeSnapshot(id);
        vm.stopPrank();
        reliquify.approveMigration(id, "X", "X", "");
        (address[] memory ea, uint256[] memory ec) = _two(other, 1e6, holder3, H3 - 1e6);
        vm.prank(leader); vm.expectRevert(DuckReliquify.AlreadyExcluded.selector);
        reliquify.proposeAllocationEdit(id, ea, ec);
    }

    function test_Propose_OnlyOneEditAtATime() public {
        (uint256 id,) = _live();
        _propose(id);
        (address[] memory a, uint256[] memory c) = _two(holder1, H1 - 1e6, newcomer2, 1e6);
        vm.prank(leader); vm.expectRevert(DuckReliquify.EditPending.selector);
        reliquify.proposeAllocationEdit(id, a, c);
    }

    // ================================================================================================ platform review

    function test_Review_OnlyTheOwnerApprovesOrRejects() public {
        (uint256 id,) = _live();
        vm.expectRevert(DuckReliquify.NoPendingEdit.selector);
        reliquify.approveAllocationEdit(id);
        vm.expectRevert(DuckReliquify.NoPendingEdit.selector);
        reliquify.rejectAllocationEdit(id);
        _propose(id);
        vm.prank(leader); vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, leader));
        reliquify.approveAllocationEdit(id);
        vm.prank(leader); vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, leader));
        reliquify.rejectAllocationEdit(id);
        reliquify.approveAllocationEdit(id);
        assertTrue(_pendingApproved(id));
        vm.expectRevert(DuckReliquify.EditAlreadyApproved.selector);
        reliquify.approveAllocationEdit(id);
    }

    function test_Reject_ResumesTheMigration_AndAllowsAFreshProposal() public {
        (uint256 id,) = _live();
        _propose(id);
        assertTrue(reliquify.paused(id));
        reliquify.rejectAllocationEdit(id);
        assertFalse(reliquify.paused(id), "the migration resumes");
        assertEq(_pendingHash(id), bytes32(0));
        assertEq(reliquify.eligibleBalance(id, newcomer1), 0, "nothing was applied");
        _deposit(id, holder1, 1e6); // deposits work again
        _propose(id);               // and a new edit can be proposed
    }

    function test_Reject_LeavesAnOwnerPausePaused() public {
        (uint256 id,) = _live();
        reliquify.setPaused(id, true); // the owner had already paused it
        _propose(id);
        assertFalse(_pausedByEdit(id), "the edit did not cause this pause");
        reliquify.rejectAllocationEdit(id);
        assertTrue(reliquify.paused(id), "the owner's own pause stays");
    }

    function test_OwnerTakingOverThePause_MeansResolvingTheEditDoesNotUndoIt() public {
        (uint256 id,) = _live();
        _propose(id);
        reliquify.setPaused(id, false); // owner resumes...
        reliquify.setPaused(id, true);  // ...and pauses again for its own reasons
        assertFalse(_pausedByEdit(id));
        reliquify.rejectAllocationEdit(id);
        assertTrue(reliquify.paused(id));
    }

    function test_LeaderCanCancelTheirOwnEdit_OthersCannot() public {
        (uint256 id,) = _live();
        _propose(id);
        vm.prank(holder1); vm.expectRevert(DuckReliquify.NotLeader.selector);
        reliquify.cancelAllocationEdit(id);
        vm.prank(leader); reliquify.cancelAllocationEdit(id);
        assertFalse(reliquify.paused(id));
        assertEq(_pendingHash(id), bytes32(0));
        vm.prank(leader); vm.expectRevert(DuckReliquify.NoPendingEdit.selector);
        reliquify.cancelAllocationEdit(id);
    }

    // ================================================================================================ applying

    function test_Apply_NeedsApproval_ThenTheFullDelay_ThenTheExactList() public {
        (uint256 id,) = _live();
        (address[] memory a, uint256[] memory c) = _propose(id);
        vm.warp(block.timestamp + 24 hours);
        vm.prank(leader); vm.expectRevert(DuckReliquify.EditNotApproved.selector); // the delay alone is not enough
        reliquify.applyAllocationEdit(id, a, c);

        // approved, but a second short of the delay
        (, , uint64 ready,,,) = reliquify.pendingEdit(id);
        reliquify.approveAllocationEdit(id);
        vm.warp(ready - 1);
        vm.prank(leader); vm.expectRevert(DuckReliquify.EditNotReady.selector);
        reliquify.applyAllocationEdit(id, a, c);

        vm.warp(ready); // ready exactly at the boundary
        // a different list, a stranger
        (address[] memory a2, uint256[] memory c2) = _two(holder3, H3 - 2e7, newcomer1, 2e7);
        vm.prank(leader); vm.expectRevert(DuckReliquify.EditDataMismatch.selector);
        reliquify.applyAllocationEdit(id, a2, c2);
        vm.prank(holder1); vm.expectRevert(DuckReliquify.NotLeader.selector);
        reliquify.applyAllocationEdit(id, a, c);

        vm.expectEmit(true, false, false, false, address(reliquify));
        emit DuckReliquify.AllocationEditApplied(id, bytes32(0), 0, address(0));
        vm.prank(leader); reliquify.applyAllocationEdit(id, a, c);
        assertEq(reliquify.eligibleBalance(id, holder3), H3 - 1e7);
        assertEq(reliquify.eligibleBalance(id, newcomer1), 1e7);
        assertFalse(reliquify.paused(id), "applying resumes the migration");
        assertEq(_pendingHash(id), bytes32(0));
        (uint256 und, uint256 res, uint256 sur) = _undeposited(id);
        assertEq(und, 1e8); assertEq(res, 1e8); assertEq(sur, 0, "a net-zero move leaves no surplus");
        (,,, uint256 eligible,,,) = reliquify.getMigration(id);
        assertEq(eligible, 1e8);
    }

    function test_Apply_TheNewAllocationsAreEnforcedByDeposits() public {
        (uint256 id,) = _live();
        (address[] memory a, uint256[] memory c) = _propose(id);
        _approveAndWait(id);
        vm.prank(leader); reliquify.applyAllocationEdit(id, a, c);
        // newcomer1 can now migrate up to 1e7, no more
        _deposit(id, newcomer1, 1e7);
        vm.startPrank(newcomer1);
        IERC20Edit(OLD_TOKEN).approve(address(reliquify), 1);
        vm.expectRevert(DuckReliquify.CapExceeded.selector);
        reliquify.depositPreSeed(id, 1);
        vm.stopPrank();
        // holder3 lost 1e7 of allocation
        vm.startPrank(holder3);
        IERC20Edit(OLD_TOKEN).approve(address(reliquify), H3);
        vm.expectRevert(DuckReliquify.CapExceeded.selector);
        reliquify.depositPreSeed(id, H3);
        reliquify.depositPreSeed(id, H3 - 1e7);
        vm.stopPrank();
    }

    function test_Apply_WindowExpires_AndAnyoneCanClearIt() public {
        (uint256 id,) = _live();
        (address[] memory a, uint256[] memory c) = _propose(id);
        (, , uint64 ready,,,) = reliquify.pendingEdit(id);
        vm.expectRevert(DuckReliquify.EditNotExpired.selector);
        reliquify.clearExpiredEdit(id);
        reliquify.approveAllocationEdit(id);
        vm.warp(uint256(ready) + 7 days - 1);
        vm.prank(leader); reliquify.applyAllocationEdit(id, a, c); // still inside the window
        // a second edit, left to expire
        (a, c) = _two(holder1, H1 - 1e6, newcomer2, 1e6);
        vm.prank(leader); reliquify.proposeAllocationEdit(id, a, c);
        (, , uint64 ready2,,,) = reliquify.pendingEdit(id);
        vm.warp(uint256(ready2) + 7 days);
        vm.expectRevert(DuckReliquify.EditExpired.selector);
        reliquify.approveAllocationEdit(id);
        assertTrue(reliquify.paused(id), "still paused until someone clears it");
        vm.prank(makeAddr("anyone")); reliquify.clearExpiredEdit(id);
        assertFalse(reliquify.paused(id));
        assertEq(_pendingHash(id), bytes32(0));
    }

    function test_Apply_ApprovedButPastTheWindow_Reverts() public {
        (uint256 id,) = _live();
        (address[] memory a, uint256[] memory c) = _propose(id);
        reliquify.approveAllocationEdit(id);
        (, , uint64 ready,,,) = reliquify.pendingEdit(id);
        vm.warp(uint256(ready) + 7 days);
        vm.prank(leader); vm.expectRevert(DuckReliquify.EditExpired.selector);
        reliquify.applyAllocationEdit(id, a, c);
    }

    function test_Apply_TheOwnerMayApplyToo() public {
        (uint256 id,) = _live();
        (address[] memory a, uint256[] memory c) = _propose(id);
        _approveAndWait(id);
        reliquify.applyAllocationEdit(id, a, c);
        assertEq(reliquify.eligibleBalance(id, newcomer1), 1e7);
    }

    // The migration can be unpaused by the owner while an edit waits, so everything is checked again at apply time.
    function test_Apply_RechecksTheRule_WhenDepositsMovedInTheMeantime() public {
        (uint256 id,) = _live();
        (address[] memory a, uint256[] memory c) = _propose(id); // holder3 down to 3e7
        _approveAndWait(id);
        reliquify.setPaused(id, false);
        _deposit(id, holder3, 4e7); // holder3 deposits everything it had
        vm.prank(leader); vm.expectRevert(abi.encodeWithSelector(DuckReliquify.BelowDeposited.selector, holder3, 4e7));
        reliquify.applyAllocationEdit(id, a, c);
    }

    function test_Apply_RevertsIfTheMigrationWasSeededMeanwhile() public {
        (uint256 id,) = _live();
        (address[] memory a, uint256[] memory c) = _propose(id);
        _approveAndWait(id);
        reliquify.setPaused(id, false);
        _seed(id);
        vm.prank(leader); vm.expectRevert(DuckReliquify.WrongStatus.selector);
        reliquify.applyAllocationEdit(id, a, c);
    }

    function test_Apply_LoweringAllocationsCanTriggerTheThreshold() public {
        (uint256 id,) = _live();
        _deposit(id, holder3, H3); // 4e7 of 1e8: below half
        vm.expectRevert(DuckReliquify.ThresholdNotReached.selector);
        reliquify.seedPool(id, 0);
        // the leader removes holder1 and holder2's undeposited allocations: eligible becomes 4e7, so 4e7 deposited is over half
        address[] memory a = new address[](2); a[0] = holder1; a[1] = holder2; uint256[] memory c = new uint256[](2);
        (a, c) = _sorted(a, c);
        vm.prank(leader); reliquify.proposeAllocationEdit(id, a, c);
        _approveAndWait(id);
        vm.prank(leader); reliquify.applyAllocationEdit(id, a, c);
        (,,, uint256 eligible,,,) = reliquify.getMigration(id);
        assertEq(eligible, 4e7);
        (uint256 und, uint256 res, uint256 sur) = _undeposited(id);
        assertEq(und, 0); assertEq(res, 6e7); assertEq(sur, 6e7, "the lowered allocations are now surplus in the reserve");
        reliquify.seedPool(id, 0); // now allowed
    }

    // ================================================================================================ after the seed

    function test_PostSeed_OnlyTheOwnerEdits_ImmediatelyAndWithinTheReserve() public {
        (uint256 id,) = _live();
        _seed(id); // holder3 (4e7) has not deposited: reserved 4e7, undeposited allocation 4e7
        (address[] memory a, uint256[] memory c) = _move();
        vm.prank(leader); vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, leader));
        reliquify.adminAdjustAllocations(id, a, c);
        reliquify.adminAdjustAllocations(id, a, c); // a net-zero move is fine
        assertEq(reliquify.eligibleBalance(id, newcomer1), 1e7);
        assertEq(reliquify.eligibleBalance(id, holder3), H3 - 1e7);

        // raising anyone above what is left would promise tokens that are not there
        (a, c) = _two(newcomer1, 1e7 + 1, holder3, H3 - 1e7);
        vm.expectRevert(abi.encodeWithSelector(DuckReliquify.ExceedsReserved.selector, 4e7 + 1, 4e7));
        reliquify.adminAdjustAllocations(id, a, c);
        // ...and a wallet that deposited before the seed cannot be cut below its deposit
        (a, c) = _two(holder1, H1 - 1, newcomer2, 1);
        vm.expectRevert(abi.encodeWithSelector(DuckReliquify.BelowDeposited.selector, holder1, H1));
        reliquify.adminAdjustAllocations(id, a, c);
        // empty / bad shape
        vm.expectRevert(DuckReliquify.InvalidEdit.selector);
        reliquify.adminAdjustAllocations(id, new address[](0), new uint256[](0));
    }

    function test_PostSeed_AdminEditIsEnforcedByPostSeedDeposits() public {
        (uint256 id,) = _live();
        _seed(id);
        (address[] memory a, uint256[] memory c) = _two(holder3, 1e7, newcomer1, 0);
        reliquify.adminAdjustAllocations(id, a, c); // holder3 cut to 1e7: 3e7 becomes surplus
        (uint256 und, uint256 res, uint256 sur) = _undeposited(id);
        assertEq(und, 1e7); assertEq(res, 4e7); assertEq(sur, 3e7);
        vm.startPrank(holder3);
        IERC20Edit(OLD_TOKEN).approve(address(reliquify), H3);
        vm.expectRevert(DuckReliquify.CapExceeded.selector);
        reliquify.depositPostSeed(id, 2e7, 0, 0);
        reliquify.depositPostSeed(id, 1e7, 0, 0);
        vm.stopPrank();
    }

    function test_PostSeed_LeaderPendingEditCannotBeAppliedAfterTheSeed_AndOwnerEditsBeforeSeedDoNotExist() public {
        (uint256 id,) = _live();
        (address[] memory a, uint256[] memory c) = _move();
        vm.expectRevert(DuckReliquify.WrongStatus.selector); // pre-seed the owner reviews; it does not edit directly
        reliquify.adminAdjustAllocations(id, a, c);
    }

    // ================================================================================================ finalize and rescue

    function test_Finalize_OnlyOwner_OnlySeeded_OnlyOnce() public {
        (uint256 id,) = _live();
        vm.expectRevert(DuckReliquify.WrongStatus.selector); // Live
        reliquify.finalizeMigration(id);
        _seed(id);
        vm.prank(leader); vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, leader));
        reliquify.finalizeMigration(id);
        vm.expectRevert(DuckReliquify.MigrationNotFound.selector);
        reliquify.finalizeMigration(99);
        vm.expectEmit(true, true, false, true, address(reliquify));
        emit DuckReliquify.MigrationFinalized(id, 4e7, address(this));
        reliquify.finalizeMigration(id);
        assertTrue(reliquify.finalized(id));
        vm.expectRevert(DuckReliquify.MigrationEnded.selector);
        reliquify.finalizeMigration(id);
    }

    function test_Finalize_EndsDepositsAndEdits_ButClaimsStayOpen() public {
        (uint256 id, address newToken) = _live();
        _seed(id);
        reliquify.finalizeMigration(id);

        vm.startPrank(holder3);
        IERC20Edit(OLD_TOKEN).approve(address(reliquify), H3);
        vm.expectRevert(DuckReliquify.MigrationEnded.selector);
        reliquify.depositPostSeed(id, 1e6, 0, 0);
        vm.stopPrank();
        (address[] memory a, uint256[] memory c) = _move();
        vm.expectRevert(DuckReliquify.MigrationEnded.selector);
        reliquify.adminAdjustAllocations(id, a, c);

        // wallets that deposited before the seed still claim what they are owed
        assertEq(reliquify.pendingClaim(id, holder1), H1);
        vm.prank(holder1); reliquify.claim(id);
        assertEq(IERC20Edit(newToken).balanceOf(holder1), H1);
    }

    function test_Rescue_OnlyAfterFinalize_OnlyTheReserve_OnlyOwner() public {
        (uint256 id, address newToken) = _live();
        _seed(id);
        vm.expectRevert(DuckReliquify.MigrationNotEnded.selector);
        reliquify.rescueReserve(id, treasury, 1);
        reliquify.finalizeMigration(id);

        vm.prank(leader); vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, leader));
        reliquify.rescueReserve(id, treasury, 1);
        vm.expectRevert(DuckReliquify.ZeroAddress.selector);
        reliquify.rescueReserve(id, address(0), 1);
        vm.expectRevert(DuckReliquify.ZeroAmount.selector);
        reliquify.rescueReserve(id, treasury, 0);
        vm.expectRevert(DuckReliquify.RescueExceedsSurplus.selector);
        reliquify.rescueReserve(id, treasury, 4e7 + 1);

        uint256 contractBefore = IERC20Edit(newToken).balanceOf(address(reliquify));
        reliquify.rescueReserve(id, treasury, 1e7);
        assertEq(IERC20Edit(newToken).balanceOf(treasury), 1e7);
        assertEq(IERC20Edit(newToken).balanceOf(address(reliquify)), contractBefore - 1e7);
        (,,,,, uint256 reserved,) = reliquify.getMigration(id);
        assertEq(reserved, 3e7);
        reliquify.rescueReserve(id, treasury, 3e7); // the rest
        vm.expectRevert(DuckReliquify.RescueExceedsSurplus.selector);
        reliquify.rescueReserve(id, treasury, 1);
    }

    // Rescuing the whole reserve must leave every pre-seed depositor able to claim in full.
    function test_Rescue_NeverTouchesWhatDepositorsAreOwed() public {
        (uint256 id, address newToken) = _live();
        _seed(id);
        reliquify.finalizeMigration(id);
        reliquify.rescueReserve(id, treasury, 4e7); // the entire reserve
        (,,,,, uint256 reserved,) = reliquify.getMigration(id);
        assertEq(reserved, 0);
        assertGe(IERC20Edit(newToken).balanceOf(address(reliquify)), H1 + H2, "still holds exactly what depositors are owed");
        vm.prank(holder1); reliquify.claim(id);
        vm.prank(holder2); reliquify.claim(id);
        assertEq(IERC20Edit(newToken).balanceOf(holder1), H1);
        assertEq(IERC20Edit(newToken).balanceOf(holder2), H2);
    }

    function test_Rescue_AfterAdminLoweredAllocations_TheSurplusIsWhatIsLeftToTake() public {
        (uint256 id, address newToken) = _live();
        _seed(id);
        (address[] memory a, uint256[] memory c) = _two(holder3, 1e7, newcomer1, 0);
        reliquify.adminAdjustAllocations(id, a, c); // 3e7 of the reserve is no longer allocated to anyone
        (,, uint256 sur) = _undeposited(id);
        assertEq(sur, 3e7);
        reliquify.finalizeMigration(id);
        reliquify.rescueReserve(id, treasury, 4e7);
        assertEq(IERC20Edit(newToken).balanceOf(treasury), 4e7);
    }

    // ================================================================================================ fuzz against an independent oracle

    /// forge-config: default.fuzz.runs = 48
    function testFuzz_ProposalIsAcceptedExactlyWhenTheReserveRuleHolds(uint32[5] memory capSeeds, uint8[3] memory depPct) public {
        (uint256 id,) = _live();
        address[5] memory who = [holder1, holder2, holder3, newcomer1, newcomer2];
        uint256[3] memory cap = [H1, H2, H3];
        uint256[5] memory dep;
        for (uint256 i; i < 3; ++i) {
            dep[i] = cap[i] * (uint256(depPct[i]) % 101) / 100;
            if (dep[i] > 0) _deposit(id, who[i], dep[i]);
        }
        uint256[5] memory nc;
        uint256 total;
        bool ok = true;
        for (uint256 i; i < 5; ++i) {
            nc[i] = uint256(capSeeds[i]) % 6e7;
            total += nc[i];
            if (nc[i] < dep[i]) ok = false;
        }
        // the independent statement of the rule: nothing above what was deposited is removed, the total is positive,
        // and (what is still to be deposited) = total - deposited <= reserved = 1e8 - deposited
        if (total == 0 || total > 1e8) ok = false;

        address[] memory a = new address[](5); uint256[] memory c = new uint256[](5);
        for (uint256 i; i < 5; ++i) { a[i] = who[i]; c[i] = nc[i]; }
        (a, c) = _sorted(a, c);
        vm.prank(leader);
        if (ok) {
            reliquify.proposeAllocationEdit(id, a, c);
            _approveAndWait(id);
            vm.prank(leader); reliquify.applyAllocationEdit(id, a, c);
            (,,, uint256 eligible, uint256 totalDep, uint256 reserved,) = reliquify.getMigration(id);
            assertEq(eligible, total, "eligibleSupply is the sum of the caps");
            assertLe(eligible - totalDep, reserved, "the rule holds after the edit");
            uint256 sum;
            for (uint256 i; i < 5; ++i) { sum += reliquify.eligibleBalance(id, who[i]); assertGe(reliquify.eligibleBalance(id, who[i]), reliquify.deposited(id, who[i])); }
            assertEq(sum, eligible, "the per-wallet caps add up to eligibleSupply");
        } else {
            (bool success,) = address(reliquify).call(abi.encodeCall(DuckReliquify.proposeAllocationEdit, (id, a, c)));
            assertFalse(success, "the contract must reject exactly what the oracle rejects");
            assertFalse(reliquify.paused(id), "a rejected proposal pauses nothing");
        }
    }
}
