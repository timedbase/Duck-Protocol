// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {DuckClones} from "duck-lib/DuckClones.sol";

// Isolated unit tests for DuckToken's holder-reward mechanics (time-weighted
// balance-seconds, 12h double-buffered distribution rounds, batched push
// payouts, DEAD/PoolManager exclusion, fixed MIN_HOLDING_BPS eligibility). Contract
// addresses are deliberately NOT excluded -- see test_ContractHolderIsEligible.
// Deploys DuckToken directly rather than through a full launch pipeline --
// mintManager ends up being this test contract itself (whoever calls
// initToken), which is exactly the trusted caller setRewardConfig expects,
// so no mock launcher is needed to exercise this in isolation.
contract DuckTokenRewardTest is Test {
    DuckToken token;
    address hook = makeAddr("hook");
    address poolManager = makeAddr("poolManager");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address DEAD = 0x000000000000000000000000000000000000dEaD;

    uint256 constant SUPPLY = 1_000_000e18;

    function setUp() public {
        DuckToken tokenImpl = new DuckToken(address(0));
        address tokenClone = DuckClones.clone(address(tokenImpl), address(this), bytes32(0));
        token = DuckToken(payable(tokenClone));
        token.initToken("Duck", "DUCK", SUPPLY, false, "");
        vm.deal(hook, 1_000 ether);
    }

    function _setRewardConfig() internal {
        token.setRewardConfig(hook, address(0), poolManager);
    }

    function _deposit(uint256 amount) internal {
        vm.prank(hook);
        token.depositHolderReward{value: amount}(amount);
    }

    // address(this) (mintManager) is itself reward-eligible now that contracts aren't excluded, and
    // it's left holding whatever the test didn't explicitly move elsewhere. Tests that want to isolate
    // a clean split among specific addresses drain that leftover to DEAD (already excluded) first.
    function _drainSelfDust() internal {
        uint256 rem = token.balanceOf(address(this));
        if (rem > 0) token.transfer(DEAD, rem);
    }

    // Lets this contract actually collect its own reward share (like any other contract holder must
    // be able to -- see test_ContractHolderIsEligible_ReceivesPayout) instead of forfeiting it.
    receive() external payable {}

    // ---------- setRewardConfig ----------

    function test_SetRewardConfig_RevertsForNonMintManager() public {
        vm.prank(alice);
        vm.expectRevert(DuckToken.NotOwner.selector);
        token.setRewardConfig(hook, address(0), poolManager);
    }

    function test_SetRewardConfig_RevertsOnSecondCall() public {
        _setRewardConfig();
        vm.expectRevert(DuckToken.RewardConfigAlreadySet.selector);
        _setRewardConfig();
    }

    function test_SetRewardConfig_StoresValuesAndStartsRound() public {
        _setRewardConfig();
        assertEq(token.rewardHook(), hook);
        assertEq(token.rewardCurrency(), address(0));
        assertEq(token.poolManagerAddr(), poolManager);
        assertEq(token.MIN_HOLDING_BPS(), 25, "fixed at 0.25% of total supply, not creator-configurable");
        assertEq(token.roundStart(), block.timestamp);
    }

    // ---------- depositHolderReward ----------

    function test_DepositHolderReward_RevertsForNonHook() public {
        _setRewardConfig();
        vm.expectRevert(DuckToken.NotRewardHook.selector);
        token.depositHolderReward{value: 1 ether}(1 ether);
    }

    function test_DepositHolderReward_AccruesRoundPool() public {
        _setRewardConfig();
        _deposit(1 ether);
        assertEq(token.roundPool(), 1 ether);
        _deposit(2 ether);
        assertEq(token.roundPool(), 3 ether);
    }

    // ---------- time-weighted holding ----------

    function test_TimeWeightedHolding_RewardsLongerHoldingProportionally() public {
        _setRewardConfig();
        uint256 t0 = block.timestamp;

        // Alice holds 10_000e18 (comfortably above MIN_HOLDING_BPS's fixed 0.25%-of-total-supply
        // floor, 2,500e18 here) for the entire 12h round.
        token.transfer(alice, 10_000e18);
        // Bob's future share is parked at DEAD (reward-excluded) until he "buys in" -- so it accrues
        // no weight while waiting there, instead of sitting in address(this) and quietly padding the
        // total with 4 hours of a third, untested party's holding.
        token.transfer(DEAD, 10_000e18);
        _drainSelfDust(); // remove address(this)'s remaining leftover so it doesn't dilute the split

        // 4h in (1/3 of the round), Bob starts holding the same balance -- only for the remaining 8h.
        vm.warp(t0 + 4 hours);
        vm.prank(DEAD);
        token.transfer(bob, 10_000e18);

        _deposit(10 ether);

        // Close the round and pay out. NOTE: computed off the *current* block.timestamp (already
        // t0+4h from the warp above), not off the stale `t0` local -- solc 0.8.36's via-ir optimizer
        // (this repo's required config; stack-too-deep otherwise) miscompiles a local that cached an
        // earlier block.timestamp read into re-reading the *current* timestamp after an intervening
        // vm.warp, so `t0 + 12 hours` here would silently evaluate using the already-warped value and
        // overshoot to t0+16h. This is a Foundry/vm.warp-only artifact (real chains can never observe
        // block.timestamp changing mid-transaction) -- confirmed with a minimal repro outside this
        // file, not a bug in DuckToken.sol itself.
        vm.warp(block.timestamp + 8 hours);
        token.processBatch();

        // Alice: 10_000e18 * 12h = 120,000e18*h weight. Bob: 10_000e18 * 8h = 80,000e18*h.
        // Total 200,000e18*h -> Alice gets 60%, Bob gets 40% of the 10 ether pool.
        assertApproxEqAbs(alice.balance, 6 ether, 0.001 ether, "alice held longer than bob at the same balance");
        assertApproxEqAbs(bob.balance, 4 ether, 0.001 ether);
        assertFalse(token.distributing(), "single-batch round must finish immediately");
    }

    // ---------- exclusions ----------

    function test_DeadAddressExcluded_FromRateAndPayout() public {
        _setRewardConfig();
        uint256 t0 = block.timestamp;
        uint256 selfBalanceBefore = address(this).balance; // Foundry gives test contracts a nonzero
            // default balance (type(uint96).max), so compare the increase, not the raw value.

        // Half the supply goes to DEAD, half to alice -- both for the whole round. address(this) keeps
        // 5000e18 (well above MIN_HOLDING_BPS's fixed floor, 0.25% of the 1,000,000e18 total supply =
        // 2,500e18) so it stays a real, eligible holder rather than incidentally falling below the
        // fixed minimum itself.
        token.transfer(DEAD, SUPPLY / 2);
        token.transfer(alice, SUPPLY / 2 - 5000e18);

        _deposit(10 ether);
        vm.warp(t0 + 12 hours);
        token.processBatch();

        assertEq(DEAD.balance, 0, "DEAD must never receive any payout");
        // Alice and this contract (address(this), acting as mintManager) are the only two real,
        // eligible holders remaining -- combined they should receive (approximately) the full pool,
        // since DEAD is unconditionally excluded from ever being a holder or accruing weight at all
        // (see _isExcludedFromRewards), regardless of how the fixed MIN_HOLDING_BPS floor is computed.
        // address(this) being a contract doesn't disqualify it -- only DEAD and the pool's own
        // reserves (PoolManager) are excluded.
        uint256 selfReward = address(this).balance - selfBalanceBefore;
        assertApproxEqAbs(alice.balance + selfReward, 10 ether, 0.01 ether,
            "excluding DEAD from ever accruing weight means real holders together get the full pool, not a DEAD-diluted fraction of it");
    }

    function test_PoolManagerAddressExcluded_FromRateAndPayout() public {
        _setRewardConfig();
        uint256 t0 = block.timestamp;
        uint256 selfBalanceBefore = address(this).balance;

        // address(this) keeps 5000e18 -- see test_DeadAddressExcluded_FromRateAndPayout for why.
        token.transfer(poolManager, SUPPLY / 2);
        token.transfer(alice, SUPPLY / 2 - 5000e18);

        _deposit(10 ether);
        vm.warp(t0 + 12 hours);
        token.processBatch();

        assertEq(poolManager.balance, 0, "the pool's own reserves must never receive a payout");
        uint256 selfReward = address(this).balance - selfBalanceBefore;
        assertApproxEqAbs(alice.balance + selfReward, 10 ether, 0.01 ether);
    }

    function test_ContractHolderIsEligible_ReceivesPayout() public {
        // Contract addresses are NOT excluded from rewards -- only DEAD and the pool's own reserves
        // (PoolManager) are. A holder being a contract (routers, vaults, LP wrappers, or just a plain
        // smart-contract wallet) must not disqualify it.
        _setRewardConfig();
        uint256 t0 = block.timestamp;
        uint256 selfBalanceBefore = address(this).balance;

        // address(this) keeps 5000e18 -- see test_DeadAddressExcluded_FromRateAndPayout for why (the
        // floor is a fixed 0.25% of the 1,000,000e18 total supply = 2,500e18, regardless of who holds
        // what).
        address mock = address(new MockContractHolder());
        token.transfer(mock, SUPPLY / 2);
        token.transfer(alice, SUPPLY / 2 - 5000e18);

        _deposit(10 ether);
        vm.warp(t0 + 12 hours);
        token.processBatch();

        assertGt(mock.balance, 0, "a contract holder must be paid like any other eligible holder");
        uint256 selfReward = address(this).balance - selfBalanceBefore;
        assertApproxEqAbs(mock.balance + alice.balance + selfReward, 10 ether, 0.01 ether);
    }

    // ---------- MIN_HOLDING_BPS eligibility ----------

    function test_MinHoldingBpsThreshold_SkipsSmallHolderAtPayoutTime() public {
        // Fixed at 0.25% of total supply -- not creator-configurable, see MIN_HOLDING_BPS.
        _setRewardConfig();
        uint256 t0 = block.timestamp;

        token.transfer(alice, SUPPLY / 2); // well above 1%
        token.transfer(bob, 1); // 1 wei -- nowhere near 1% of supply, but nonzero weight

        _deposit(10 ether);
        vm.warp(t0 + 12 hours);
        token.processBatch();

        assertEq(bob.balance, 0, "a holder below the minimum balance at payout time must be skipped");
        assertGt(alice.balance, 0, "the eligible holder must still be paid");
        assertLt(alice.balance + bob.balance, 10 ether,
            "bob's forfeited share must not be silently redistributed to anyone else");
    }

    // ---------- round timing ----------

    function test_DistributionRound_DoesNotCloseBeforeInterval() public {
        _setRewardConfig();
        uint256 t0 = block.timestamp;
        token.transfer(alice, 1000e18);
        _deposit(10 ether);

        vm.warp(t0 + 5 hours); // short of the 12h interval
        token.transfer(alice, 1); // plain activity -- not due yet

        assertFalse(token.distributing(), "round must not close before the full interval elapses");
        assertEq(alice.balance, 0, "no payout should have happened yet");
    }

    // ---------- ordinary transfers never drive distribution -- only an explicit processBatch() call does ----------

    function test_TransferAlone_NeverTriggersProcessBatch_EvenWhenDue() public {
        // processBatch is not wired into _transfer at all: an ordinary, unrelated wallet-to-wallet
        // transfer must never pay for advancing someone else's reward round, no matter how overdue
        // that round is. Only an explicit processBatch() call (manual, or DuckKeeper's scheduled one)
        // actually closes/advances a round -- see test_ManualProcessBatch_WorksWithoutAnyTransfer.
        _setRewardConfig();
        uint256 t0 = block.timestamp;
        token.transfer(alice, 1000e18);
        _deposit(10 ether);

        vm.warp(t0 + 12 hours + 1); // well past the interval -- a round is now due
        token.transfer(alice, 1);

        assertFalse(token.distributing(), "an ordinary transfer must never close or advance a round, due or not");
        assertEq(alice.balance, 0, "no payout should have happened from a plain transfer");
        assertEq(token.roundPool(), 10 ether, "the round must still be sitting there, unclosed, until someone explicitly calls processBatch()");
    }

    // ---------- a reentrant processBatch() attempt must never revert the outer processBatch() call ----------

    function test_ReentrantProcessBatchReentry_DoesNotRevertTheOuterCall() public {
        // A native payout's 30,000 gas cap (see processBatch) isn't enough headroom for a reentrant
        // processBatch() attempt -- that's the cap correctly doing its job (an unusually expensive
        // receiver simply forfeits its payment), not a way to reach this path. An ERC777-style quote
        // currency, which really could call a recipient hook on transfer, gives the ERC20 payout's
        // more generous 100,000 gas cap instead -- comfortably enough to actually exercise the
        // scenario this test cares about.
        MockHookedCurrency quote = new MockHookedCurrency();
        token.setRewardConfig(hook, address(quote), poolManager);
        uint256 t0 = block.timestamp;

        // Places the reentrant holder as the FIRST entry of the second batch, regardless of what
        // BATCH_SIZE is currently set to -- one full batch of filler holders, then the reentrant one.
        // Only the reentrant holder is funded above MIN_HOLDING_BPS -- the fixed 0.25% floor makes it
        // mathematically impossible for more than 400 holders to be simultaneously eligible (400 *
        // 0.25% = 100% of total supply), so at a large BATCH_SIZE the filler holders exist purely to
        // pad _holders past the batch boundary, exactly like a real token's long tail of small
        // holders that never clear the floor.
        uint256 batchSize = token.BATCH_SIZE();
        uint256 n = batchSize + 2;
        uint256 reentrantIndex = batchSize;
        ReentrantOnTokenReceivedHolder reentrant = new ReentrantOnTokenReceivedHolder(token, quote);
        address[] memory holders = new address[](n);
        for (uint256 i; i < n; ++i) {
            holders[i] = i == reentrantIndex ? address(reentrant) : address(uint160(uint256(keccak256(abi.encode("holder", i)))));
            token.transfer(holders[i], i == reentrantIndex ? 400_000e18 : 1);
        }
        _drainSelfDust();

        quote.mint(hook, 5.5e18);
        vm.startPrank(hook);
        quote.approve(address(token), 5.5e18);
        token.depositHolderReward(5.5e18);
        vm.stopPrank();

        vm.warp(t0 + 12 hours);

        token.processBatch(); // batch 1: indices [0, batchSize)
        assertTrue(token.distributing(), "must still be mid-payout, the reentrant holder not yet visited");

        // The reentrant holder's onTokensReceived() fires here (from the hooked currency's transfer()),
        // and its own direct token.processBatch() reentry attempt must hit the reentrancy guard and
        // revert -- caught by its own try/catch, so this outer call must NOT itself revert.
        token.processBatch(); // batch 2: starts at index batchSize -- must NOT revert

        assertFalse(token.distributing(), "round must finish once the second batch completes despite the reentrancy attempt");
        assertGt(quote.balanceOf(address(reentrant)), 0, "the reentrant holder must still receive its own reward");
        assertTrue(reentrant.reentryReverted(), "the nested processBatch() reentry attempt must have hit the reentrancy guard and reverted");
    }

    // ---------- batching across multiple calls ----------

    function test_ProcessBatch_ResumesAcrossMultipleCallsWhenOverBatchSize() public {
        _setRewardConfig();
        uint256 t0 = block.timestamp;

        // BATCH_SIZE + 5 holders forces a second processBatch() call, whatever BATCH_SIZE is set to.
        // Only two of them -- one landing in each batch -- are actually funded above MIN_HOLDING_BPS:
        // the fixed 0.25% floor makes it mathematically impossible for more than 400 holders to be
        // simultaneously eligible (400 * 0.25% = 100% of total supply), so at a large
        // BATCH_SIZE the rest exist purely to pad _holders past the batch boundary, exactly like a
        // real token's long tail of small holders that never clear the floor.
        uint256 batchSize = token.BATCH_SIZE();
        uint256 n = batchSize + 5;
        uint256 eligibleInBatch1 = 0;
        uint256 eligibleInBatch2 = batchSize; // first entry of the second batch
        address[] memory holders = new address[](n);
        for (uint256 i; i < n; ++i) {
            holders[i] = address(uint160(uint256(keccak256(abi.encode("holder", i)))));
            bool eligible = i == eligibleInBatch1 || i == eligibleInBatch2;
            token.transfer(holders[i], eligible ? 400_000e18 : 1);
        }
        _drainSelfDust(); // keep _holders at exactly these n -- address(this) would otherwise still be in the set too.

        _deposit(10 ether);
        vm.warp(t0 + 12 hours);

        token.processBatch();
        assertTrue(token.distributing(), "n holders must not finish in a single batch");
        assertGt(holders[eligibleInBatch1].balance, 0, "the eligible holder in batch 1 must be paid after the first call");
        assertEq(holders[eligibleInBatch2].balance, 0, "the eligible holder in batch 2 must not be paid yet");

        token.processBatch();
        assertFalse(token.distributing(), "the second call must finish the remaining holders");
        assertApproxEqAbs(holders[eligibleInBatch1].balance, 5 ether, 0.01 ether, "the two equally-weighted eligible holders split the pool evenly");
        assertApproxEqAbs(holders[eligibleInBatch2].balance, 5 ether, 0.01 ether, "the two equally-weighted eligible holders split the pool evenly");
    }

    // ---------- double-buffering ----------

    function test_DoubleBuffering_NextRoundAccruesWhileStillDistributing() public {
        _setRewardConfig();
        uint256 t0 = block.timestamp;

        uint256 n = token.BATCH_SIZE() + 5; // forces the round to span 2 batches, staying `distributing` after the first
        address[] memory holders = new address[](n);
        for (uint256 i; i < n; ++i) {
            holders[i] = address(uint160(uint256(keccak256(abi.encode("holder", i)))));
            token.transfer(holders[i], 100e18);
        }
        _deposit(5.5 ether);
        vm.warp(t0 + 12 hours);
        token.processBatch();
        assertTrue(token.distributing(), "must still be mid-payout for round 1");

        // While round 1 is still batching out, new activity happens -- this must accrue into
        // round 2, not corrupt round 1's frozen weights.
        address carol = makeAddr("carol");
        token.transfer(carol, 1000e18);
        _deposit(1 ether); // deposited into the NEW round's roundPool, not round 1's frozen payout

        // Finish round 1. Carol joining _holders mid-payout appends her as one more live slot that
        // processBatch must still walk past (with zero weight for round 1, since she held nothing
        // during its accrual window) before the round can close -- so this may take one more call than
        // the original holder count alone would suggest; loop rather than assume a fixed count.
        while (token.distributing()) {
            token.processBatch();
        }
        assertFalse(token.distributing(), "round 1 must finish independent of round 2's new activity");

        // Round 2 hasn't closed yet (only just started) -- carol shouldn't have been paid from
        // round 1's pool, and round 2's own pool should reflect only the new 1 ether deposit.
        assertEq(carol.balance, 0, "carol never held anything during round 1's window");
        assertEq(token.roundPool(), 1 ether, "round 2's pool must only contain the new deposit");
    }

    // ---------- manual trigger ----------

    function test_ManualProcessBatch_WorksWithoutAnyTransfer() public {
        _setRewardConfig();
        uint256 t0 = block.timestamp;
        token.transfer(alice, 10_000e18); // comfortably above the fixed 2,500e18 floor
        _drainSelfDust(); // isolate alice as the sole eligible holder for a clean 100%-of-pool check

        _deposit(10 ether);

        vm.warp(t0 + 12 hours + 1);
        // No transfer happens here at all -- processBatch() is called directly, the only way a round
        // ever actually closes/advances (manually, or via DuckKeeper's scheduled call).
        token.processBatch();

        assertApproxEqAbs(alice.balance, 10 ether, 0.01 ether);
    }

    // ---------- ERC20 (non-native) reward currency ----------

    function test_ERC20Currency_DepositAndPayoutWork() public {
        // Every other test uses native currency (address(0)) -- this is the only one that exercises
        // the ERC20 branch of both depositHolderReward (transferFrom) and processBatch's payout
        // (the gas-capped low-level transfer call), which is otherwise completely untested.
        MockERC20 quote = new MockERC20();
        token.setRewardConfig(hook, address(quote), poolManager);
        uint256 t0 = block.timestamp;

        token.transfer(alice, 10_000e18); // comfortably above the fixed 2,500e18 floor
        _drainSelfDust();

        quote.mint(hook, 10e18);
        vm.startPrank(hook);
        quote.approve(address(token), 10e18);
        token.depositHolderReward(10e18);
        vm.stopPrank();

        assertEq(token.roundPool(), 10e18);

        vm.warp(t0 + 12 hours);
        token.processBatch();

        assertApproxEqAbs(quote.balanceOf(alice), 10e18, 0.01e18,
            "alice must be paid in the configured ERC20 quote currency, not native");
        assertEq(alice.balance, 0, "no native currency should move when rewardCurrency is an ERC20");
    }

    // ---------- a full exit forfeits under the fixed floor, but must never corrupt anyone else's payout ----------

    function test_FullExitBeforeRoundCloses_ForfeitsReward_WithoutBreakingOthers() public {
        // Alice holds for the first half of the round, then sells everything to DEAD -- well before
        // the round even closes. Under the fixed MIN_HOLDING_BPS floor, a zero balance at payout time
        // can never clear a nonzero minimum, so alice correctly forfeits whatever she earned. What
        // must NOT happen is her exit corrupting the holder set for anyone else: bob, who holds
        // throughout and stays comfortably above the floor, must still be paid in full.
        _setRewardConfig();
        uint256 t0 = block.timestamp;

        token.transfer(alice, 10_000e18);
        token.transfer(bob, 10_000e18);
        _drainSelfDust();

        vm.warp(t0 + 6 hours);
        vm.prank(alice);
        token.transfer(DEAD, 10_000e18); // full exit -- balance drops to exactly 0

        _deposit(10 ether);
        vm.warp(t0 + 12 hours);
        token.processBatch();

        assertEq(alice.balance, 0, "a zero balance at payout time can never clear the fixed minimum -- alice must forfeit");
        assertGt(bob.balance, 0, "bob held throughout and must still be paid despite alice's exit");
    }

    function test_FullExitDuringActivePayout_ForfeitsReward_WithoutBreakingLaterBatch() public {
        // BATCH_SIZE + 5 holders forces a 2-batch round. The holder at index batchSize is the FIRST
        // entry of the SECOND (not-yet-processed) batch -- sell everything to zero in between the two
        // processBatch() calls. That holder correctly forfeits its own reward (a zero balance can
        // never clear MIN_HOLDING_BPS), but this must not corrupt the holder set: everyone else in the
        // still-pending second batch must still be found and paid, rather than a naive removal
        // silently dropping them from _holders. Only the exiting holder and the LAST holder (n-1) are
        // funded above MIN_HOLDING_BPS -- the fixed 0.25% floor makes it mathematically impossible for
        // more than 400 holders to be simultaneously eligible, so the rest are dust padding, same as a
        // real token's long tail. n-1 is deliberately the eligible one checked for corruption: a naive
        // swap-and-pop removal of the exiting holder would move exactly this last entry into the
        // removed slot, which is the scenario this test exists to catch.
        _setRewardConfig();
        uint256 t0 = block.timestamp;

        uint256 batchSize = token.BATCH_SIZE();
        uint256 n = batchSize + 5;
        uint256 exitIndex = batchSize;
        uint256 eligibleIndex = n - 1;
        address[] memory holders = new address[](n);
        for (uint256 i; i < n; ++i) {
            holders[i] = address(uint160(uint256(keccak256(abi.encode("holder", i)))));
            bool eligible = i == exitIndex || i == eligibleIndex;
            token.transfer(holders[i], eligible ? 400_000e18 : 1);
        }
        _drainSelfDust();

        _deposit(5.5 ether);
        vm.warp(t0 + 12 hours);

        token.processBatch(); // batch 1: indices [0, batchSize)
        assertTrue(token.distributing(), "must still be mid-payout, the exiting holder not yet visited");
        assertEq(holders[exitIndex].balance, 0, "exiting holder is in the second batch, not paid yet");

        address sink = makeAddr("sink");
        vm.prank(holders[exitIndex]);
        token.transfer(sink, 400_000e18); // full exit, entirely before their own payout batch runs

        // sink is a brand-new address, so this exit also appends it as one more live _holders slot
        // (with zero weight for this round) that processBatch must still walk past before the round
        // can close -- loop rather than assume the exit is a net-zero change to the holder count.
        while (token.distributing()) {
            token.processBatch(); // batch 2 (and, if needed, one more for sink's slot)
        }
        assertFalse(token.distributing(), "round must finish once every remaining slot is processed");
        assertEq(holders[exitIndex].balance, 0, "a zero balance at payout time can never clear the fixed minimum -- exiting holder must forfeit");
        assertGt(holders[eligibleIndex].balance, 0, "the exit must not corrupt payouts to the rest of the still-pending batch");
    }
}

