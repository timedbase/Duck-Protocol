// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {UpgradeReliquifyAllocationEdit} from "../script/UpgradeReliquifyAllocationEdit.s.sol";

// Runs the upgrade script against the live Arc Reliquify proxy: owner, fee, routes wiring and the (empty) migration list
// survive, the new state starts empty, and a real migration can be proposed and edited afterwards.
contract UpgradeReliquifyAllocationEditArcForkTest is Test {
    address constant PROXY = 0xf7F65C4e96E8D2f4b960E1d7837Cf3c4520412bA;
    address constant OWNER = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;
    bytes32 constant IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function test_Upgrade() public {
        vm.createSelectFork(vm.envString("ARC_RPC_URL"));
        DuckReliquify r = DuckReliquify(payable(PROXY));
        address owner0 = r.owner(); uint256 fee0 = r.reliquifyFee(); uint256 n0 = r.migrationCount();
        address hook0 = r.v4Hook(); address pw0 = r.platformWallet(); address vf0 = r.vaultFactory();

        address impl = new UpgradeReliquifyAllocationEdit().upgradeAs(OWNER);
        assertEq(address(uint160(uint256(vm.load(PROXY, IMPL_SLOT)))), impl);
        assertEq(r.owner(), owner0); assertEq(r.reliquifyFee(), fee0); assertEq(r.migrationCount(), n0);
        assertEq(r.v4Hook(), hook0); assertEq(r.platformWallet(), pw0); assertEq(r.vaultFactory(), vf0);
        assertFalse(r.finalized(0));
        (bytes32 h,,,,,) = r.pendingEdit(0);
        assertEq(h, bytes32(0));
    }
}
