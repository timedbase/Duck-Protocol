// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {DuckReliquifyArcForkTest} from "./DuckReliquify.fork.t.sol";

// The allocation-edit code is byte-identical to the shared tree's (checked by diffing the two sources), where it is tested
// in full, including after the seed, against the real Robinhood stack. Arc has no proven sell route yet, so seedPool cannot
// run here: this covers the pre-seed flow (propose -> pause -> review -> 24h -> apply), the rule, and the guards that keep
// the post-seed functions closed to a migration that is not seeded.
contract DuckReliquifyEditArcForkTest is DuckReliquifyArcForkTest {
    error OwnableUnauthorizedAccount(address account);

    address newcomer = makeAddr("dra-newcomer");
    uint256 constant CAP = 3_000e18;

    function _live() internal returns (uint256 id) {
        vm.prank(leader);
        id = reliquify.proposeMigration(address(oldToken), 200, 10_000, 0, 0);
        address[] memory a = new address[](2); a[0] = holder1; a[1] = holder2;
        uint256[] memory b = new uint256[](2); b[0] = CAP; b[1] = CAP;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, a, b);
        reliquify.finalizeSnapshot(id);
        vm.stopPrank();
        reliquify.approveMigration(id, "Edit Arc", "EDA", "ipfs://test");
    }

    // holder2 gives 1000 of its allocation to newcomer: net zero, sorted ascending
    function _move() internal view returns (address[] memory a, uint256[] memory c) {
        a = new address[](2); c = new uint256[](2);
        uint256 lowered = CAP - 1_000e18;
        uint256 given = 1_000e18;
        address x = holder2 < newcomer ? holder2 : newcomer;
        address y = holder2 < newcomer ? newcomer : holder2;
        uint256 cx = x == holder2 ? lowered : given;
        uint256 cy = y == holder2 ? lowered : given;
        a[0] = x; c[0] = cx; a[1] = y; c[1] = cy;
    }

    function _deposit(uint256 id, address who, uint256 amt) internal {
        vm.startPrank(who);
        oldToken.approve(address(reliquify), amt);
        reliquify.depositPreSeed(id, amt);
        vm.stopPrank();
    }

    function test_Edit_FullFlow_ProposePausesReviewDelayApply() public {
        uint256 id = _live();
        (address[] memory a, uint256[] memory c) = _move();
        vm.prank(leader); reliquify.proposeAllocationEdit(id, a, c);
        assertTrue(reliquify.paused(id));
        vm.prank(holder1); vm.expectRevert(DuckReliquify.Paused.selector);
        reliquify.depositPreSeed(id, 1);

        vm.warp(block.timestamp + 24 hours);
        vm.prank(leader); vm.expectRevert(DuckReliquify.EditNotApproved.selector);
        reliquify.applyAllocationEdit(id, a, c);
        reliquify.approveAllocationEdit(id);
        vm.prank(leader); reliquify.applyAllocationEdit(id, a, c);
        assertFalse(reliquify.paused(id));
        assertEq(reliquify.eligibleBalance(id, newcomer), 1_000e18);
        assertEq(reliquify.eligibleBalance(id, holder2), CAP - 1_000e18);
        (,,, uint256 eligible,,,) = reliquify.getMigration(id);
        assertEq(eligible, 2 * CAP);

        oldToken.mint(newcomer, 1_000e18);
        _deposit(id, newcomer, 1_000e18);
        vm.startPrank(newcomer);
        vm.expectRevert(DuckReliquify.CapExceeded.selector);
        reliquify.depositPreSeed(id, 1);
        vm.stopPrank();
    }

    function test_Edit_RejectResumes_DelayEnforced_ExpiryClears() public {
        uint256 id = _live();
        (address[] memory a, uint256[] memory c) = _move();
        vm.prank(leader); reliquify.proposeAllocationEdit(id, a, c);
        reliquify.rejectAllocationEdit(id);
        assertFalse(reliquify.paused(id));

        vm.prank(leader); reliquify.proposeAllocationEdit(id, a, c);
        reliquify.approveAllocationEdit(id);
        vm.warp(block.timestamp + 24 hours - 1);
        vm.prank(leader); vm.expectRevert(DuckReliquify.EditNotReady.selector);
        reliquify.applyAllocationEdit(id, a, c);
        vm.warp(block.timestamp + 7 days + 1);
        vm.prank(leader); vm.expectRevert(DuckReliquify.EditExpired.selector);
        reliquify.applyAllocationEdit(id, a, c);
        reliquify.clearExpiredEdit(id);
        assertFalse(reliquify.paused(id));
    }

    function test_Edit_Rule_AndRoles() public {
        uint256 id = _live();
        _deposit(id, holder2, 2_000e18);
        (address[] memory a, uint256[] memory c) = _move(); // holder2 -> 2000e18 = what it deposited: allowed
        vm.prank(leader); reliquify.proposeAllocationEdit(id, a, c);
        reliquify.rejectAllocationEdit(id);
        // below the deposit
        (a, c) = _move(); for (uint256 i; i < 2; ++i) if (a[i] == holder2) c[i] = 1_999e18; else c[i] = 1_001e18;
        vm.prank(leader); vm.expectRevert(abi.encodeWithSelector(DuckReliquify.BelowDeposited.selector, holder2, 2_000e18));
        reliquify.proposeAllocationEdit(id, a, c);
        // more than what is reserved
        (a, c) = _move(); for (uint256 i; i < 2; ++i) if (a[i] == newcomer) c[i] = 1_000e18 + 1;
        vm.prank(leader); vm.expectRevert(abi.encodeWithSelector(DuckReliquify.ExceedsReserved.selector, 6_000e18 - 2_000e18 + 1, 4_000e18));
        reliquify.proposeAllocationEdit(id, a, c);
        // roles
        (a, c) = _move();
        vm.prank(holder1); vm.expectRevert(DuckReliquify.NotLeader.selector);
        reliquify.proposeAllocationEdit(id, a, c);
        // not seeded: the post-seed functions are closed
        vm.expectRevert(DuckReliquify.WrongStatus.selector);
        reliquify.adminAdjustAllocations(id, a, c);
        vm.expectRevert(DuckReliquify.WrongStatus.selector);
        reliquify.finalizeMigration(id);
        vm.prank(leader); vm.expectRevert(abi.encodeWithSelector(OwnableUnauthorizedAccount.selector, leader));
        reliquify.approveAllocationEdit(id);
        vm.expectRevert(DuckReliquify.MigrationNotEnded.selector);
        reliquify.rescueReserve(id, address(this), 1);
    }
}
