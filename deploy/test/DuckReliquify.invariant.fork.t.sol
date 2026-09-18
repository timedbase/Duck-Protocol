// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Stateful (handler-based) invariant test -- not a directed happy-path test. Foundry drives the
// Handler below through hundreds of randomly-ordered, randomly-sized calls (deposit pre-seed, seed
// the pool, deposit post-seed, claim -- in whatever sequence and amounts the fuzzer picks) and checks
// the core accounting identity after EVERY single call, on the actual deployed contract's own public
// state -- never a shadow/ghost copy that could itself hide the same class of bug. This is exactly the
// kind of testing that would have caught the reserved-decrement-timing bug found during manual
// end-to-end testing (reserved was only decremented in depositPostSeed, not at the moment a
// depositPreSeed's claim entitlement was created) -- that bug depended on a SPECIFIC call ORDER
// (a post-seed deposit landing between a pre-seed deposit and its claim) that a fixed, hand-written
// test sequence could easily miss but a randomized one reliably explores.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {DuckReliquifyToken} from "duck-lib/DuckReliquifyToken.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultFactory} from "duck-lending/DuckVaultFactory.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";
import {Route, RouteShape} from "duck-lib/LaunchRouting.sol";

interface IERC20Invariant {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

// Exposes exactly the state-mutating surface the fuzzer can call, each call bounded/guarded so an
// out-of-range fuzz input becomes a safe no-op (returns early) instead of a revert -- reverts inside a
// handler call abort the whole run rather than just that one step, which would make the fuzzer spend
// almost all its budget on inputs that never reach interesting states.
contract ReliquifyInvariantHandler is Test {
    DuckReliquify public reliquify;
    address public oldToken;
    address public newToken;
    uint256 public id;
    address public owner;

    address[] public depositors;

    // Ghost totals used ONLY to size fuzzer inputs sensibly (e.g. "don't ask for more than a
    // depositor's real wallet balance") -- never used inside the invariant assertions themselves,
    // which read exclusively from the contract's own public state.
    mapping(address => uint256) public realBalance;

    constructor(DuckReliquify reliquify_, address oldToken_, uint256 id_, address owner_, address[] memory depositors_) {
        reliquify = reliquify_;
        oldToken = oldToken_;
        id = id_;
        owner = owner_;
        depositors = depositors_;
        for (uint256 i; i < depositors_.length; ++i) {
            realBalance[depositors_[i]] = IERC20Invariant(oldToken_).balanceOf(depositors_[i]);
        }
    }

    function setNewToken(address newToken_) external {
        newToken = newToken_;
    }

    function _pick(uint256 seed) private view returns (address) {
        return depositors[seed % depositors.length];
    }

    function handler_depositPreSeed(uint256 depositorSeed, uint256 amountSeed) external {
        (,,,,,, DuckReliquify.MigrationStatus status) = reliquify.getMigration(id);
        if (status != DuckReliquify.MigrationStatus.Live) return;

        address depositor = _pick(depositorSeed);
        uint256 already = reliquify.deposited(id, depositor);
        uint256 cap = reliquify.eligibleBalance(id, depositor);
        if (already >= cap) return;
        uint256 headroom = cap - already;
        uint256 wallet = IERC20Invariant(oldToken).balanceOf(depositor);
        uint256 maxAmount = headroom < wallet ? headroom : wallet;
        if (maxAmount == 0) return;
        uint256 amount = 1 + (amountSeed % maxAmount);

        vm.startPrank(depositor);
        IERC20Invariant(oldToken).approve(address(reliquify), amount);
        reliquify.depositPreSeed(id, amount);
        vm.stopPrank();
    }

    function handler_seedPool() external {
        (,,,,,, DuckReliquify.MigrationStatus status) = reliquify.getMigration(id);
        if (status != DuckReliquify.MigrationStatus.Live) return;
        // getMigration doesn't expose thresholdReached directly -- try/catch rather than duplicate
        // the threshold math here; a too-early call just reverts and is swallowed as a no-op.
        vm.prank(owner);
        try reliquify.seedPool(id, 0) {
            (,, address newToken_,,,,) = reliquify.getMigration(id);
            newToken = newToken_;
        } catch {}
    }

    function handler_depositPostSeed(uint256 depositorSeed, uint256 amountSeed) external {
        (,,,,,, DuckReliquify.MigrationStatus status) = reliquify.getMigration(id);
        if (status != DuckReliquify.MigrationStatus.Seeded) return;

        address depositor = _pick(depositorSeed);
        uint256 already = reliquify.deposited(id, depositor);
        uint256 cap = reliquify.eligibleBalance(id, depositor);
        if (already >= cap) return;
        uint256 headroom = cap - already;
        uint256 wallet = IERC20Invariant(oldToken).balanceOf(depositor);
        uint256 maxAmount = headroom < wallet ? headroom : wallet;
        if (maxAmount == 0) return;
        uint256 amount = 1 + (amountSeed % maxAmount);

        vm.startPrank(depositor);
        IERC20Invariant(oldToken).approve(address(reliquify), amount);
        try reliquify.depositPostSeed(id, amount, 0, 0) {} catch {}
        vm.stopPrank();
    }

    function handler_claim(uint256 depositorSeed) external {
        (,,,,,, DuckReliquify.MigrationStatus status) = reliquify.getMigration(id);
        if (status != DuckReliquify.MigrationStatus.Seeded) return;
        address depositor = _pick(depositorSeed);
        if (reliquify.pendingClaim(id, depositor) == 0) return;
        vm.prank(depositor);
        reliquify.claim(id);
    }

    function depositorCount() external view returns (uint256) {
        return depositors.length;
    }
}

contract DuckReliquifyInvariantForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER    = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant OLD_TOKEN           = 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4; // BTC, 8 decimals

