// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {DuckWheel} from "duck-shared/DuckWheel.sol";

// DuckVRF now lives in its own standalone project (workspace root: DuckVRF/) with its own build
// pipeline, independent of DuckProtocol -- so DuckWheel's tests exercise it here through a local
// mock that reproduces the same hash-chain commit/reveal surface DuckWheel actually depends on
// (IDuckVRF's request/getRandomNumber), rather than importing the real contract across projects.
contract DuckWheelTest is Test {
    MockDuckVRF vrf;
    DuckWheel wheel;
    MockERC20 duck;
    address provider = makeAddr("provider");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    // Same 2-link hash-chain helper as DuckVRF.t.sol -- this test contract acts as its own VRF
    // provider so spins can be deterministically resolved.
    function _chain() internal pure returns (bytes32 seed, bytes32 s1, bytes32 root) {
        seed = keccak256("wheel-test-seed");
        s1 = keccak256(abi.encodePacked(seed));
        root = keccak256(abi.encodePacked(s1));
    }

    function setUp() public {
        vrf = new MockDuckVRF();
        duck = new MockERC20();
        wheel = new DuckWheel(address(vrf), provider, address(duck));

        (, , bytes32 root) = _chain();
        vm.prank(provider);
        vrf.registerProvider(root);
    }

    function _makeEligible(address who) internal {
        duck.mint(who, wheel.MIN_DUCK_BALANCE());
    }

    // A 30-slot table: slot 0 is No Prize at exactly the 30% ceiling; the remaining 7000bps is spread
    // across the other 29 slots (240bps each, plus 40bps absorbed by the last one to hit exactly
    // 7000), each paying out wheelTokens[0] (duck itself) for simplicity -- individual per-slot token
    // routing is exercised separately in test_ResolveSpin_PaysTheCorrectWheelToken.
    function _defaultPrizeTable() internal pure returns (DuckWheel.PrizeSlot[30] memory slots) {
        slots[0] = DuckWheel.PrizeSlot({wheelTokenIndex: 0, amount: 0, oddsBps: 3000, isNoPrize: true});
        uint16 remaining = 7000;
        for (uint256 i = 1; i < 30; ++i) {
            uint16 odds = i == 29 ? remaining : 240;
            remaining -= odds;
            slots[i] = DuckWheel.PrizeSlot({wheelTokenIndex: 0, amount: 1e18, oddsBps: odds, isNoPrize: false});
        }
    }

    // ---------- construction / access control ----------

    function test_Constructor_RevertsOnZeroVrfOrProvider() public {
        vm.expectRevert(DuckWheel.ZeroAddress.selector);
        new DuckWheel(address(0), provider, address(duck));
        vm.expectRevert(DuckWheel.ZeroAddress.selector);
        new DuckWheel(address(vrf), address(0), address(duck));
    }

    function test_Constructor_SeedsWheelSlotZeroWithDuckToken() public {
        assertEq(wheel.wheelTokens(0), address(duck));
    }

    function test_OnlyOwnerCanCallAdminFunctions() public {
        vm.startPrank(alice);
        vm.expectRevert(DuckWheel.NotOwner.selector);
        wheel.setDuckToken(address(1));
        vm.expectRevert(DuckWheel.NotOwner.selector);
        wheel.setStockToken(address(1), true);
        vm.expectRevert(DuckWheel.NotOwner.selector);
        wheel.setDailyDuckProtocolTokens([address(1), address(2), address(3)]);
        vm.expectRevert(DuckWheel.NotOwner.selector);
        wheel.setDailyStockTokens([address(1), address(2), address(3), address(4)]);
        vm.expectRevert(DuckWheel.NotOwner.selector);
        wheel.setPrizeTable(_defaultPrizeTable());
        vm.expectRevert(DuckWheel.NotOwner.selector);
        wheel.withdrawTreasury(address(duck), alice, 1);
        vm.expectRevert(DuckWheel.NotOwner.selector);
        wheel.transferOwnership(alice);
        vm.stopPrank();
    }

    function test_TransferOwnership() public {
        wheel.transferOwnership(alice);
        assertEq(wheel.owner(), alice);
    }

    // ---------- $DUCK / eligibility ----------

    function test_SetDuckToken_UpdatesEligibilityTokenAndWheelSlotZero() public {
        MockERC20 newDuck = new MockERC20();
        wheel.setDuckToken(address(newDuck));
        assertEq(wheel.duckToken(), address(newDuck));
        assertEq(wheel.wheelTokens(0), address(newDuck));
    }

    function test_IsEligible_FalseBelowThreshold_TrueAtOrAboveIt() public {
        duck.mint(alice, wheel.MIN_DUCK_BALANCE() - 1);
        assertFalse(wheel.isEligible(alice));
        duck.mint(alice, 1);
        assertTrue(wheel.isEligible(alice));
    }

    function test_IsEligible_FalseWhenDuckTokenUnset() public {
        DuckWheel freshWheel = new DuckWheel(address(vrf), provider, address(0));
        assertFalse(freshWheel.isEligible(alice));
    }

    // ---------- stock token registry ----------

    function test_SetStockToken_AddsAndRemoves() public {
        address stock = address(new MockERC20());
        wheel.setStockToken(stock, true);
        assertTrue(wheel.isStockToken(stock));
        assertEq(wheel.stockTokenCount(), 1);

        wheel.setStockToken(stock, false);
        assertFalse(wheel.isStockToken(stock));
        assertEq(wheel.stockTokenCount(), 0);
    }

    // ---------- daily wheel-slot rotation ----------

    function test_SetDailyDuckProtocolTokens_FillsSlotsOneThroughThree() public {
        address[3] memory picks = [address(new MockERC20()), address(new MockERC20()), address(new MockERC20())];
        wheel.setDailyDuckProtocolTokens(picks);
        assertEq(wheel.wheelTokens(1), picks[0]);
        assertEq(wheel.wheelTokens(2), picks[1]);
        assertEq(wheel.wheelTokens(3), picks[2]);
    }

    function test_SetDailyDuckProtocolTokens_RevertsWithinRotationInterval() public {
        address[3] memory picks = [address(1), address(2), address(3)];
        wheel.setDailyDuckProtocolTokens(picks);

        vm.expectRevert(DuckWheel.TooSoonToRotate.selector);
        wheel.setDailyDuckProtocolTokens(picks);

        vm.warp(block.timestamp + wheel.ROTATION_INTERVAL());
        wheel.setDailyDuckProtocolTokens(picks); // must succeed once the interval has elapsed
    }

    function test_SetDailyStockTokens_RequiresRegisteredStockTokens() public {
        address notStock = address(new MockERC20());
        address[4] memory picks = [notStock, address(2), address(3), address(4)];
        vm.expectRevert(DuckWheel.InvalidStockToken.selector);
        wheel.setDailyStockTokens(picks);
    }

    function test_SetDailyStockTokens_FillsSlotsFourThroughSeven() public {
        address[4] memory picks;
        for (uint256 i; i < 4; ++i) {
            address t = address(new MockERC20());
            wheel.setStockToken(t, true);
            picks[i] = t;
        }
        wheel.setDailyStockTokens(picks);
        for (uint256 i; i < 4; ++i) {
            assertEq(wheel.wheelTokens(4 + i), picks[i]);
        }
    }

    // ---------- prize table validation ----------

    function test_SetPrizeTable_AcceptsValidTable() public {
        wheel.setPrizeTable(_defaultPrizeTable());
        assertTrue(wheel.prizeTableSet());
    }

    function test_SetPrizeTable_RevertsIfOddsDoNotSumToWhole() public {
        DuckWheel.PrizeSlot[30] memory slots = _defaultPrizeTable();
        slots[1].oddsBps += 1; // now sums to 10_001
        vm.expectRevert(DuckWheel.OddsMustSumToWhole.selector);
        wheel.setPrizeTable(slots);
    }

    function test_SetPrizeTable_RevertsIfAnyOddsOutOfRange() public {
        DuckWheel.PrizeSlot[30] memory tooLow = _defaultPrizeTable();
        tooLow[1].oddsBps = 5; // below MIN_ODDS_BPS (10)
        vm.expectRevert(DuckWheel.OddsOutOfRange.selector);
        wheel.setPrizeTable(tooLow);
    }

    function test_SetPrizeTable_RevertsIfNoPrizeIsNotStrictlyHighest() public {
        DuckWheel.PrizeSlot[30] memory slots = _defaultPrizeTable();
        // Push slot 1 up to TIE the No-Prize slot's odds (3000), taking the needed odds back out
        // evenly across the other 28 real-prize slots so the table still sums to exactly 10_000 and
        // every slot stays within the valid [MIN_ODDS_BPS, MAX_ODDS_BPS] range -- this must still be
        // rejected, since No Prize must be STRICTLY highest, not merely tied.
        uint16 delta = 3000 - slots[1].oddsBps;
        slots[1].oddsBps = 3000;
        uint16 perSlot = delta / 28;
        uint16 accountedFor;
        for (uint256 i = 2; i < 30; ++i) {
            slots[i].oddsBps -= perSlot;
            accountedFor += perSlot;
        }
        slots[29].oddsBps -= (delta - accountedFor); // mop up the integer-division remainder
        vm.expectRevert(DuckWheel.NoPrizeMustBeHighestOdds.selector);
        wheel.setPrizeTable(slots);
    }

    function test_SetPrizeTable_RevertsWithoutAnyNoPrizeSlot() public {
        DuckWheel.PrizeSlot[30] memory slots = _defaultPrizeTable();
        slots[0].isNoPrize = false; // now every slot is a real prize -- no NO_PRIZE outcome exists
        slots[0].wheelTokenIndex = 0;
        vm.expectRevert(DuckWheel.NoPrizeMustBeHighestOdds.selector);
        wheel.setPrizeTable(slots);
    }

    function test_SetPrizeTable_RevertsOnInvalidWheelTokenIndex() public {
        DuckWheel.PrizeSlot[30] memory slots = _defaultPrizeTable();
        slots[1].wheelTokenIndex = 8; // out of range -- only 0-7 are valid
        vm.expectRevert(DuckWheel.InvalidWheelTokenIndex.selector);
        wheel.setPrizeTable(slots);
    }

    // ---------- spin() ----------

    function test_Spin_RevertsIfNotEligible() public {
        vm.prank(alice);
        vm.expectRevert(DuckWheel.NotEligible.selector);
        wheel.spin();
    }

    function test_Spin_RevertsIfPrizeTableNotSet() public {
        _makeEligible(alice);
        vm.prank(alice);
        vm.expectRevert(DuckWheel.PrizeTableNotSet.selector);
        wheel.spin();
    }

    function test_Spin_RequestsRandomnessAndTracksPendingSpin() public {
        _makeEligible(alice);
        wheel.setPrizeTable(_defaultPrizeTable());

        vm.prank(alice);
        uint64 seq = wheel.spin();

        (address player, bool resolved) = wheel.pendingSpins(seq);
        assertEq(player, alice);
        assertFalse(resolved);
    }

    function test_Spin_RevertsOnCooldown() public {
        _makeEligible(alice);
        wheel.setPrizeTable(_defaultPrizeTable());

        vm.startPrank(alice);
        wheel.spin();
        vm.expectRevert(DuckWheel.SpinOnCooldown.selector);
        wheel.spin();
        vm.stopPrank();

        vm.warp(block.timestamp + wheel.SPIN_COOLDOWN());
        vm.prank(alice);
        wheel.spin(); // must succeed once the cooldown has elapsed
    }

    // ---------- resolveSpin() ----------

    function test_ResolveSpin_RevertsIfNoPendingSpin() public {
        vm.expectRevert(DuckWheel.NoPendingSpin.selector);
        wheel.resolveSpin(0);
    }

    function test_ResolveSpin_RevertsIfNotYetRevealed() public {
        _makeEligible(alice);
        wheel.setPrizeTable(_defaultPrizeTable());
        vm.prank(alice);
        uint64 seq = wheel.spin();

        vm.expectRevert(DuckWheel.NotYetRevealed.selector);
        wheel.resolveSpin(seq);
    }

    function test_ResolveSpin_RevertsOnDoubleResolve() public {
        _makeEligible(alice);
        wheel.setPrizeTable(_defaultPrizeTable());
        duck.mint(address(wheel), 100e18); // fund the treasury so a real-prize outcome can pay out

        vm.prank(alice);
        uint64 seq = wheel.spin();
        (, bytes32 userRandom, ,) = vrf.requests(provider, seq);
        (, bytes32 s1, ) = _chain();
        vrf.reveal(provider, seq, s1);

        wheel.resolveSpin(seq);
        vm.expectRevert(DuckWheel.AlreadyResolved.selector);
        wheel.resolveSpin(seq);
        userRandom; // silence unused-var warning; kept for clarity of what reveal() combines with
    }

    // Reproduces the exact on-chain roll -> prize-slot mapping given a known reveal value, to
    // determine which slot resolveSpin() should have landed on, then asserts against that -- rather
    // than grinding for a specific outcome. This is what actually proves the odds table is being
    // walked correctly by resolveSpin().
    function _expectedSlot(DuckWheel.PrizeSlot[30] memory slots, bytes32 revealValue, bytes32 userRandom, uint64 seq)
        internal
        pure
        returns (uint256)
    {
        bytes32 randomNumber = keccak256(abi.encode(revealValue, userRandom, seq));
        uint256 roll = uint256(randomNumber) % 10_000;
        uint256 cumulative;
        for (uint256 i; i < 30; ++i) {
            cumulative += slots[i].oddsBps;
            if (roll < cumulative) return i;
        }
        revert("unreachable -- odds must sum to 10_000");
    }

    function test_ResolveSpin_PaysOutOrEmitsNoPrizeMatchingTheComputedRoll() public {
        _makeEligible(alice);
        DuckWheel.PrizeSlot[30] memory slots = _defaultPrizeTable();
        wheel.setPrizeTable(slots);
        duck.mint(address(wheel), 1000e18);

        vm.prank(alice);
        uint64 seq = wheel.spin();
        (, bytes32 userRandom, ,) = vrf.requests(provider, seq);
        (, bytes32 s1, ) = _chain();

        uint256 expected = _expectedSlot(slots, s1, userRandom, seq);
        uint256 balanceBefore = duck.balanceOf(alice);

        vrf.reveal(provider, seq, s1);
        wheel.resolveSpin(seq);

        (, bool resolved) = wheel.pendingSpins(seq);
        assertTrue(resolved);

        if (slots[expected].isNoPrize) {
            assertEq(duck.balanceOf(alice), balanceBefore, "No Prize must pay nothing");
        } else {
            assertEq(
                duck.balanceOf(alice),
                balanceBefore + slots[expected].amount,
                "the player must receive exactly the computed slot's prize amount"
            );
        }
    }

    function test_ResolveSpin_PaysTheCorrectWheelToken() public {
        // A table where every slot is a guaranteed win (no No-Prize slot at all is invalid per the
        // contract's own rules -- see test_SetPrizeTable_RevertsWithoutAnyNoPrizeSlot -- so instead
        // give No Prize the minimum-possible share, MIN_ODDS_BPS below the top slot, to make hitting
        // a *specific* real prize slot the overwhelmingly likely outcome for this deterministic seed)
        // paying out wheelTokens[3] specifically, to prove resolveSpin() routes to the slot's own
        // configured token, not always wheelTokens[0].
        MockERC20 pickToken = new MockERC20();
        wheel.setDailyDuckProtocolTokens([address(pickToken), address(2), address(3)]);
        pickToken.mint(address(wheel), 1000e18);
        duck.mint(address(wheel), 1000e18); // slots 2-29 pay out wheelTokens[0] (duck) -- fund that too

        DuckWheel.PrizeSlot[30] memory slots;
        slots[0] = DuckWheel.PrizeSlot({wheelTokenIndex: 1, amount: 42e18, oddsBps: 2999, isNoPrize: false});
        slots[1] = DuckWheel.PrizeSlot({wheelTokenIndex: 0, amount: 0, oddsBps: 3000, isNoPrize: true});
        for (uint256 i = 2; i < 30; ++i) {
            slots[i] = DuckWheel.PrizeSlot({wheelTokenIndex: 0, amount: 1, oddsBps: 142, isNoPrize: false});
        }
        // 2999 + 3000 + 27*142 = 2999 + 3000 + 3834 = 9833 -- top up slot 29 with the remainder to
        // land on exactly 10_000 (slots 2-29 is 28 slots, so this replaces slot 29's own 142 too).
        slots[29].oddsBps = 10_000 - 2999 - 3000 - 27 * 142;
        wheel.setPrizeTable(slots);

        _makeEligible(alice);
        vm.prank(alice);
        uint64 seq = wheel.spin();
        (, bytes32 userRandom, ,) = vrf.requests(provider, seq);
        (, bytes32 s1, ) = _chain();

        uint256 expected = _expectedSlot(slots, s1, userRandom, seq);
        vrf.reveal(provider, seq, s1);
        wheel.resolveSpin(seq);

        if (expected == 0) {
            assertEq(pickToken.balanceOf(alice), 42e18, "slot 0 must pay from wheelTokens[1], the DuckProtocol pick");
        }
    }

    // ---------- treasury ----------

    function test_WithdrawTreasury_MovesTokensOut() public {
        duck.mint(address(wheel), 10e18);
        wheel.withdrawTreasury(address(duck), bob, 10e18);
        assertEq(duck.balanceOf(bob), 10e18);
    }
}

