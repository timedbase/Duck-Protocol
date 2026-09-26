// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Proves the exact property that made Multicall3 unsafe as an approval target does NOT hold here:
// an attacker who is not the approver can never trigger a pull of the approver's tokens, no matter
// what they pass as arguments -- because the pull inside executeSwap is hardcoded to msg.sender, not
// a parameter. This is a direct regression test for a real incident (a bot drained live Multicall3
// approvals on Arc within one block of being granted) -- see Liquifier.sol's header comment.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Liquifier} from "duck-liquifier/Liquifier.sol";
import {MockERC20} from "./utils/MockERC20.sol";

// A trivial stand-in for a venue router: pulls `amountIn` of `tokenIn` from its caller (exactly how
// every real Uniswap router behaves -- pulls from msg.sender, never an arbitrary address) and mints
// `amountOut` of `tokenOut` to `recipient`. Good enough to prove Liquifier's own access control
// without needing a real fork for this specific property.
contract MockRouter {
    function swap(MockERC20 tokenIn, uint256 amountIn, MockERC20 tokenOut, uint256 amountOut, address recipient) external payable {
        if (amountIn > 0) tokenIn.transferFrom(msg.sender, address(this), amountIn);
        if (amountOut > 0) tokenOut.mint(recipient, amountOut);
    }
}

contract LiquifierTest is Test {
    Liquifier liquifier;
    MockERC20 sellToken;
    MockERC20 buyToken;
    MockRouter router;

    address owner = address(0xA11CE);
    address treasury = address(0x7EA5);
    address victim = address(0xB0B);
    address attacker = address(0xE31);

    function setUp() public {
        Liquifier impl = new Liquifier();
        bytes memory initData = abi.encodeCall(Liquifier.initialize, (owner, treasury, 50, address(0xdead))); // 0.5% fee, dummy permit2
        liquifier = Liquifier(payable(address(new ERC1967Proxy(address(impl), initData))));

        sellToken = new MockERC20();
        buyToken = new MockERC20();
        router = new MockRouter();

        vm.prank(owner);
        liquifier.setAllowedTarget(address(router), true);

        sellToken.mint(victim, 1_000e18);
        vm.prank(victim);
        sellToken.approve(address(liquifier), 100e18);
    }

    // The core regression: attacker calls executeSwap with sellToken=victim's token and a real
    // approved amount, but as themselves -- the pull can only ever draw from attacker's OWN
    // (nonexistent) allowance, never victim's, because msg.sender is what's pulled from.
    function test_attackerCannotDrainVictimsApproval() public {
        Liquifier.Approval[] memory approvals = new Liquifier.Approval[](1);
        approvals[0] = Liquifier.Approval({ viaPermit2: false, spender: address(router), amount: 100e18, expiration: 0 });
        bytes memory swapCalldata = abi.encodeCall(MockRouter.swap, (sellToken, 100e18, buyToken, 100e18, attacker));

        vm.prank(attacker);
        vm.expectRevert(); // MockERC20 has no allowance for attacker -> underflow revert on transferFrom
        liquifier.executeSwap(address(sellToken), 100e18, approvals, address(router), swapCalldata, 0);

        // Victim's approval is untouched -- nothing was ever pulled.
        assertEq(sellToken.allowance(victim, address(liquifier)), 100e18);
        assertEq(sellToken.balanceOf(victim), 1_000e18);
    }

    // The legitimate path: victim calls it themselves, gets charged the fee, and receives the swap output.
    function test_victimCanSwapTheirOwnApproval() public {
        Liquifier.Approval[] memory approvals = new Liquifier.Approval[](1);
        approvals[0] = Liquifier.Approval({ viaPermit2: false, spender: address(router), amount: 99.5e18, expiration: 0 });
        bytes memory swapCalldata = abi.encodeCall(MockRouter.swap, (sellToken, 99.5e18, buyToken, 50e18, victim));

        vm.prank(victim);
        uint256 fee = liquifier.executeSwap(address(sellToken), 100e18, approvals, address(router), swapCalldata, 0);

        assertEq(fee, 0.5e18); // 50 bps of 100e18
        assertEq(sellToken.balanceOf(treasury), 0.5e18);
        assertEq(sellToken.balanceOf(victim), 900e18); // 1000 - 100 pulled
        assertEq(buyToken.balanceOf(victim), 50e18);
        assertEq(sellToken.allowance(victim, address(liquifier)), 0); // fully consumed, nothing left to exploit later
    }

    // A target that isn't on the allowlist is rejected outright, whether it's the final swap call...
    function test_rejectsNonAllowlistedSwapTarget() public {
        address rogueRouter = address(new MockRouter());
        Liquifier.Approval[] memory approvals = new Liquifier.Approval[](0);
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(Liquifier.TargetNotAllowed.selector, rogueRouter));
        liquifier.executeSwap(address(sellToken), 0, approvals, rogueRouter, "", 0);
    }

    // ...or an approval spender -- closes the "approve some other address on whatever this contract
    // happens to be holding" edge case even though real trades never need a non-allowlisted spender.
    function test_rejectsNonAllowlistedApprovalSpender() public {
        address rogueSpender = address(0xBAD);
        Liquifier.Approval[] memory approvals = new Liquifier.Approval[](1);
        approvals[0] = Liquifier.Approval({ viaPermit2: false, spender: rogueSpender, amount: 1, expiration: 0 });
        vm.prank(victim);
        vm.expectRevert(abi.encodeWithSelector(Liquifier.TargetNotAllowed.selector, rogueSpender));
        liquifier.executeSwap(address(sellToken), 0, approvals, address(router), "", 0);
    }

    function test_nativeSellPaysFeeAndForwardsRemainder() public {
        vm.deal(victim, 10 ether);
        Liquifier.Approval[] memory approvals = new Liquifier.Approval[](0);
        // amountIn=0/amountOut=0 keeps this a no-op transferFrom/mint -- only the fee split and the
        // native value actually reaching the router are under test here, not a real swap outcome.
        bytes memory swapCalldata = abi.encodeCall(MockRouter.swap, (sellToken, 0, buyToken, 0, victim));

        vm.prank(victim);
        uint256 fee = liquifier.executeSwap{value: 1 ether}(address(0), 1 ether, approvals, address(router), swapCalldata, 0.995 ether);

        assertEq(fee, 0.005 ether);
        assertEq(treasury.balance, 0.005 ether);
        assertEq(address(router).balance, 0.995 ether);
    }
}
