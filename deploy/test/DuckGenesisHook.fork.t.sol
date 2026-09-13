// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// DuckGenesisHook against Robinhood Chain's real PoolManager. The test contract plays the launcher:
// it registers pools, initializes them, adds liquidity, and trades through its own unlockCallback, so
// every hook callback runs exactly as the PoolManager calls it in production.

import {Test} from "forge-std/Test.sol";

import {DuckGenesisHook} from "duck-shared/DuckGenesisHook.sol";
import {DuckGenesisHookFactory} from "../script/DuckGenesisHookFactory.sol";
import {PoolKey, SwapParams, ModifyLiquidityParams} from "duck-lib/LaunchRouting.sol";

interface IPoolManagerGenesisTest {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feesAccrued);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

contract GenesisMockToken {
    string public name = "Mock";
    string public symbol = "MOCK";
    uint8  public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; totalSupply += amount; }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; return true; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        allowance[from][msg.sender] -= amount; balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
}

// Anyone who isn't a launcher, trying to add liquidity to a registered pool.
contract GenesisStranger {
    IPoolManagerGenesisTest immutable pm;
    PoolKey key;
    constructor(IPoolManagerGenesisTest pm_) { pm = pm_; }
    function addLiquidity(PoolKey memory key_) external {
        key = key_;
        pm.unlock("");
    }
    function unlockCallback(bytes calldata) external returns (bytes memory) {
        pm.modifyLiquidity(key, ModifyLiquidityParams({tickLower: -887_200, tickUpper: 887_200, liquidityDelta: 1e18, salt: bytes32(0)}), "");
        return "";
    }
}