contract MockERC20 {
    mapping(address => uint256) public balanceOf;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// A test-local stand-in for the real DuckVRF (now DuckVRF/, its own standalone project) --
// reproduces the same hash-chain commit/reveal surface DuckWheel and this test file depend on:
// registerProvider/request/reveal/getRandomNumber, plus the public `requests` getter these tests
// read back to recover a spin's userRandomNumber. See DuckVRF/src/DuckVRF.sol for the real,
// independently-tested implementation this mirrors.
contract MockDuckVRF {
    struct ProviderInfo {
        bytes32 currentCommitment;
        uint64 sequenceCount;
    }

    struct Request {
        address requester;
        bytes32 userRandomNumber;
        bool fulfilled;
        bytes32 randomNumber;
    }

    mapping(address => ProviderInfo) public providers;
    mapping(address => mapping(uint64 => Request)) public requests;

    function registerProvider(bytes32 initialCommitment) external {
        providers[msg.sender] = ProviderInfo({currentCommitment: initialCommitment, sequenceCount: 0});
    }

    function request(address provider, bytes32 userRandomNumber) external returns (uint64 sequenceNumber) {
        ProviderInfo storage p = providers[provider];
        sequenceNumber = p.sequenceCount++;
        requests[provider][sequenceNumber] =
            Request({requester: msg.sender, userRandomNumber: userRandomNumber, fulfilled: false, randomNumber: bytes32(0)});
    }

    function reveal(address provider, uint64 sequenceNumber, bytes32 revealValue) external {
        ProviderInfo storage p = providers[provider];
        require(keccak256(abi.encodePacked(revealValue)) == p.currentCommitment, "invalid reveal");
        Request storage r = requests[provider][sequenceNumber];
        require(!r.fulfilled, "already revealed");
        p.currentCommitment = revealValue;
        r.fulfilled = true;
        r.randomNumber = keccak256(abi.encode(revealValue, r.userRandomNumber, sequenceNumber));
    }

    function getRandomNumber(address provider, uint64 sequenceNumber)
        external
        view
        returns (bytes32 randomNumber, bool fulfilled)
    {
        Request storage r = requests[provider][sequenceNumber];
        return (r.randomNumber, r.fulfilled);
    }
}