contract MockHookedCurrency {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    // ERC777-style: best-effort notifies a contract recipient after crediting it. A non-implementing
    // recipient (no onTokensReceived, or one that reverts) still receives normally -- the notification
    // failing is silently ignored, matching how real hook-standard tokens behave for non-registered
    // recipients.
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        if (to.code.length > 0) {
            to.call(abi.encodeWithSignature("onTokensReceived(uint256)", amount));
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract ReentrantOnTokenReceivedHolder {
    DuckToken public token;
    MockHookedCurrency public quote;
    bool public reentryReverted;

    constructor(DuckToken token_, MockHookedCurrency quote_) {
        token = token_;
        quote = quote_;
    }

    // Fires from the hooked currency's transfer(), the instant this contract is paid its own reward --
    // mid-processBatch. Directly reenters processBatch() itself: a real vector, since processBatch is
    // permissionless and callable by anyone at any time, including a payout recipient reacting to its
    // own payment. That nested call must hit the reentrancy guard and revert; caught here via
    // try/catch so this contract's own revert doesn't drag down the outer payout call that invoked it
    // (matching how a real ERC777-style hook implementation would just swallow the failure).
    function onTokensReceived(uint256) external {
        try token.processBatch() {
            reentryReverted = false;
        } catch {
            reentryReverted = true;
        }
    }
}

contract MockContractHolder {
    receive() external payable {}
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
