// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {PoolKey, SwapParams} from "duck-lib/LaunchRouting.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DuckClones} from "duck-lib/DuckClones.sol";

contract MockERC20 {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8  public decimals = 18;
    address public vault;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function setVault(address vault_) external {
        vault = vault_;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
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
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

contract MockStateView {
    mapping(bytes32 => int24) public tickOf;

    uint128 private _liquidity = type(uint128).max;

    function setTick(bytes32 poolId, int24 tick) external {
        tickOf[poolId] = tick;
    }

    function setLiquidity(uint128 liquidity_) external {
        _liquidity = liquidity_;
    }

    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)
    {
        return (0, tickOf[poolId], 0, 0);
    }

    function getLiquidity(bytes32) external view returns (uint128) {
        return _liquidity;
    }
}

contract DuckVaultTest is Test {
    DuckVault vault;
    DuckVaultConfig config;
    DuckHookV4 hook;
    MockStateView stateView;
    MockERC20 token;
    MockERC20 currency;

    address poolManager = makeAddr("poolManager");
    address launcher = makeAddr("launcher");
    address family = makeAddr("family");
    address borrower = makeAddr("borrower");
    address liquidator = makeAddr("liquidator");

    bytes32 poolId;
    PoolKey key;

    function setUp() public {
        token = new MockERC20();
        currency = new MockERC20();

        hook = DuckHookV4(payable(_deployHook(poolManager)));
        stateView = new MockStateView();
        hook.setStateView(address(stateView));
        hook.addLauncher(launcher);

        bool tokenIsC0 = address(token) < address(currency);
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
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl), abi.encodeCall(DuckVaultConfig.initialize, (address(this)))
        );
        config = DuckVaultConfig(address(configProxy));

        DuckVault vaultImpl = new DuckVault();
        address vaultClone = DuckClones.clone(address(vaultImpl), address(this), bytes32(0));
        vault = DuckVault(payable(vaultClone));
        vault.initialize(address(token), 18, address(this), address(config), address(hook), family);
        vm.prank(family);
        vault.linkPool(address(currency), poolId, tokenIsC0, 18, false);
        token.setVault(address(vault));

        stateView.setTick(poolId, 0);
        _swap();
        vm.warp(block.timestamp + 20_000);
        _swap();
        // Past minPoolAge (24h, see DuckVaultConfig) so tests exercise their own specific scenario
        // rather than universally hitting the (separately, directly tested) fresh-pool guard.
        vm.warp(block.timestamp + 70_000);

        currency.mint(family, 1000 ether);
        vm.prank(family);
        currency.approve(address(vault), type(uint256).max);
        vm.prank(family);
        vault.depositFees(1000 ether);

        token.mint(borrower, 100 ether);
        vm.prank(borrower);
        token.approve(address(vault), type(uint256).max);

        currency.mint(borrower, 1000 ether);
        vm.prank(borrower);
        currency.approve(address(vault), type(uint256).max);

        currency.mint(liquidator, 1000 ether);
        vm.prank(liquidator);
        currency.approve(address(vault), type(uint256).max);
    }

    function _swap() internal {
        vm.prank(poolManager);
        hook.afterSwap(address(0), key, SwapParams({zeroForOne: true, amountSpecified: 0, sqrtPriceLimitX96: 0}), int256(0), "");
    }

    function test_BorrowUpToMaxLtvSucceeds() public {

        vm.prank(borrower);
        vault.addCollateral(10 ether);

        vm.prank(borrower);
        vault.borrow(3 ether);

        assertEq(currency.balanceOf(borrower), 1000 ether + 3 ether);
        assertEq(vault.totalBorrows(), 3 ether);
        assertEq(vault.totalReserves(), 1000 ether - 3 ether);
    }

    function test_BorrowAboveMaxLtvReverts() public {
        vm.prank(borrower);
        vault.addCollateral(10 ether);

        vm.prank(borrower);
        vm.expectRevert(DuckVault.ExceedsMaxLtv.selector);
        vault.borrow(3 ether + 1);
    }

    function test_BorrowRevertsWhenExceedingRealReserves() public {

        vm.prank(borrower);
        vm.expectRevert(DuckVault.InsufficientLiquidity.selector);
        vault.borrow(1000 ether + 1);
    }

    function test_BorrowRevertsIfMarketNeverLinked() public {

        DuckVault unlinkedImpl = new DuckVault();
        address unlinkedClone = DuckClones.clone(address(unlinkedImpl), address(this), bytes32(uint256(1)));
        DuckVault unlinkedVault = DuckVault(payable(unlinkedClone));
        unlinkedVault.initialize(address(token), 18, address(this), address(config), address(hook), family);

        vm.prank(borrower);
        vm.expectRevert(DuckVault.MarketDisabled.selector);
        unlinkedVault.borrow(1 ether);
    }

    function test_RepayRevertsWithNoDebt() public {
        vm.prank(borrower);
        vm.expectRevert(DuckVault.NoDebt.selector);
        vault.repay(1 ether);
    }

    function test_LiquidateRevertsWithNoDebt() public {
        vm.prank(liquidator);
        vm.expectRevert(DuckVault.NoDebt.selector);
        vault.liquidate(borrower, 1 ether);
    }

    function test_RepayClearsDebtAndEarmarksInterestForBuyback() public {
        vm.prank(borrower);
        vault.addCollateral(10 ether);
        vm.prank(borrower);
        vault.borrow(3 ether);

        vm.warp(block.timestamp + 30 days);

        vm.prank(borrower);
        vault.repay(10 ether);

        (, uint128 principal, , ) = vault.loans(borrower);
        assertEq(principal, 0, "full repayment must zero out the loan");

        assertGt(vault.pendingBuyback(), 0, "interest-bearing repayment must queue a nonzero buyback cut");
    }

    function test_RepayWithNoAccruedTimeEarmarksNothing() public {
        vm.prank(borrower);
        vault.addCollateral(10 ether);
        vm.prank(borrower);
        vault.borrow(3 ether);

        vm.prank(borrower);
        vault.repay(3 ether);

        assertEq(vault.pendingBuyback(), 0, "a same-block repay is pure principal, nothing to buy back");
    }

    function test_AddAndWithdrawCollateral() public {
        vm.prank(borrower);
        vault.addCollateral(10 ether);
        assertEq(vault.totalCollateral(), 10 ether);

        vm.prank(borrower);
        vault.withdrawCollateral(4 ether);
        assertEq(token.balanceOf(borrower), 100 ether - 6 ether);
        assertEq(vault.totalCollateral(), 6 ether);
    }

    function test_WithdrawCollateralBlockedIfWouldBreachLtv() public {
        vm.prank(borrower);
        vault.addCollateral(10 ether);
        vm.prank(borrower);
        vault.borrow(3 ether);

        vm.prank(borrower);
        vm.expectRevert(DuckVault.ExceedsMaxLtv.selector);
        vault.withdrawCollateral(1 ether);
    }

    function test_LiquidationAtBreachedThreshold() public {
        vm.prank(borrower);
        vault.addCollateral(10 ether);
        vm.prank(borrower);
        vault.borrow(3 ether);

        vm.prank(liquidator);
        vm.expectRevert(DuckVault.NotLiquidatable.selector);
        vault.liquidate(borrower, 1 ether);

        stateView.setTick(poolId, 0);
        bool tokenIsC0 = address(token) < address(currency);

        int24 crashTick = tokenIsC0 ? int24(-20000) : int24(20000);
        stateView.setTick(poolId, crashTick);

        // Forward of wherever setUp() left off (it now warps past minPoolAge -- see DuckVaultConfig
        // -- so block.timestamp is already ~90_000 by this point); an absolute warp to a smaller
        // value here would rewind time and underflow _accrue()'s elapsed-time math against the
        // lastAccrual already stamped by the borrow() above.
        vm.warp(150_000);
        _swap();
        vm.warp(170_000);
        _swap();

        uint256 healthBefore = vault.healthFactorBps(borrower);
        assertLt(healthBefore, 10_000, "position must be underwater after the crash");

        uint256 liquidatorTokenBefore = token.balanceOf(liquidator);
        vm.prank(liquidator);
        vault.liquidate(borrower, 1 ether);

        assertGt(token.balanceOf(liquidator), liquidatorTokenBefore, "liquidator must receive seized collateral");
    }

    function test_CTOApprovalUpdatesVaultCreatorOnly() public {
        address newCreator = makeAddr("newCreator");
        address platformWallet = makeAddr("platformWallet");
        hook.setPlatformWallet(platformWallet);

        address applicant = makeAddr("applicant");
        vm.deal(applicant, 1 ether);
        vm.prank(applicant);
        hook.applyForCTO{value: hook.ctoFee()}(poolId, newCreator);

        address vaultBefore = address(vault);
        hook.approveCTO(poolId);

        assertEq(vault.creator(), newCreator, "CTO must update the vault's creator");
        assertEq(address(vault), vaultBefore, "CTO must never touch the vault address itself");
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
