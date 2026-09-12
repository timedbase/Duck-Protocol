// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {DuckClones} from "duck-lib/DuckClones.sol";

contract DuckTokenTest is Test {
    DuckToken token;
    uint256 ownerPk = 0xA11CE;
    address ownerAddr;
    address spender = makeAddr("spender");
    address recipient = makeAddr("recipient");

    function setUp() public {
        ownerAddr = vm.addr(ownerPk);

        DuckToken tokenImpl = new DuckToken(address(0));
        address tokenClone = DuckClones.clone(address(tokenImpl), address(this), bytes32(0));
        token = DuckToken(payable(tokenClone));

        token.initToken("Duck", "DUCK", 1_000_000e18, false, "");
        token.transfer(ownerAddr, 1_000e18);
    }

    function _signPermit(uint256 pk, address owner_, address spender_, uint256 value, uint256 deadline)
        internal view returns (uint8 v, bytes32 r, bytes32 s)
    {
        bytes32 PERMIT_TYPEHASH = keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, owner_, spender_, value, token.nonces(owner_), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (v, r, s) = vm.sign(pk, digest);
    }

    function test_PermitApprovesViaValidSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerPk, ownerAddr, spender, 500e18, deadline);

        token.permit(ownerAddr, spender, 500e18, deadline, v, r, s);

        assertEq(token.allowance(ownerAddr, spender), 500e18);
        assertEq(token.nonces(ownerAddr), 1, "nonce must advance after a consumed permit");
    }

    function test_PermitRejectsReplayedSignature() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerPk, ownerAddr, spender, 500e18, deadline);
        token.permit(ownerAddr, spender, 500e18, deadline, v, r, s);

        vm.expectRevert(DuckToken.InvalidSignature.selector);
        token.permit(ownerAddr, spender, 500e18, deadline, v, r, s);
    }

    function test_PermitRejectsExpiredDeadline() public {

        uint256 deadline = 1_000;
        vm.warp(deadline);
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(ownerPk, ownerAddr, spender, 500e18, deadline);
        vm.warp(1_001);

        vm.expectRevert(DuckToken.PermitExpired.selector);
        token.permit(ownerAddr, spender, 500e18, deadline, v, r, s);
    }

    function test_PermitRejectsWrongSigner() public {
        uint256 wrongPk = 0xB0B;
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = _signPermit(wrongPk, ownerAddr, spender, 500e18, deadline);

        vm.expectRevert(DuckToken.InvalidSignature.selector);
        token.permit(ownerAddr, spender, 500e18, deadline, v, r, s);
    }

    function test_DomainSeparatorMatchesManualComputation() public view {
        bytes32 expected = keccak256(abi.encode(
            keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
            keccak256(bytes("Duck")),
            keccak256("1"),
            block.chainid,
            address(token)
        ));
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    function test_CheckpointsTrackMintAndTransfer() public {

        vm.roll(block.number + 1);
        assertEq(token.getPastVotes(address(this), block.number - 1), 1_000_000e18 - 1_000e18);
        assertEq(token.getPastVotes(ownerAddr, block.number - 1), 1_000e18);
        assertEq(token.getPastTotalSupply(block.number - 1), 1_000_000e18);
    }

    function test_CheckpointReflectsBalanceAtHistoricalBlock() public {

        uint256 blockBeforeTransfer = 100;
        vm.roll(blockBeforeTransfer);

        vm.roll(101);
        vm.prank(ownerAddr);
        token.transfer(recipient, 400e18);

        vm.roll(102);

        assertEq(token.getPastVotes(ownerAddr, blockBeforeTransfer), 1_000e18, "past snapshot must be unaffected by the later transfer");
        assertEq(token.getVotes(ownerAddr), 600e18, "current votes must reflect the transfer");
        assertEq(token.getVotes(recipient), 400e18);
    }

    function test_DelegationIsDisabled() public {
        assertEq(token.delegates(ownerAddr), ownerAddr, "every account must be its own permanent delegate");

        vm.expectRevert(DuckToken.DelegationDisabled.selector);
        token.delegate(spender);

        vm.expectRevert(DuckToken.DelegationDisabled.selector);
        token.delegateBySig(spender, 0, block.timestamp + 1 hours, 0, bytes32(0), bytes32(0));
    }

    function test_HolderCountTracksMintAndFullTransfer() public {

        assertEq(token.holderCount(), 2);

        vm.prank(ownerAddr);
        token.transfer(recipient, 1_000e18);
        assertEq(token.balanceOf(ownerAddr), 0);
        assertEq(token.holderCount(), 2, "ownerAddr dropping out and recipient appearing must net to the same count");
    }

    function test_HolderCountUnaffectedBySelfTransfer() public {
        uint256 before = token.holderCount();

        vm.prank(ownerAddr);
        token.transfer(ownerAddr, 1_000e18);
        assertEq(token.balanceOf(ownerAddr), 1_000e18, "self-transfer must not change the balance");
        assertEq(token.holderCount(), before, "a full-balance self-transfer must never change holder count");

        vm.prank(ownerAddr);
        token.transfer(ownerAddr, 1);
        assertEq(token.holderCount(), before);
    }

    function test_HolderCountNeverCountsDeadAddress() public {
        address DEAD = 0x000000000000000000000000000000000000dEaD;
        uint256 before = token.holderCount();

        vm.prank(ownerAddr);
        token.transfer(DEAD, 1_000e18);

        assertEq(token.balanceOf(DEAD), 1_000e18, "the transfer itself must still succeed and land the balance");
        assertEq(token.holderCount(), before - 1, "ownerAddr dropping out must decrement, but DEAD appearing must NOT increment");
    }

    function test_GetPastHolderCountRevertsOnCurrentOrFutureBlock() public {
        vm.expectRevert(abi.encodeWithSelector(DuckToken.FutureLookup.selector, block.number, block.number));
        token.getPastHolderCount(block.number);

        vm.expectRevert(abi.encodeWithSelector(DuckToken.FutureLookup.selector, block.number + 1, block.number));
        token.getPastHolderCount(block.number + 1);
    }

    function test_GetPastHolderCountReflectsHistoricalSnapshot() public {

        uint256 blockBeforeNewHolder = 1000;
        vm.roll(blockBeforeNewHolder);

        vm.roll(1001);
        vm.prank(ownerAddr);
        token.transfer(recipient, 100e18);

        vm.roll(1002);

        assertEq(token.getPastHolderCount(blockBeforeNewHolder), 2, "must reflect the count BEFORE recipient appeared");
        assertEq(token.holderCount(), 3, "current count must include recipient");
    }
}
