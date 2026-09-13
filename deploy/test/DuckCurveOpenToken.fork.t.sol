// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Runs UpgradeCurveOpenToken against the live Robinhood Chain deployment as its real owner and checks both
// kinds of curve token end to end on the real DuckBondingCurve proxy, PoolManager and DuckGenesisHook:
//   - a token created on DuckToken before the upgrade stays locked, then migrates and is unlocked;
//   - a token created on DuckCurveToken after it is transferable from the start, its pool can't be
//     initialized ahead of migration (a no-hook pool for the same pair can, and changes nothing), and it
//     migrates onto DuckGenesisHook.
//
//   forge test --match-path test/DuckCurveOpenToken.fork.t.sol

import {Test} from "forge-std/Test.sol";

import {UpgradeCurveOpenToken} from "../script/UpgradeCurveOpenToken.s.sol";
import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckGenesisHook} from "duck-shared/DuckGenesisHook.sol";
import {TokenConfig} from "duck-lib/DuckTypes.sol";
import {PoolKey} from "duck-lib/LaunchRouting.sol";

interface ILaunchLockable {
    function launchPhaseLocked() external view returns (bool);
}

interface IERC20CurveTest {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

interface IPositionManagerInit {
    function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) external payable returns (int24);
}

interface IStateViewCurveTest {
    function getSlot0(bytes32 poolId) external view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

contract DuckCurveOpenTokenForkTest is Test {
    address constant OWNER            = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;
    address constant CURVE            = 0xcE71ce995C2A3657aF9bEC45bA1Ee2E8fA2ef5eF;
    address constant WETH             = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant STATE_VIEW       = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    bytes32 constant IMPL_SLOT        = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint160 constant ONE_TO_ONE       = 79228162514264337593543950336; // sqrt(1) * 2^96

    DuckBondingCurve curve = DuckBondingCurve(payable(CURVE));
    address creator = makeAddr("curve-creator");
    address buyer   = makeAddr("curve-buyer");
    address friend  = makeAddr("curve-friend");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        vm.deal(creator, 10 ether);
        vm.deal(buyer, 200 ether);
    }

    function test_UpgradeSetsImplementationAndTemplate() public {
        UpgradeCurveOpenToken.Result memory r = new UpgradeCurveOpenToken().upgradeAs(OWNER);
        assertEq(address(uint160(uint256(vm.load(CURVE, IMPL_SLOT)))), r.curveImpl, "proxy runs the new implementation");
        assertEq(curve.tokenImpl(), r.curveTokenImpl, "curve clones DuckCurveToken");
    }

    function test_TokenLaunchedLockedBeforeUpgradeStillMigratesAndUnlocks() public {
        address token = _create(curve.tokenImpl());
        assertTrue(ILaunchLockable(token).launchPhaseLocked(), "pre-upgrade curve tokens carry the lock");

        vm.prank(buyer);
        curve.buy{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);
        uint256 bought = IERC20CurveTest(token).balanceOf(buyer);
        vm.prank(buyer);
        vm.expectRevert();
        IERC20CurveTest(token).transfer(friend, bought / 2);

        new UpgradeCurveOpenToken().upgradeAs(OWNER);

        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);
        TokenConfig memory tc = curve.getTokenConfig(token);
        assertTrue(tc.migrated, "migrated on the target-crossing buy");
        assertFalse(ILaunchLockable(token).launchPhaseLocked(), "migration lifted the lock");
        _assertOnGenesisHook(token, tc.poolId);

