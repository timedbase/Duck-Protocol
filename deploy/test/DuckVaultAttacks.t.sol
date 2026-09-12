// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {PoolKey, SwapParams} from "duck-lib/LaunchRouting.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DuckClones} from "duck-lib/DuckClones.sol";

contract MockERC20Atk {
    uint8 public decimals = 18;
    address public vault;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setVault(address vault_) external { vault = vault_; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; return true; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
}

// ERC777-style: fires a callback out of transferFrom, like a real hooked token would on the sender
// side. Used to prove DuckVault's reentrancy guard actually blocks a reentrant repay()/liquidate(),
// not just that its own accounting looks right in the non-adversarial tests.
contract MaliciousReentrantCurrency {
    uint8 public decimals = 18;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public target;
    bytes public reentrantCall;
    bool public armed;
    bool public reentrantCallAttempted;
    bool public reentrantCallSucceeded;

    function arm(address target_, bytes calldata reentrantCall_) external {
        target = target_;
        reentrantCall = reentrantCall_;
        armed = true;
    }

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; return true; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount; balanceOf[to] += amount;
        if (armed) {
            armed = false; // one-shot -- avoid unbounded recursion, one reentrant attempt is enough to prove the point
            reentrantCallAttempted = true;
            (bool ok, ) = target.call(reentrantCall);
            reentrantCallSucceeded = ok;
        }
        return true;
    }
}

contract MockStateViewAtk {
    mapping(bytes32 => int24) public tickOf;

    uint128 private _liquidity = type(uint128).max;
    function setTick(bytes32 poolId, int24 tick) external { tickOf[poolId] = tick; }
    function setLiquidity(uint128 liquidity_) external { _liquidity = liquidity_; }
    function getSlot0(bytes32 poolId) external view returns (uint160, int24 tick, uint24, uint24) {
        return (0, tickOf[poolId], 0, 0);
    }
    function getLiquidity(bytes32) external view returns (uint128) { return _liquidity; }
}

