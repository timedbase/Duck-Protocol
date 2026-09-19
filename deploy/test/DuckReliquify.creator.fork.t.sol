// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test, Vm} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {DuckReliquifyToken} from "duck-lib/DuckReliquifyToken.sol";
import {Route, RouteShape} from "duck-lib/LaunchRouting.sol";

interface IERC20CreatorFork {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

// The LIVE Robinhood DuckGenesisHook and DuckVaultFactory, not test doubles: the point of these tests is what the
// real registerPool / claimFees / createVault do with the creator DuckReliquify hands them.
interface IGenesisHookCreatorFork {
    function owner() external view returns (address);
    function platformWallet() external view returns (address);
    function addLauncher(address launcher_) external;
    function pools(bytes32 poolId) external view returns (
        address token, address quoteCurrency, bool tokenIsCurrency0, address creator, uint256 launchTimestamp,
        bool registered, uint256 hookFeeBps, uint16 creatorBps, uint16 vaultBps, uint16 burnBps
    );
    function accruedFees(bytes32 poolId) external view returns (uint256);
    function claimFees(bytes32 poolId) external;
    function transferPoolCreator(bytes32 poolId, address newCreator) external;
}

interface IVaultFactoryCreatorFork {
    function owner() external view returns (address);
    function setFamily(address family_, bool allowed_) external;
}

interface ITokenVaultCreatorFork { function vault() external view returns (address); }
interface IVaultCreatorFork { function creator() external view returns (address); }

// The migration leader is the pool's creator (and its vault's creator), so the creatorBps share of every fee payout
// goes to them, not to the platform. Earlier builds hardcoded the platform wallet here.
contract DuckReliquifyCreatorForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER    = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant HOOK                = 0x18bd65Fb1c44DD629caD7c7F5B96aD2bCAF76ACC;
    address constant VAULT_FACTORY       = 0x006e53d079BB4c2010682a4896D1950965faD5A5;
    address constant OLD_TOKEN           = 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4; // BTC

    DuckReliquify reliquify;
    IGenesisHookCreatorFork hook = IGenesisHookCreatorFork(HOOK);