    DuckReliquify reliquify;
    ReliquifyInvariantHandler handler;
    uint256 migrationId;

    address owner = makeAddr("dri-owner");
    address platform = makeAddr("dri-platform");
    address leader = makeAddr("dri-leader");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        vm.startPrank(owner);
        DuckVaultConfig configImpl = new DuckVaultConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), abi.encodeCall(DuckVaultConfig.initialize, (owner)));
        DuckVault vaultImpl = new DuckVault();

        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(DuckHookV4).creationCode, abi.encode(V4_POOL_MANAGER)));
        (bytes32 hookSalt,) = _mineHookSalt(address(hookFactory), initCodeHash);
        address hookAddr = hookFactory.deploy(hookSalt, V4_POOL_MANAGER, owner);
        DuckHookV4 hook = DuckHookV4(payable(hookAddr));
        require(uint160(hookAddr) & 0x3FFF == 0x2CC, "bad hook permission bits");
        hook.setWeth(WETH);
        hook.setPlatformWallet(platform);

        DuckVaultFactory vaultFactoryImpl = new DuckVaultFactory();
        ERC1967Proxy vaultFactoryProxy = new ERC1967Proxy(
            address(vaultFactoryImpl),
            abi.encodeCall(DuckVaultFactory.initialize, (owner, address(vaultImpl), address(configProxy), hookAddr))
        );
        DuckVaultFactory vaultFactory = DuckVaultFactory(address(vaultFactoryProxy));

        DuckReliquifyToken tokenImpl = new DuckReliquifyToken(address(vaultFactory));
        DuckReliquify reliquifyImpl = new DuckReliquify();
        ERC1967Proxy reliquifyProxy = new ERC1967Proxy(
            address(reliquifyImpl),
            abi.encodeCall(DuckReliquify.initialize, (WETH, address(tokenImpl), V4_POOL_MANAGER, V4_POSITION_MANAGER, hookAddr, platform))
        );
        reliquify = DuckReliquify(payable(address(reliquifyProxy)));
        reliquify.setUniversalRouter(UNIVERSAL_ROUTER);

        hook.addLauncher(address(reliquify));
        vaultFactory.setFamily(address(reliquify), true);

        Route[] memory oldTokenRoutes = new Route[](1);
        address[] memory path = new address[](2);
        path[0] = WETH; path[1] = OLD_TOKEN;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        oldTokenRoutes[0] = Route({shape: RouteShape.V3_STYLE, enabled: true, path: path, fees: fees, hook: address(0), fee: 0, tickSpacing: 0});
        reliquify.setRoutes(OLD_TOKEN, oldTokenRoutes);
        vm.stopPrank();

        // Five depositors, deliberately uneven and non-round balances/snapshots -- the fuzzer picks
        // among these, but the interesting numeric edge cases (a depositor whose wallet is SMALLER
        // than their snapshotted cap, one that's LARGER, one exactly equal) come from these fixed
        // starting conditions, not from the fuzzer itself.
        address[] memory depositors = new address[](5);
        uint256[] memory eligibleBalances = new uint256[](5);
        uint256[] memory walletBalances = new uint256[](5);
        for (uint256 i; i < 5; ++i) {
            depositors[i] = makeAddr(string(abi.encodePacked("dri-depositor-", i)));
        }
        eligibleBalances[0] = 17_000_000; eligibleBalances[1] = 5_500_000; eligibleBalances[2] = 23_000_000;
        eligibleBalances[3] = 9_250_000;  eligibleBalances[4] = 1_000_000;
        // depositor 2's real wallet is LESS than their snapshotted cap (partial redemption only
        // possible); depositor 4's wallet is MORE than their cap (extra tokens must never be
        // depositable past the cap).
        walletBalances[0] = 17_000_000; walletBalances[1] = 5_500_000; walletBalances[2] = 10_000_000;
        walletBalances[3] = 9_250_000;  walletBalances[4] = 4_000_000;
        for (uint256 i; i < 5; ++i) {
            deal(OLD_TOKEN, depositors[i], walletBalances[i]);
        }

        vm.prank(leader);
        migrationId = reliquify.proposeMigration(OLD_TOKEN, 200, 10_000, 0, 0);
        vm.prank(leader);
        reliquify.submitSnapshotBatch(migrationId, depositors, eligibleBalances);
        vm.prank(leader);
        reliquify.finalizeSnapshot(migrationId);
        vm.prank(owner);
        address newToken = reliquify.approveMigration(migrationId, "Invariant BTC", "iBTC", "ipfs://test");

        handler = new ReliquifyInvariantHandler(reliquify, OLD_TOKEN, migrationId, owner, depositors);
        handler.setNewToken(newToken);

        // setNewToken is a setup-only helper, not something the fuzzer should ever call itself (it
        // did, with a garbage address, before this exclusion was added -- corrupting the handler's
        // own bookkeeping rather than exercising DuckReliquify at all). Only the four handler_* actions
        // are real fuzz targets.
        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = ReliquifyInvariantHandler.handler_depositPreSeed.selector;
        selectors[1] = ReliquifyInvariantHandler.handler_seedPool.selector;
        selectors[2] = ReliquifyInvariantHandler.handler_depositPostSeed.selector;
        selectors[3] = ReliquifyInvariantHandler.handler_claim.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // The core accounting identity this whole design exists to guarantee: every unit of eligibleSupply
    // is, at all times, in EXACTLY one of three places -- still reserved (nobody has claimed it yet),
    // sitting in a depositor's wallet as an already-paid-out 1:1 redemption (via claim() or
    // depositPostSeed), or still an outstanding pendingClaim promise. Never lost, never double-paid,
    // never conjured from nowhere -- regardless of what random order deposits/seedPool/claims happen
    // in. Read entirely from the deployed contract's OWN public state, not a shadow ghost total.
    function invariant_ReservedPlusPaidPlusPendingEqualsEligibleSupply() public view {
        (,,, uint256 eligibleSupply,, uint256 reserved,) = reliquify.getMigration(migrationId);
        uint256 paidOut;
        uint256 pending;
        address newToken = handler.newToken();
        uint256 n = handler.depositorCount();
        for (uint256 i; i < n; ++i) {
            address depositor = handler.depositors(i);
            pending += reliquify.pendingClaim(migrationId, depositor);
            if (newToken != address(0)) {
                paidOut += IERC20Invariant(newToken).balanceOf(depositor);
            }
        }
        assertEq(reserved + paidOut + pending, eligibleSupply, "reserved + paid-out + pending must always equal eligibleSupply exactly");
    }

    // No depositor's running total can ever exceed what they were actually snapshotted for, no matter
    // how many times the fuzzer calls deposit for them across both pre- and post-seed phases.
    function invariant_NoDepositorExceedsTheirEligibleCap() public view {
        uint256 n = handler.depositorCount();
        for (uint256 i; i < n; ++i) {
            address depositor = handler.depositors(i);
            uint256 depositedAmt = reliquify.deposited(migrationId, depositor);
            uint256 cap = reliquify.eligibleBalance(migrationId, depositor);
            assertLe(depositedAmt, cap, "a depositor's cumulative deposit must never exceed their own snapshotted eligibleBalance");
        }
    }

    function _mineHookSalt(address factory, bytes32 initCodeHash) internal pure returns (bytes32 salt, address predicted) {
        for (uint256 nonce = 0; nonce < 200_000; nonce++) {
            salt = bytes32(nonce);
            predicted = _computeCreate2Address(salt, initCodeHash, factory);
            if (uint160(predicted) & 0x3FFF == 0x2CC) return (salt, predicted);
        }
        revert("hook salt not found");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer) internal pure returns (address addr) {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), initCodeHash)
            addr := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}