        vm.prank(buyer);
        assertTrue(IERC20CurveTest(token).transfer(friend, bought / 2), "transferable after migration");
    }

    function test_NewCurveTokenIsTransferableAndItsPoolCantBeSeededEarly() public {
        UpgradeCurveOpenToken.Result memory r = new UpgradeCurveOpenToken().upgradeAs(OWNER);
        address token = _create(r.curveTokenImpl);

        (bool hasLock,) = token.staticcall(abi.encodeWithSelector(ILaunchLockable.launchPhaseLocked.selector));
        assertFalse(hasLock, "DuckCurveToken has no launch-phase lock");

        vm.prank(buyer);
        curve.buy{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);
        uint256 bought = IERC20CurveTest(token).balanceOf(buyer);
        assertGt(bought, 0);
        vm.prank(buyer);
        assertTrue(IERC20CurveTest(token).transfer(friend, bought / 4), "wallet-to-wallet transfer before migration");

        // Someone tries to initialize the exact pool migration will create. DuckGenesisHook refuses an
        // unregistered key, so the PositionManager reports failure and the pool stays uninitialized.
        address hook = curve.v4Hook();
        PoolKey memory key = _key(token, hook);
        int24 tick = IPositionManagerInit(POSITION_MANAGER).initializePool(key, ONE_TO_ONE);
        assertEq(tick, type(int24).max, "hook refused to initialize an unregistered pool");
        (uint160 early,,,) = IStateViewCurveTest(STATE_VIEW).getSlot0(keccak256(abi.encode(key)));
        assertEq(early, 0, "our pool is still uninitialized");

        // A pool for the same pair without the hook is a different key: it can exist, and migration
        // doesn't care.
        PoolKey memory noHook = _key(token, address(0));
        int24 sideTick = IPositionManagerInit(POSITION_MANAGER).initializePool(noHook, ONE_TO_ONE);
        assertTrue(sideTick != type(int24).max, "a separate no-hook pool can be created");

        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);
        TokenConfig memory tc = curve.getTokenConfig(token);
        assertTrue(tc.migrated, "migrated on the target-crossing buy");
        assertEq(tc.poolId, keccak256(abi.encode(key)), "migrated into the hook pool, not the side pool");
        _assertOnGenesisHook(token, tc.poolId);

        vm.prank(friend);
        assertTrue(IERC20CurveTest(token).transfer(buyer, bought / 8), "still transferable after migration");
    }

    // ---------------------------------------------------------------- helpers

    function _create(address impl) internal returns (address token) {
        DuckBondingCurve.BaseParams memory p;
        p.name = "Open Duck";
        p.symbol = "ODUCK";
        p.supplyTier = 0;
        p.curveBps = 8_000;
        p.liquidityBps = 2_000;
        p.quoteToken = address(0);
        p.startVirtualQuote = 1 ether;
        p.migrationTargetQuote = 10 ether;
        p.hookFeeBps = 350;
        p.creatorBps = 10_000;
        p.salt = _mineTokenSalt(creator, impl);
        uint256 fee = curve.creationFee();
        vm.prank(creator);
        token = curve.createToken{value: fee}(p);
        assertEq(uint16(uint160(token)), 0x8888, "vanity address");
    }

    function _assertOnGenesisHook(address token, bytes32 poolId) internal view {
        DuckGenesisHook hook = DuckGenesisHook(payable(curve.v4Hook()));
        (address poolToken,,,,, bool registered, uint256 feeBps,,,) = hook.pools(poolId);
        assertTrue(registered, "pool registered on DuckGenesisHook");
        assertEq(poolToken, token);
        assertEq(feeBps, 350);
        (uint160 sqrtPriceX96,,,) = IStateViewCurveTest(STATE_VIEW).getSlot0(poolId);
        assertGt(sqrtPriceX96, 0, "pool initialized at migration");
    }

    // Native-quoted curve pools pair the token with WETH.
    function _key(address token, address hook) internal pure returns (PoolKey memory) {
        (address c0, address c1) = token < WETH ? (token, WETH) : (WETH, token);
        return PoolKey({currency0: c0, currency1: c1, fee: 0, tickSpacing: 200, hooks: hook});
    }

    // salt = keccak256(abi.encode(creator, userSalt)); the curve CREATE2-clones `impl`.
    function _mineTokenSalt(address creator_, address impl) internal pure returns (bytes32 userSalt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3"
        ));
        for (uint256 i = 0; i < 2_000_000; i++) {
            userSalt = bytes32(i);
            bytes32 salt = keccak256(abi.encode(creator_, userSalt));
            bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), CURVE, salt, initCodeHash));
            if (uint16(uint160(uint256(h))) == 0x8888) return userSalt;
        }
        revert("token salt not found");
    }
}