contract DuckGenesisHookForkTest is Test {
    address constant WETH         = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336; // 2^96
    uint160 constant MIN_SQRT = 4295128739;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;
    uint256 constant FEE_BPS = 500; // 5%

    uint8 constant OP_ADD  = 1;
    uint8 constant OP_SWAP = 2;
    uint8 constant OP_REMOVE = 3;

    IPoolManagerGenesisTest pm = IPoolManagerGenesisTest(POOL_MANAGER);
    DuckGenesisHook hook;
    GenesisMockToken token;
    PoolKey key;
    bytes32 poolId;

    address owner    = makeAddr("owner");
    address platform = makeAddr("platform");
    address creator  = makeAddr("creator");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        vm.etch(platform, "");
        vm.etch(creator, "");

        vm.startPrank(owner);
        DuckGenesisHookFactory factory = new DuckGenesisHookFactory();
        bytes32 salt = _mineHookSalt(address(factory), factory.initCodeHash(POOL_MANAGER));
        hook = DuckGenesisHook(payable(factory.deploy(salt, POOL_MANAGER, owner)));
        hook.addLauncher(address(this));
        hook.setPlatformWallet(platform);
        hook.setWeth(WETH);
        vm.stopPrank();

        token = new GenesisMockToken();
        token.mint(address(this), 1_000_000e18);
        vm.deal(address(this), 1_000_000 ether);

        (key, poolId) = _registerAndSeed(address(token), FEE_BPS, 100_000e18);
    }

    receive() external payable {}

    // ---------------------------------------------------------------- setup helpers

    function _keyFor(address token_) internal view returns (PoolKey memory k) {
        k = PoolKey({currency0: address(0), currency1: token_, fee: 0, tickSpacing: 200, hooks: address(hook)});
    }

    function _registerAndSeed(address token_, uint256 feeBps, uint128 liquidity) internal returns (PoolKey memory k, bytes32 id) {
        k = _keyFor(token_);
        id = keccak256(abi.encode(k));
        hook.registerPool(k, token_, creator, feeBps, 10_000, 0, 0);
        pm.initialize(k, SQRT_PRICE_1_1);
        pm.unlock(abi.encode(OP_ADD, abi.encode(k, int256(uint256(liquidity)))));
    }

    function _mineHookSalt(address factory, bytes32 initCodeHash) internal pure returns (bytes32 salt) {
        for (uint256 nonce = 0; nonce < 1_000_000; nonce++) {
            salt = bytes32(nonce);
            bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), factory, salt, initCodeHash));
            if (uint160(uint256(h)) & 0x3FFF == 0x2ACC) return salt;
        }
        revert("hook salt not found");
    }

    function _swap(bool zeroForOne, int256 amountSpecified, uint160 limit) internal returns (int128 amount0, int128 amount1) {
        bytes memory res = pm.unlock(abi.encode(OP_SWAP, abi.encode(key, zeroForOne, amountSpecified, limit)));
        int256 delta = abi.decode(res, (int256));
        amount0 = int128(delta >> 128);
        amount1 = int128(delta);
    }

    function _swapNoLimit(bool zeroForOne, int256 amountSpecified) internal returns (int128, int128) {
        return _swap(zeroForOne, amountSpecified, zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "not pool manager");
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (op == OP_ADD || op == OP_REMOVE) {
            (PoolKey memory k, int256 liquidityDelta) = abi.decode(payload, (PoolKey, int256));
            (int256 delta,) = pm.modifyLiquidity(
                k, ModifyLiquidityParams({tickLower: -887_200, tickUpper: 887_200, liquidityDelta: liquidityDelta, salt: bytes32(0)}), ""
            );
            _settle(k, delta);
            return "";
        }
        (PoolKey memory sk, bool zeroForOne, int256 amountSpecified, uint160 limit) = abi.decode(payload, (PoolKey, bool, int256, uint160));
        int256 swapDelta = pm.swap(sk, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: limit}), "");
        _settle(sk, swapDelta);
        return abi.encode(swapDelta);
    }

    function _settle(PoolKey memory k, int256 delta) internal {
        int128 a0 = int128(delta >> 128);
        int128 a1 = int128(delta);
        if (a0 < 0) pm.settle{value: uint256(uint128(-a0))}();
        if (a0 > 0) pm.take(k.currency0, address(this), uint256(uint128(a0)));
        if (a1 < 0) {
            pm.sync(k.currency1);
            GenesisMockToken(k.currency1).transfer(POOL_MANAGER, uint256(uint128(-a1)));
            pm.settle();
        }
        if (a1 > 0) pm.take(k.currency1, address(this), uint256(uint128(a1)));
    }

    // ---------------------------------------------------------------- fee math

    function test_ExactInputBuyChargesFeeOnQuoteIn() public {
        (int128 eth, int128 tok) = _swapNoLimit(true, -1 ether);
        assertEq(eth, -1 ether, "trader pays exactly the specified quote");
        assertGt(tok, 0);
        assertEq(hook.accruedFees(poolId), 1 ether * FEE_BPS / 10_000, "5% of the quote in");
    }

    function test_ExactOutputBuyGrossesUpFee() public {
        (int128 eth, int128 tok) = _swapNoLimit(true, 100e18);
        assertEq(tok, 100e18, "trader receives exactly the specified tokens");
        uint256 paid = uint256(uint128(-eth));
        uint256 fee = hook.accruedFees(poolId);
        assertEq(fee, (paid - fee) * FEE_BPS / (10_000 - FEE_BPS), "fee grossed up on the quote the pool moved");
        assertApproxEqRel(fee * 1e18 / paid, FEE_BPS * 1e14, 1e15, "fee is 5% of what the trader paid in total");
    }

    function test_ExactInputSellChargesFeeOnQuoteOut() public {
        (int128 eth, int128 tok) = _swapNoLimit(false, -100e18);
        assertEq(tok, -100e18, "trader sells exactly the specified tokens");
        uint256 received = uint256(uint128(eth));
        uint256 fee = hook.accruedFees(poolId);
        assertEq(fee, (received + fee) * FEE_BPS / 10_000, "5% of the quote the pool paid out");
    }

    function test_ExactOutputSellGrossesUpFee() public {
        (int128 eth, int128 tok) = _swapNoLimit(false, 1 ether);
        assertEq(eth, 1 ether, "trader receives exactly the specified quote");
        assertLt(tok, 0);
        assertEq(hook.accruedFees(poolId), 1 ether * FEE_BPS / (10_000 - FEE_BPS), "fee on top of the named quote out");
    }

    function test_PartiallyFilledBuyIsRejected() public {
        // A price limit 0.1% below the current price stops a 50,000 ETH buy almost immediately.
        uint160 limit = uint160(uint256(SQRT_PRICE_1_1) * 9_995 / 10_000);
        // Asserted through try/catch rather than vm.expectRevert: the PoolManager calls back into this
        // contract mid-swap, and the revert has to be unwrapped to confirm it's the hook's own error.
        try this.swapExternal(true, -50_000 ether, limit) {
            fail("partially filled buy was accepted");
        } catch (bytes memory err) {
            assertEq(_hookRevertSelector(err), DuckGenesisHook.PartialFillRejected.selector, "rejected by the fill check");
        }
    }

    function swapExternal(bool zeroForOne, int256 amountSpecified, uint160 limit) external returns (int128, int128) {
        require(msg.sender == address(this), "self only");
        return _swap(zeroForOne, amountSpecified, limit);
    }

    // v4-core wraps a reverting hook as WrappedError(address target, bytes4 selector, bytes reason,
    // bytes details); returns the hook's own revert selector from `reason`.
    function _hookRevertSelector(bytes memory err) internal pure returns (bytes4) {
        require(err.length >= 4 && bytes4(err) == bytes4(keccak256("WrappedError(address,bytes4,bytes,bytes)")), "not a wrapped hook revert");
        bytes memory body = new bytes(err.length - 4);
        for (uint256 i = 0; i < body.length; i++) body[i] = err[i + 4];
        (, , bytes memory reason, ) = abi.decode(body, (address, bytes4, bytes, bytes));
        return bytes4(reason);
    }

    function test_NoSameBlockSwapLimit() public {
        _swapNoLimit(true, -0.1 ether);
        _swapNoLimit(true, -0.1 ether);
        _swapNoLimit(false, -10e18);
        assertGt(hook.accruedFees(poolId), 0);
    }

    // ---------------------------------------------------------------- pool gates

    function test_UnregisteredPoolCannotBeInitialized() public {
        GenesisMockToken other = new GenesisMockToken();
        vm.expectRevert();
        pm.initialize(_keyFor(address(other)), SQRT_PRICE_1_1);
    }

    function test_NonLauncherCannotAddLiquidity() public {
        GenesisStranger stranger = new GenesisStranger(pm);
        vm.expectRevert();
        stranger.addLiquidity(key);
    }

    function test_LauncherRemovedCannotAddLiquidity() public {
        vm.prank(owner);
        hook.removeLauncher(address(this));
        vm.expectRevert();
        pm.unlock(abi.encode(OP_ADD, abi.encode(key, int256(1e18))));
    }

    function test_LiquidityCannotBeRemoved() public {
        vm.expectRevert();
        pm.unlock(abi.encode(OP_REMOVE, abi.encode(key, -int256(1e18))));
    }

    function test_RegisterPoolRules() public {
        GenesisMockToken a = new GenesisMockToken();
        PoolKey memory k = _keyFor(address(a));

        vm.expectRevert(DuckGenesisHook.InvalidHookFeeBps.selector);
        hook.registerPool(k, address(a), creator, 1001, 10_000, 0, 0);

        // A separate struct: assigning `k` would alias it, and changing the spacing would change `k` too.
        PoolKey memory wrongSpacing = _keyFor(address(a));
        wrongSpacing.tickSpacing = 60;
        vm.expectRevert(DuckGenesisHook.InvalidPoolKey.selector);
        hook.registerPool(wrongSpacing, address(a), creator, 735, 10_000, 0, 0);

        vm.prank(creator);
        vm.expectRevert(DuckGenesisHook.NotLauncher.selector);
        hook.registerPool(k, address(a), creator, 735, 10_000, 0, 0);

        hook.registerPool(k, address(a), creator, 735, 10_000, 0, 0);
        (,,,,,, uint256 feeBps,,,) = hook.pools(keccak256(abi.encode(k)));
        assertEq(feeBps, 735, "any rate up to 10% is stored as-is");

        vm.expectRevert(DuckGenesisHook.AlreadyRegistered.selector);
        hook.registerPool(k, address(a), creator, 735, 10_000, 0, 0);
    }

    // ---------------------------------------------------------------- creator + payout

    function test_TransferPoolCreatorIsOwnerOnlyAndClearsSplits() public {
        DuckGenesisHook.FeeSplit[] memory splits = new DuckGenesisHook.FeeSplit[](1);
        splits[0] = DuckGenesisHook.FeeSplit({wallet: makeAddr("split"), bps: 10_000});
        vm.prank(creator);
        hook.setFeeSplits(poolId, splits);

        address newCreator = makeAddr("newCreator");
        vm.prank(creator);
        vm.expectRevert(DuckGenesisHook.NotOwner.selector);
        hook.transferPoolCreator(poolId, newCreator);

        vm.prank(owner);
        hook.transferPoolCreator(poolId, newCreator);
        (,,, address current,,,,,,) = hook.pools(poolId);
        assertEq(current, newCreator);
        assertEq(hook.getFeeSplits(poolId).length, 0, "previous creator's splits cleared");
    }

    function test_ClaimFeesPaysPlatformAndCreator() public {
        _swapNoLimit(true, -10 ether);
        uint256 fee = hook.accruedFees(poolId);
        uint256 platformBefore = platform.balance;
        uint256 creatorBefore = creator.balance;

        hook.claimFees(poolId);

        assertEq(hook.accruedFees(poolId), 0);
        assertEq(platform.balance - platformBefore, fee * 2_400 / 10_000, "24% platform (1% went to the claimer)");
        // The mock token has no holder-reward deposit, so that 5% falls back to the creator: 75%.
        assertApproxEqAbs(creator.balance - creatorBefore, fee * 7_500 / 10_000, 2);
    }
}
