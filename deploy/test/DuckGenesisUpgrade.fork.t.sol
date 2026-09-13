// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Runs UpgradeToGenesis against the live Robinhood Chain deployment as its real owner, then launches a
// token through the upgraded DuckLauncher at a fee the old menu never allowed and trades it -- the
// whole path a creator takes after the upgrade, on real proxies, real PoolManager and real state.

import {Test} from "forge-std/Test.sol";

import {UpgradeToGenesis} from "../script/UpgradeToGenesis.s.sol";
import {DuckLauncher} from "duck-launcher/DuckLauncher.sol";
import {DuckGenesisHook} from "duck-shared/DuckGenesisHook.sol";
import {PoolKey, SwapParams} from "duck-lib/LaunchRouting.sol";

interface ILiveFamily {
    function tokenImpl() external view returns (address);
    function launchFee() external view returns (uint256);
    function dexes(address positionManager) external view returns (address singleton, address hook, bool enabled);
}

interface ILiveVaultFactory {
    function hook() external view returns (address);
}

interface IPoolManagerUpgradeTest {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

interface IERC20UpgradeTest {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
}

contract DuckGenesisUpgradeForkTest is Test {
    address constant OWNER            = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;
    address constant CURVE            = 0xcE71ce995C2A3657aF9bEC45bA1Ee2E8fA2ef5eF;
    address constant LAUNCHER         = 0x5F37c68f9937A0524Cc441b4E1080Ca4F089693B;
    address constant CROWDFUND        = 0xdA868A545aB058D14a70C46CA7760226e7Dcf7b9;
    address constant VAULT_FACTORY    = 0x006e53d079BB4c2010682a4896D1950965faD5A5;
    address constant POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    bytes32 constant IMPL_SLOT        = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;
    uint160 constant MIN_SQRT = 4295128739;
    uint160 constant MAX_SQRT = 1461446703485210103287273052203988822378723970342;

    UpgradeToGenesis.Result r;
    address creator = makeAddr("creator");
    PoolKey swapKey;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        vm.etch(creator, "");
        vm.deal(creator, 100 ether);
        vm.deal(address(this), 100 ether);

        UpgradeToGenesis script = new UpgradeToGenesis();
        r = script.upgradeAs(OWNER, false);
    }

    receive() external payable {}

    function test_UpgradeWiresEverythingToTheNewHook() public view {
        assertEq(uint160(r.hook) & 0x3FFF, 0x2ACC, "hook permission bits");
        DuckGenesisHook hook = DuckGenesisHook(payable(r.hook));
        assertEq(hook.owner(), OWNER);
        assertTrue(hook.isLauncher(CURVE) && hook.isLauncher(LAUNCHER) && hook.isLauncher(CROWDFUND));
        assertTrue(hook.platformWallet() != address(0));
        assertTrue(hook.stateView() != address(0));

        assertEq(address(uint160(uint256(vm.load(CURVE, IMPL_SLOT)))), r.curveImpl);
        assertEq(address(uint160(uint256(vm.load(LAUNCHER, IMPL_SLOT)))), r.launcherImpl);
        assertEq(address(uint160(uint256(vm.load(CROWDFUND, IMPL_SLOT)))), r.crowdfundImpl);

        (, address launcherHook, bool enabled) = ILiveFamily(LAUNCHER).dexes(POSITION_MANAGER);
        assertEq(launcherHook, r.hook);
        assertTrue(enabled);
        assertEq(ILiveVaultFactory(VAULT_FACTORY).hook(), r.hook);

        assertEq(ILiveFamily(LAUNCHER).tokenImpl(), r.launcherTokenImpl);
        assertEq(ILiveFamily(CROWDFUND).tokenImpl(), r.crowdfundTokenImpl);
    }

