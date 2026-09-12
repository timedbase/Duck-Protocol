// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {PoolKey, SwapParams} from "duck-lib/LaunchRouting.sol";

contract MockStateView {
    mapping(bytes32 => int24) public tickOf;
    bool public shouldRevert;

    function setTick(bytes32 poolId, int24 tick) external {
        tickOf[poolId] = tick;
    }

    function setShouldRevert(bool v) external {
        shouldRevert = v;
    }

    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        if (shouldRevert) revert("mock revert");
        return (0, tickOf[poolId], 0, 0);
    }
}

contract DuckHookOracleTest is Test {
    DuckHookV4 hook;
    MockStateView stateView;
    address poolManager = makeAddr("poolManager");
    address launcher = makeAddr("launcher");
    address token = makeAddr("token");
    address quote = makeAddr("quote");
    bytes32 poolId;
    PoolKey key;

    function setUp() public {
        hook = DuckHookV4(payable(_deployHook(poolManager)));
        stateView = new MockStateView();
        hook.setStateView(address(stateView));
        hook.addLauncher(launcher);

        bool tokenIsC0 = token < quote;
        key = PoolKey({
            currency0: tokenIsC0 ? token : quote,
            currency1: tokenIsC0 ? quote : token,
            fee: 10_000,
            tickSpacing: 200,
            hooks: address(hook)
        });
        poolId = keccak256(abi.encode(key));

        vm.prank(launcher);
        hook.registerPool(key, token, address(this), 0, 10_000, 0, 0);
    }

    function _swap(int24 tick, int256 amount0, int256 amount1) internal {
        stateView.setTick(poolId, tick);
        int256 delta = (amount0 << 128) | (amount1 & ((int256(1) << 128) - 1));
        vm.prank(poolManager);
        hook.afterSwap(address(0), key, SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}), delta, "");
    }

    function test_FirstSwapSeedsObservation() public {
        _swap(100, -1 ether, 1 ether);
        (int56 cumulative, uint32 lastTs, int24 lastTick, uint16 index, uint16 count) = hook.oracleMeta(poolId);
        assertEq(count, 1);
        assertEq(lastTick, 100);
        assertEq(lastTs, uint32(block.timestamp));
        assertEq(cumulative, 0);
        assertEq(index, 0);
    }

    function test_ObserveConstantTickMatchesExactly() public {

        vm.warp(1_000);
        _swap(500, -1 ether, 1 ether);

        vm.warp(1_400);
        _swap(500, -1 ether, 1 ether);

        vm.warp(1_800);
        _swap(500, -1 ether, 1 ether);

        vm.warp(1_900);

        (int24 avgTick, bool valid) = hook.observe(poolId, 500);
        assertTrue(valid);
        assertEq(avgTick, 500, "a constant tick must average to itself exactly");
    }

    function test_ObserveWeightsByTimeWhenTickChanges() public {

        vm.warp(1_000);
        _swap(0, -1 ether, 1 ether);
        vm.warp(1_300);
        _swap(1000, -1 ether, 1 ether);
        vm.warp(1_600);
        _swap(1000, -1 ether, 1 ether);
        vm.warp(1_700);

        (int24 avgTick, bool valid) = hook.observe(poolId, 600);
        assertTrue(valid);
        assertEq(avgTick, 571);
    }

    // Regression test for a fresh-audit finding: observe() used to silently clamp to whatever
    // short real history existed and still report `valid = true` when asked for a longer window
    // than the pool had actually been tracked for -- letting a brand-new, easily-manipulated pool's
    // price masquerade as a genuine long-window TWAP. Confirmed the fix here in isolation (no
    // DuckVault minPoolAge gate involved) rather than only via the vault's full borrow() flow.
    function test_ObserveReturnsInvalidWhenRequestedWindowExceedsTrackedHistory() public {
        vm.warp(1_000);
        _swap(100, -1 ether, 1 ether); // first-ever observation for this pool, seeded at ts=1000

        vm.warp(1_100); // only 100 seconds of real history exist so far

        // A 600-second window reaches back to ts=500 -- well before tracking began (ts=1000).
        (int24 avgTick, bool valid) = hook.observe(poolId, 600);
        assertFalse(valid, "requesting more history than has actually been tracked must report invalid");
        assertEq(avgTick, 0);
    }

    // Sanity check that the fix above doesn't over-trigger: a window that fits exactly within the
    // tracked history (even if it's the very first observation) must still report valid.
    function test_ObserveStillValidWhenWindowFitsExactlyWithinHistory() public {
        vm.warp(1_000);
        _swap(100, -1 ether, 1 ether);

        vm.warp(1_600);
        (int24 avgTick, bool valid) = hook.observe(poolId, 600); // targetTs = 1000, exactly the seed
        assertTrue(valid);
        assertEq(avgTick, 100);
    }

    function test_DegradesGracefullyWhenStateViewReverts() public {
        vm.warp(1_000);
        _swap(100, -1 ether, 1 ether);
        stateView.setShouldRevert(true);

        vm.warp(1_400);

        _swap(999, -1 ether, 1 ether);

        (, , int24 lastTick, , uint16 count) = hook.oracleMeta(poolId);
        assertEq(count, 1, "a failed read must not advance the ring");
        assertEq(lastTick, 100, "a failed read must not overwrite the last known tick");
    }

    function test_OraclePausedSkipsUpdates() public {
        hook.setOraclePaused(true);
        _swap(100, -1 ether, 1 ether);
        (, uint32 lastTs, , , uint16 count) = hook.oracleMeta(poolId);
        assertEq(count, 0);
        assertEq(lastTs, 0);
    }

    function test_OracleDisabledPerPoolSkipsUpdates() public {
        hook.setOracleDisabled(poolId, true);
        _swap(100, -1 ether, 1 ether);
        (, , , , uint16 count) = hook.oracleMeta(poolId);
        assertEq(count, 0);
    }

    // Raw create (not a typed `new DuckHookV4(...)` expression) -- DuckHookV4 is large enough that
    // embedding it via a typed new-expression inside a test's setUp() can hit stack-too-deep even
    // under via-IR, same fix as DuckHookFactory.deploy in the real deploy script.
    function _deployHook(address poolManager_) internal returns (address hook_) {
        bytes memory initCode = abi.encodePacked(type(DuckHookV4).creationCode, abi.encode(poolManager_));
        assembly {
            hook_ := create(0, add(initCode, 0x20), mload(initCode))
        }
        require(hook_ != address(0), "hook deploy failed");
    }
}
