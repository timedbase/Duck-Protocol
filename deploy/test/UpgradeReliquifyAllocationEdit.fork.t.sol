// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {UpgradeReliquifyAllocationEdit} from "../script/UpgradeReliquifyAllocationEdit.s.sol";

interface IERC20UAE { function balanceOf(address) external view returns (uint256); }

// Runs the upgrade script against the live Reliquify proxy and checks that everything already on chain survives, then
// uses the new admin functions on the real FEG migration (#0): edits are bounded by what is left in the reserve, finalize
// ends it, and rescue moves only the reserve, never what pre-seed depositors are owed.
contract UpgradeReliquifyAllocationEditForkTest is Test {
    address constant PROXY = 0xD4B52e1b491B757e04f592c1f995212f93a1ec2D;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    DuckReliquify r = DuckReliquify(payable(PROXY));

    struct Snap {
        address owner; uint256 fee; uint256 count; address leader; address oldToken; address newToken;
        uint256 eligible; uint256 deposited; uint256 reserved; uint8 status; uint256 newBal;
    }

    function _snap(uint256 id) internal view returns (Snap memory s) {
        s.owner = r.owner(); s.fee = r.reliquifyFee(); s.count = r.migrationCount();
        (s.leader, s.oldToken, s.newToken, s.eligible, s.deposited, s.reserved,) = r.getMigration(id);
        (,,,,,, DuckReliquify.MigrationStatus st) = r.getMigration(id);
        s.status = uint8(st);
        s.newBal = IERC20UAE(s.newToken).balanceOf(PROXY);
    }

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
    }

    function test_UpgradeKeepsLiveStateAndAddsTheNewFlow() public {
        Snap memory a = _snap(0);
        assertEq(a.status, uint8(DuckReliquify.MigrationStatus.Seeded), "migration #0 is seeded");
        address holder = makeAddr("some-holder");

        UpgradeReliquifyAllocationEdit up = new UpgradeReliquifyAllocationEdit();
        address impl = up.upgradeAs(OWNER);
        assertEq(address(uint160(uint256(vm.load(PROXY, IMPL_SLOT)))), impl);

        Snap memory b = _snap(0);
        assertEq(b.owner, a.owner); assertEq(b.fee, a.fee); assertEq(b.count, a.count); assertEq(b.leader, a.leader);
        assertEq(b.oldToken, a.oldToken); assertEq(b.newToken, a.newToken); assertEq(b.eligible, a.eligible);
        assertEq(b.deposited, a.deposited); assertEq(b.reserved, a.reserved); assertEq(b.status, a.status); assertEq(b.newBal, a.newBal);
        assertFalse(r.finalized(0));
        (bytes32 h,,,,,) = r.pendingEdit(0);
        assertEq(h, bytes32(0));

        // A wallet that is not in the snapshot gets an allocation carved out of the unallocated part of the reserve, up to
        // exactly what is left, and not a token more.
        uint256 undeposited = b.eligible - b.deposited;
        uint256 surplus = b.reserved - undeposited;
        address[] memory acc = new address[](1); acc[0] = holder;
        uint256[] memory cap = new uint256[](1);
        cap[0] = surplus + 1;
        vm.startPrank(OWNER);
        vm.expectRevert(abi.encodeWithSelector(DuckReliquify.ExceedsReserved.selector, undeposited + surplus + 1, b.reserved));
        r.adminAdjustAllocations(0, acc, cap);
        cap[0] = surplus;
        if (surplus > 0) {
            r.adminAdjustAllocations(0, acc, cap);
            assertEq(r.eligibleBalance(0, holder), surplus);
        }

        // Finalize, then rescue everything left in the reserve.
        r.finalizeMigration(0);
        vm.expectRevert(DuckReliquify.MigrationEnded.selector);
        r.adminAdjustAllocations(0, acc, cap);
        (,,,,, uint256 reserved,) = r.getMigration(0);
        r.rescueReserve(0, OWNER, reserved);
        vm.stopPrank();

        (,,,, uint256 dep2, uint256 res2,) = r.getMigration(0);
        assertEq(res2, 0);
        assertEq(dep2, b.deposited);
        assertEq(IERC20UAE(b.newToken).balanceOf(OWNER) >= reserved, true);
        // what is still in the contract covers every unclaimed pre-seed deposit; nothing owed was rescued
        assertEq(IERC20UAE(b.newToken).balanceOf(PROXY), b.newBal - reserved);
    }
}