// ---------------------------------------------------------------------------------------------
// Second, separate invariant test: abort/refund under randomized multi-depositor sequences. Kept
// apart from the seed/claim handler above rather than folded in as one more random action, since
// abortMigration is only reachable from Live and permanently forecloses seedPool/depositPostSeed/
// claim for that migration -- mixing it in would let an early random "abort" starve the other
// invariant's coverage of the seed/claim path instead of genuinely adding coverage of its own.
// This is exactly the path where the fuzzer (via the Arc mirror of this same test) caught a real
// bug: refundOldToken zeroed deposited[account] but never decremented the migration's own
// totalDeposited, leaving it permanently stale after a refund -- fixed on both trees, verified here.
contract ReliquifyAbortInvariantHandler is Test {
    DuckReliquify public reliquify;
    MockOldTokenReliquifyInvariant public oldToken;
    uint256 public id;
    address public leader;
    bool public aborted;

    address[] public depositors;

    constructor(DuckReliquify reliquify_, MockOldTokenReliquifyInvariant oldToken_, uint256 id_, address leader_, address[] memory depositors_) {
        reliquify = reliquify_;
        oldToken = oldToken_;
        id = id_;
        leader = leader_;
        depositors = depositors_;
    }

    function _pick(uint256 seed) private view returns (address) {
        return depositors[seed % depositors.length];
    }

    function handler_depositPreSeed(uint256 depositorSeed, uint256 amountSeed) external {
        if (aborted) return;
        address depositor = _pick(depositorSeed);
        uint256 already = reliquify.deposited(id, depositor);
        uint256 cap = reliquify.eligibleBalance(id, depositor);
        if (already >= cap) return;
        uint256 headroom = cap - already;
        uint256 wallet = oldToken.balanceOf(depositor);
        uint256 maxAmount = headroom < wallet ? headroom : wallet;
        if (maxAmount == 0) return;
        uint256 amount = 1 + (amountSeed % maxAmount);

        vm.startPrank(depositor);
        oldToken.approve(address(reliquify), amount);
        reliquify.depositPreSeed(id, amount);
        vm.stopPrank();
    }

    function handler_abort() external {
        if (aborted) return;
        vm.prank(leader);
        try reliquify.abortMigration(id) {
            aborted = true;
        } catch {}
    }

    function handler_refund(uint256 depositorSeed) external {
        if (!aborted) return;
        address depositor = _pick(depositorSeed);
        if (reliquify.deposited(id, depositor) == 0) return;
        vm.prank(depositor);
        reliquify.refundOldToken(id);
    }

    function depositorCount() external view returns (uint256) {
        return depositors.length;
    }
}