    address leader  = makeAddr("cr-leader");
    address holder1 = makeAddr("cr-holder1");
    address holder2 = makeAddr("cr-holder2");
    address holder3 = makeAddr("cr-holder3");
    address other   = makeAddr("cr-other");
    address platform;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));
        platform = hook.platformWallet();

        DuckReliquifyToken tokenImpl = new DuckReliquifyToken(VAULT_FACTORY);
        DuckReliquify impl = new DuckReliquify();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(DuckReliquify.initialize, (WETH, address(tokenImpl), V4_POOL_MANAGER, V4_POSITION_MANAGER, HOOK, platform))
        );
        reliquify = DuckReliquify(payable(address(proxy)));
        reliquify.setUniversalRouter(UNIVERSAL_ROUTER);
        reliquify.setVaultFactory(VAULT_FACTORY);

        vm.prank(hook.owner());
        hook.addLauncher(address(reliquify));
        vm.prank(IVaultFactoryCreatorFork(VAULT_FACTORY).owner());
        IVaultFactoryCreatorFork(VAULT_FACTORY).setFamily(address(reliquify), true);

        Route[] memory routes = new Route[](1);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = OLD_TOKEN;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        routes[0] = Route({shape: RouteShape.V3_STYLE, enabled: true, path: path, fees: fees, hook: address(0), fee: 0, tickSpacing: 0});
        reliquify.setRoutes(OLD_TOKEN, routes);

        deal(OLD_TOKEN, holder1, 3e7);
        deal(OLD_TOKEN, holder2, 3e7);
        deal(OLD_TOKEN, holder3, 4e7);
    }

    function _proposeAndApprove(uint16 creatorBps, uint16 vaultBps, uint16 burnBps) private returns (uint256 id, address newToken) {
        vm.prank(leader);
        id = reliquify.proposeMigration(OLD_TOKEN, 200, creatorBps, vaultBps, burnBps);
        address[] memory accounts = new address[](3);
        accounts[0] = holder1; accounts[1] = holder2; accounts[2] = holder3;
        uint256[] memory balances = new uint256[](3);
        balances[0] = 3e7; balances[1] = 3e7; balances[2] = 4e7;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        reliquify.finalizeSnapshot(id);
        vm.stopPrank();
        newToken = reliquify.approveMigration(id, "Reliquified BTC", "rBTC", "ipfs://test");
    }

    function _seed(uint256 id) private returns (bytes32 poolId) {
        vm.startPrank(holder1);
        IERC20CreatorFork(OLD_TOKEN).approve(address(reliquify), 3e7);
        reliquify.depositPreSeed(id, 3e7);
        vm.stopPrank();
        vm.startPrank(holder2);
        IERC20CreatorFork(OLD_TOKEN).approve(address(reliquify), 3e7);
        reliquify.depositPreSeed(id, 3e7);
        vm.stopPrank();

        vm.recordLogs();
        reliquify.seedPool(id, 0);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("PoolSeeded(uint256,bytes32,uint256)");
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(reliquify) && logs[i].topics[0] == topic) {
                (poolId,) = abi.decode(logs[i].data, (bytes32, uint256));
            }
        }
        require(poolId != bytes32(0), "PoolSeeded event not found");
    }

    function test_Leader_IsPoolCreator_AndReceivesTheCreatorShareOfFees() public {
        (uint256 id,) = _proposeAndApprove(10_000, 0, 0); // the whole 70% remainder is the creator's
        bytes32 poolId = _seed(id);

        (,,, address creator,, bool registered,,,,) = hook.pools(poolId);
        assertTrue(registered);
        assertEq(creator, leader, "the leader must be the pool's creator");
        assertTrue(creator != platform, "the platform wallet must no longer be the creator");

        // A post-seed deposit buys back through the pool, which is a real swap: it accrues a hook fee.
        vm.startPrank(holder3);
        IERC20CreatorFork(OLD_TOKEN).approve(address(reliquify), 4e7);
        reliquify.depositPostSeed(id, 4e7, 0, 0);
        vm.stopPrank();

        uint256 accrued = hook.accruedFees(poolId);
        assertGt(accrued, 0, "the swap must have accrued a fee");

        uint256 leaderBefore = IERC20CreatorFork(WETH).balanceOf(leader);
        uint256 platformBefore = IERC20CreatorFork(WETH).balanceOf(platform);
        uint256 claimerBefore = IERC20CreatorFork(WETH).balanceOf(address(this));
        hook.claimFees(poolId);

        // 25% platform (24% + 1% to whoever triggers the claim), 5% holders, 70% to the creator = the leader.
        assertEq(IERC20CreatorFork(WETH).balanceOf(platform) - platformBefore, (accrued * 2400) / 10_000, "platform gets 24%");
        assertEq(IERC20CreatorFork(WETH).balanceOf(address(this)) - claimerBefore, (accrued * 100) / 10_000, "the caller gets 1%");
        assertGe(IERC20CreatorFork(WETH).balanceOf(leader) - leaderBefore, (accrued * 7000) / 10_000, "the leader gets the creator share");
    }

    function test_CreatorShare_FollowsTheLeadersSplit() public {
        // 40% creator / 60% burn: the leader gets 40% of the 70% remainder, the rest buys back and burns.
        (uint256 id,) = _proposeAndApprove(4_000, 0, 6_000);
        bytes32 poolId = _seed(id);
        vm.startPrank(holder3);
        IERC20CreatorFork(OLD_TOKEN).approve(address(reliquify), 4e7);
        reliquify.depositPostSeed(id, 4e7, 0, 0);
        vm.stopPrank();

        uint256 accrued = hook.accruedFees(poolId);
        uint256 leaderBefore = IERC20CreatorFork(WETH).balanceOf(leader);
        hook.claimFees(poolId);
        uint256 got = IERC20CreatorFork(WETH).balanceOf(leader) - leaderBefore;
        uint256 remainder = (accrued * 7000) / 10_000;
        assertApproxEqAbs(got, (remainder * 4000) / 10_000, remainder / 100 + 2, "the leader gets 40% of the 70% remainder");
        assertLt(got, remainder, "the burn share must not go to the leader");
    }

    function test_VaultCreator_IsTheLeader() public {
        (, address newToken) = _proposeAndApprove(5_000, 5_000, 0);
        address vault = ITokenVaultCreatorFork(newToken).vault();
        assertTrue(vault != address(0), "a vault must exist when vaultBps > 0");
        assertEq(IVaultCreatorFork(vault).creator(), leader, "the vault's creator must follow the pool's creator");
    }

    function test_PlatformCanStillMoveTheCreatorRole() public {
        (uint256 id,) = _proposeAndApprove(10_000, 0, 0);
        bytes32 poolId = _seed(id);
        vm.prank(hook.owner());
        hook.transferPoolCreator(poolId, other);
        (,,, address creator,,,,,,) = hook.pools(poolId);
        assertEq(creator, other, "the hook owner keeps the escape hatch for a lost or compromised leader");
    }
}