    function test_LaunchAtAnyFeeOnGenesisHookAndTrade() public {
        DuckLauncher launcher = DuckLauncher(payable(LAUNCHER));
        DuckGenesisHook hook = DuckGenesisHook(payable(r.hook));

        DuckLauncher.LaunchParams memory p;
        p.name = "Genesis Duck";
        p.symbol = "GDUCK";
        p.positionManager = POSITION_MANAGER;
        p.quoteToken = address(0);
        p.vanitySalt = _mineTokenSalt(creator, r.launcherTokenImpl);
        p.launchMarketCap = 5 ether;
        p.hookFeeBps = 735; // 7.35%: never valid under the old 2/4/6/8/10 menu
        p.creatorBps = 10_000;

        uint256 fee = ILiveFamily(LAUNCHER).launchFee();
        vm.prank(creator);
        (address token, bytes32 poolId) = launcher.launch{value: fee + 0.05 ether}(p);

        assertEq(uint16(uint160(token)), 0x8888, "vanity address mined against the new token template");
        (address poolToken,,,,, bool registered, uint256 feeBps,,,) = hook.pools(poolId);
        assertTrue(registered);
        assertEq(poolToken, token);
        assertEq(feeBps, 735);

        (bool hasLock,) = token.staticcall(abi.encodeWithSignature("launchPhaseLocked()"));
        assertFalse(hasLock, "launcher tokens carry no transfer lock");

        uint256 afterInstantBuy = hook.accruedFees(poolId);
        assertGt(afterInstantBuy, 0, "instant buy paid the fee");
        uint256 bought = IERC20UpgradeTest(token).balanceOf(creator);
        assertGt(bought, 0, "instant buy delivered tokens");

        // A plain wallet-to-wallet transfer works immediately.
        vm.prank(creator);
        assertTrue(IERC20UpgradeTest(token).transfer(address(this), bought / 2));

        // Sell half of it back through the pool, exact input.
        swapKey = PoolKey({currency0: address(0), currency1: token, fee: 0, tickSpacing: 200, hooks: r.hook});
        int256 delta = abi.decode(IPoolManagerUpgradeTest(POOL_MANAGER).unlock(abi.encode(false, -int256(bought / 4))), (int256));
        assertGt(int128(delta >> 128), 0, "sell paid out quote");
        assertGt(hook.accruedFees(poolId), afterInstantBuy, "sell paid the fee too");
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "not pool manager");
        (bool zeroForOne, int256 amountSpecified) = abi.decode(data, (bool, int256));
        IPoolManagerUpgradeTest pm = IPoolManagerUpgradeTest(POOL_MANAGER);
        int256 delta = pm.swap(
            swapKey, SwapParams({zeroForOne: zeroForOne, amountSpecified: amountSpecified, sqrtPriceLimitX96: zeroForOne ? MIN_SQRT + 1 : MAX_SQRT - 1}), ""
        );
        int128 a0 = int128(delta >> 128);
        int128 a1 = int128(delta);
        if (a0 < 0) pm.settle{value: uint256(uint128(-a0))}();
        if (a0 > 0) pm.take(address(0), address(this), uint256(uint128(a0)));
        if (a1 < 0) {
            pm.sync(swapKey.currency1);
            IERC20UpgradeTest(swapKey.currency1).transfer(POOL_MANAGER, uint256(uint128(-a1)));
            pm.settle();
        }
        if (a1 > 0) pm.take(swapKey.currency1, address(this), uint256(uint128(a1)));
        return abi.encode(delta);
    }

    // Same derivation the launch contracts and the interface's vanity miner use:
    // salt = keccak256(abi.encode(msg.sender, userSalt)), clone of `impl` created by the launcher.
    function _mineTokenSalt(address creator_, address impl) internal view returns (bytes32 userSalt) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73", impl, hex"5af43d82803e903d91602b57fd5bf3"
        ));
        for (uint256 i = 0; i < 2_000_000; i++) {
            userSalt = bytes32(i);
            bytes32 salt = keccak256(abi.encode(creator_, userSalt));
            bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), LAUNCHER, salt, initCodeHash));
            if (uint16(uint160(uint256(h))) == 0x8888) return userSalt;
        }
        revert("token salt not found");
    }
}