// Standalone mock, not BTC/deal() -- abort/refund never touches a router or real liquidity, so a
// simple, fully deterministic local ERC20 is cleaner here than taxing the free RPC further.
contract MockOldTokenReliquifyInvariant {
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

// approveMigration checks hook.isLauncher(address(this)) defensively even though this test never
// reaches seedPool (the only place a real hook matters) -- a minimal always-true stand-in avoids
// needing the real live hook/a real addLauncher prank just to get past that one check.
contract MockAlwaysLauncherHook {
    function isLauncher(address) external pure returns (bool) { return true; }
}

contract DuckReliquifyAbortInvariantForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    DuckReliquify reliquify;
    MockOldTokenReliquifyInvariant oldToken;
    ReliquifyAbortInvariantHandler handler;
    uint256 migrationId;

    address owner = makeAddr("dria-owner");
    address platform = makeAddr("dria-platform");
    address leader = makeAddr("dria-leader");

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        address mockHook = address(new MockAlwaysLauncherHook());

        vm.startPrank(owner);
        DuckReliquifyToken tokenImpl = new DuckReliquifyToken(address(0xdead));
        DuckReliquify reliquifyImpl = new DuckReliquify();
        ERC1967Proxy reliquifyProxy = new ERC1967Proxy(
            address(reliquifyImpl),
            abi.encodeCall(DuckReliquify.initialize, (WETH, address(tokenImpl), V4_POOL_MANAGER, V4_POSITION_MANAGER, mockHook, platform))
        );
        reliquify = DuckReliquify(payable(address(reliquifyProxy)));
        vm.stopPrank();

        oldToken = new MockOldTokenReliquifyInvariant();

        address[] memory depositors = new address[](4);
        uint256[] memory eligibleBalances = new uint256[](4);
        uint256[] memory walletBalances = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            depositors[i] = makeAddr(string(abi.encodePacked("dria-depositor-", i)));
        }
        eligibleBalances[0] = 12_000e18; eligibleBalances[1] = 3_400e18;
        eligibleBalances[2] = 8_800e18;  eligibleBalances[3] = 900e18;
        walletBalances[0] = 12_000e18; walletBalances[1] = 3_400e18;
        walletBalances[2] = 5_000e18;  walletBalances[3] = 2_000e18;
        for (uint256 i; i < 4; ++i) {
            oldToken.mint(depositors[i], walletBalances[i]);
        }
        oldToken.mint(makeAddr("dria-rest-of-supply"), 50_000e18);

        vm.prank(leader);
        migrationId = reliquify.proposeMigration(address(oldToken), 200, 10_000, 0, 0);
        vm.prank(leader);
        reliquify.submitSnapshotBatch(migrationId, depositors, eligibleBalances);
        vm.prank(leader);
        reliquify.finalizeSnapshot(migrationId);
        // No hook wired (address(0) v4Hook, matching this test's setUp above) -- fine here, since
        // this invariant never reaches seedPool, which is the only place v4Hook/isLauncher matters.
        vm.prank(owner);
        reliquify.approveMigration(migrationId, "Invariant Abort", "iABT", "ipfs://test");

        handler = new ReliquifyAbortInvariantHandler(reliquify, oldToken, migrationId, leader, depositors);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ReliquifyAbortInvariantHandler.handler_depositPreSeed.selector;
        selectors[1] = ReliquifyAbortInvariantHandler.handler_abort.selector;
        selectors[2] = ReliquifyAbortInvariantHandler.handler_refund.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    function invariant_DepositedSumEqualsMigrationTotalDeposited() public view {
        (,,,, uint256 totalDeposited,,) = reliquify.getMigration(migrationId);
        uint256 sumDeposited;
        uint256 n = handler.depositorCount();
        for (uint256 i; i < n; ++i) {
            sumDeposited += reliquify.deposited(migrationId, handler.depositors(i));
        }
        assertEq(sumDeposited, totalDeposited, "sum of individual deposited[] must equal the migration's own totalDeposited running total, even after refunds");
    }

    function invariant_DepositedNeverExceedsEligibleCap() public view {
        uint256 n = handler.depositorCount();
        for (uint256 i; i < n; ++i) {
            address depositor = handler.depositors(i);
            assertLe(reliquify.deposited(migrationId, depositor), reliquify.eligibleBalance(migrationId, depositor));
        }
    }
}