contract DuckVaultAttacksTest is Test {
    DuckVault vault;
    DuckVaultConfig config;
    DuckHookV4 hook;
    MockStateViewAtk stateView;
    MockERC20Atk token;
    MockERC20Atk currency;

    address poolManager = makeAddr("poolManager");
    address launcher = makeAddr("launcher");
    address family = makeAddr("family");
    address attacker = makeAddr("attacker");
    address liquidator = makeAddr("liquidator");

    bytes32 poolId;
    PoolKey key;
    bool tokenIsC0;

    function setUp() public {
        token = new MockERC20Atk();
        currency = new MockERC20Atk();

        hook = DuckHookV4(payable(_deployHook(poolManager)));
        stateView = new MockStateViewAtk();
        hook.setStateView(address(stateView));
        hook.addLauncher(launcher);

        tokenIsC0 = address(token) < address(currency);
        key = PoolKey({
            currency0: tokenIsC0 ? address(token) : address(currency),
            currency1: tokenIsC0 ? address(currency) : address(token),
            fee: 10_000,
            tickSpacing: 200,
            hooks: address(hook)
        });
        poolId = keccak256(abi.encode(key));

        vm.prank(launcher);
        hook.registerPool(key, address(token), address(this), 0, 10_000, 0, 0);

        DuckVaultConfig configImpl = new DuckVaultConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), abi.encodeCall(DuckVaultConfig.initialize, (address(this))));
        config = DuckVaultConfig(address(configProxy));

        DuckVault vaultImpl = new DuckVault();
        address vaultClone = DuckClones.clone(address(vaultImpl), address(this), bytes32(0));
        vault = DuckVault(payable(vaultClone));
        vault.initialize(address(token), 18, address(this), address(config), address(hook), family);
        vm.prank(family);
        vault.linkPool(address(currency), poolId, tokenIsC0, 18, false);
        token.setVault(address(vault));

        currency.mint(family, 1000 ether);
        vm.prank(family);
        currency.approve(address(vault), type(uint256).max);
        vm.prank(family);
        vault.depositFees(1000 ether);

        token.mint(makeAddr("attacksUnrelatedHolder"), 10_000_000 ether);
        token.mint(attacker, 100_000 ether);
        vm.prank(attacker);
        token.approve(address(vault), type(uint256).max);

        currency.mint(attacker, 1000 ether);
        vm.prank(attacker);
        currency.approve(address(vault), type(uint256).max);

        currency.mint(liquidator, 1000 ether);
        vm.prank(liquidator);
        currency.approve(address(vault), type(uint256).max);
    }

    function _swapAt(int24 tick) internal {
        stateView.setTick(poolId, tick);
        vm.prank(poolManager);
        hook.afterSwap(address(0), key, SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}), int256(0), "");
    }

    function test_OracleManipulation_ShortWindowPumpDoesNotInflateBorrowLimit() public {
        // Base shifted well past minPoolAge (24h, relative to poolLinkedAt set near genesis in
        // setUp()) -- the pump's relative timing (tight, near the end of the window) is what this
        // test actually cares about, so only the absolute starting point moves, not the spacing.
        uint256 base = 90_000;
        vm.warp(base);
        _swapAt(0);

        for (uint256 i = 1; i <= 15; i++) {
            vm.warp(base + i * 1_200);
            _swapAt(0);
        }
        uint256 tNow = base + 15 * 1_200;

        int24 pumpTick = tokenIsC0 ? int24(7_000) : int24(-7_000);
        vm.warp(tNow + 750);
        _swapAt(pumpTick);
        vm.warp(tNow + 1_500);
        _swapAt(pumpTick);

        vm.prank(attacker);
        vault.addCollateral(10 ether);

        vm.prank(attacker);
        vm.expectRevert(DuckVault.ExceedsMaxLtv.selector);
        vault.borrow(4 ether);

        vm.prank(attacker);
        vault.borrow(2 ether);
    }

    function test_MaxBorrowerShareCapsSingleBorrowerExposure() public {
        _seedRealPriceHistory();

        vm.prank(attacker);
        vault.addCollateral(100_000 ether);

        vm.prank(attacker);
        vm.expectRevert(DuckVault.ExceedsBorrowerShare.selector);
        vault.borrow(300 ether);

        vm.prank(attacker);
        vault.borrow(200 ether);
    }

    function test_ExceedsCirculatingShareBlocksOverConcentratedCollateral() public {
        _seedRealPriceHistory();

        token.mint(attacker, 2_000_000 ether);
        uint256 attackerBalance = token.balanceOf(attacker);
        uint256 circulating = token.totalSupply();
        assertGt(attackerBalance * 10_000, circulating * 1000, "sanity: attacker must exceed the real 10% threshold");

        vm.prank(attacker);
        token.approve(address(vault), type(uint256).max);
        vm.prank(attacker);
        vault.addCollateral(attackerBalance);

        vm.prank(attacker);
        vm.expectRevert(DuckVault.ExceedsCirculatingShare.selector);
        vault.borrow(0.0001 ether);
    }

    function test_DeeplyUnderwaterLiquidation_ClampsAndSocializesBadDebt() public {
        _seedRealPriceHistory();

        vm.prank(attacker);
        vault.addCollateral(10 ether);
        vm.prank(attacker);
        vault.borrow(3 ether);

        int24 crashTick = tokenIsC0 ? int24(-23_500) : int24(23_500);
        vm.warp(200_000);
        _swapAt(crashTick);
        vm.warp(220_000);
        _swapAt(crashTick);

        uint256 reservesBefore = vault.totalReserves();
        uint256 borrowsBefore = vault.totalBorrows();

        vm.prank(liquidator);
        vault.liquidate(attacker, 3 ether);

        (uint128 collateralAfter, uint128 principalAfter, , ) = vault.loans(attacker);
        assertEq(collateralAfter, 0, "all collateral must be seized when the position can't cover repay+bonus");
        assertEq(principalAfter, 0, "the position must close fully, not partially, once collateral runs out");

        assertEq(vault.totalBorrows(), borrowsBefore - 3 ether);
        assertLt(vault.totalReserves(), reservesBefore + 3 ether, "reserves must NOT grow by the full requested repay -- only by what was actually recoverable");
        assertGe(vault.totalReserves(), reservesBefore, "reserves must never go backwards from a liquidation");
    }

    function test_CloseFactorLimitsHowMuchOneLiquidationCanClose() public {
        _seedRealPriceHistory();

        vm.prank(attacker);
        vault.addCollateral(10 ether);
        vm.prank(attacker);
        vault.borrow(3 ether);

        int24 crashTick = tokenIsC0 ? int24(-9_200) : int24(9_200);
        vm.warp(200_000);
        _swapAt(crashTick);
        vm.warp(220_000);
        _swapAt(crashTick);

        assertTrue(vault.healthFactorBps(attacker) < 10_000, "position must be liquidatable for this test to be meaningful");

        vm.prank(liquidator);
        vault.liquidate(attacker, 3 ether);

        (, uint128 principalAfter, , ) = vault.loans(attacker);

        assertApproxEqAbs(uint256(principalAfter), 1.5 ether, 0.01 ether, "closeFactor must cap a single liquidation at 50% of the debt");
    }

    function test_ZeroPoolLiquidityBlocksBorrowingEntirely() public {
        _seedRealPriceHistory();
        stateView.setLiquidity(0);

        vm.prank(attacker);
        vault.addCollateral(10 ether);

        vm.prank(attacker);
        vm.expectRevert(DuckVault.ExceedsPoolDepthShare.selector);
        vault.borrow(0.0001 ether);
    }

    function test_UnavailablePoolDepthBlocksBorrowing() public {
        _seedRealPriceHistory();
        hook.setStateView(address(0));

        vm.prank(attacker);
        vault.addCollateral(10 ether);

        vm.prank(attacker);
        vm.expectRevert(DuckVault.PoolDepthUnavailable.selector);
        vault.borrow(0.0001 ether);
    }

    function test_PoolDepthGuardRecoversOnceLiquidityReturns() public {
        _seedRealPriceHistory();
        stateView.setLiquidity(0);

        vm.prank(attacker);
        vault.addCollateral(10 ether);
        vm.prank(attacker);
        vm.expectRevert(DuckVault.ExceedsPoolDepthShare.selector);
        vault.borrow(1 ether);

        stateView.setLiquidity(type(uint128).max);
        vm.prank(attacker);
        vault.borrow(1 ether);
        assertEq(vault.totalBorrows(), 1 ether);
    }

    function _seedRealPriceHistory() internal {
        vm.warp(1_000);
        _swapAt(0);
        for (uint256 i = 1; i <= 15; i++) {
            vm.warp(1_000 + i * 1_200);
            _swapAt(0);
        }
        // Past minPoolAge (24h, see DuckVaultConfig) relative to poolLinkedAt (set in setUp(), at
        // block.timestamp close to genesis for this non-fork test) -- so tests exercise their own
        // specific scenario rather than universally hitting the fresh-pool guard.
        vm.warp(100_000);
    }

    // ---------- reentrancy ----------

    // Shared by both reentrancy tests below: a fresh vault + pool using a malicious, ERC777-style
    // currency instead of the plain mock, plus enough real price history for borrow()/liquidate() to
    // work against it. currency is an arbitrary, permissionless quote token per this codebase's own
    // launcher tests -- not something safe to assume is a plain, hookless ERC20.
    struct EvilSetup { DuckVault vault; bytes32 poolId; PoolKey key; }

    function _deployVaultWithCurrency(MaliciousReentrantCurrency evilCurrency) internal returns (EvilSetup memory s) {
        bool tIsC0 = address(token) < address(evilCurrency);
        s.key = PoolKey({
            currency0: tIsC0 ? address(token) : address(evilCurrency),
            currency1: tIsC0 ? address(evilCurrency) : address(token),
            fee: 10_000,
            tickSpacing: 200,
            hooks: address(hook)
        });
        s.poolId = keccak256(abi.encode(s.key));
        vm.prank(launcher);
        hook.registerPool(s.key, address(token), address(this), 0, 10_000, 0, 0);

        DuckVault vaultImpl = new DuckVault();
        address vaultClone = DuckClones.clone(address(vaultImpl), address(this), bytes32(uint256(uint160(address(evilCurrency)))));
        s.vault = DuckVault(payable(vaultClone));
        s.vault.initialize(address(token), 18, address(this), address(config), address(hook), family);
        vm.prank(family);
        s.vault.linkPool(address(evilCurrency), s.poolId, tIsC0, 18, false);

        evilCurrency.mint(family, 1000 ether);
        vm.prank(family);
        evilCurrency.approve(address(s.vault), type(uint256).max);
        vm.prank(family);
        s.vault.depositFees(1000 ether);

        stateView.setTick(s.poolId, 0);
        vm.warp(1_000);
        vm.prank(poolManager);
        hook.afterSwap(address(0), s.key, SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}), int256(0), "");
        for (uint256 i = 1; i <= 15; i++) {
            vm.warp(1_000 + i * 1_200);
            vm.prank(poolManager);
            hook.afterSwap(address(0), s.key, SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}), int256(0), "");
        }
        // Past minPoolAge (24h, see DuckVaultConfig) relative to poolLinkedAt (set just above, at
        // block.timestamp close to genesis for this non-fork test).
        vm.warp(100_000);
    }

    // Proves repay()'s reentrancy guard actually blocks a reentrant repay() attempt triggered from
    // within the currency's own transferFrom, rather than just trusting that the fix compiles.
    function test_ReentrantCurrency_RepayCannotReenterRepay() public {
        MaliciousReentrantCurrency evilCurrency = new MaliciousReentrantCurrency();
        EvilSetup memory s = _deployVaultWithCurrency(evilCurrency);

        vm.prank(attacker);
        token.approve(address(s.vault), type(uint256).max);
        vm.prank(attacker);
        s.vault.addCollateral(10 ether);
        vm.prank(attacker);
        s.vault.borrow(2 ether);

        evilCurrency.mint(attacker, 10 ether);
        vm.prank(attacker);
        evilCurrency.approve(address(s.vault), type(uint256).max);

        evilCurrency.arm(address(s.vault), abi.encodeWithSelector(DuckVault.repay.selector, 1 ether));

        vm.prank(attacker);
        s.vault.repay(1 ether);

        assertTrue(evilCurrency.reentrantCallAttempted(), "the malicious currency must actually have tried to reenter repay()");
        assertFalse(evilCurrency.reentrantCallSucceeded(), "a reentrant repay() call must be blocked by the guard");
    }

    // Same proof, against liquidate() -- the more concerning of the two, since the reentrant call is
    // liquidator-initiated (deliberate attacker choice) rather than a borrower's own footgun.
    function test_ReentrantCurrency_LiquidateCannotReenterLiquidate() public {
        MaliciousReentrantCurrency evilCurrency = new MaliciousReentrantCurrency();
        EvilSetup memory s = _deployVaultWithCurrency(evilCurrency);

        vm.prank(attacker);
        token.approve(address(s.vault), type(uint256).max);
        vm.prank(attacker);
        s.vault.addCollateral(10 ether);
        vm.prank(attacker);
        s.vault.borrow(3 ether);

        // Crash the price so the position becomes liquidatable, same technique as the other
        // liquidation tests in this file, just against this test's own isolated pool. Sign depends on
        // token/evilCurrency's own address ordering, NOT the outer shared tokenIsC0 (computed against
        // the unrelated shared `currency` mock) -- evilCurrency's address relative to token is
        // effectively random, so reusing the shared flag would pick the wrong sign about half the time.
        bool evilTokenIsC0 = address(token) < address(evilCurrency);
        int24 crashTick = evilTokenIsC0 ? int24(-23_500) : int24(23_500);
        stateView.setTick(s.poolId, crashTick);
        vm.warp(200_000);
        vm.prank(poolManager);
        hook.afterSwap(address(0), s.key, SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}), int256(0), "");
        vm.warp(220_000);
        vm.prank(poolManager);
        hook.afterSwap(address(0), s.key, SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}), int256(0), "");

        evilCurrency.mint(liquidator, 10 ether);
        vm.prank(liquidator);
        evilCurrency.approve(address(s.vault), type(uint256).max);

        evilCurrency.arm(address(s.vault), abi.encodeWithSelector(DuckVault.liquidate.selector, attacker, 3 ether));

        vm.prank(liquidator);
        s.vault.liquidate(attacker, 3 ether);

        assertTrue(evilCurrency.reentrantCallAttempted(), "the malicious currency must actually have tried to reenter liquidate()");
        assertFalse(evilCurrency.reentrantCallSucceeded(), "a reentrant liquidate() call must be blocked by the guard");
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
