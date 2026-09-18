// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

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

interface IERC20ReliquifyFork {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function totalSupply() external view returns (uint256);
}

// Uses a real, already-liquid token (Robinhood's BTC) as the "old token" stand-in -- the whole point
// of Reliquify is migrating tokens duckpad never touched, so there's no protocol-native token to
// exercise this against; BTC's WETH pool (fee 3000) is the same proven-liquid route
// RouteTables.sol/DEPLOYMENT.md already document, reused here rather than guessed. (USDG, the other
// obvious candidate, isn't deal()-compatible -- its balance storage layout doesn't match stdStorage's
// slot-detection heuristic -- confirmed by a throwaway probe test before picking BTC instead.)
contract DuckReliquifyForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant UNIVERSAL_ROUTER    = 0x8876789976dEcBfCbBbe364623C63652db8C0904;
    address constant OLD_TOKEN           = 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4; // BTC
    address constant DEAD                = 0x000000000000000000000000000000000000dEaD;

    DuckReliquify reliquify;
    DuckHookV4 hook;
    DuckVaultFactory vaultFactory;

    address owner    = makeAddr("dr-owner");
    address platform = makeAddr("dr-platform");
    address leader   = makeAddr("dr-leader");
    address holder1  = makeAddr("dr-holder1");
    address holder2  = makeAddr("dr-holder2");
    address holder3  = makeAddr("dr-holder3");

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
        hook = DuckHookV4(payable(hookAddr));
        require(uint160(hookAddr) & 0x3FFF == 0x2CC, "bad hook permission bits");
        hook.setWeth(WETH);
        hook.setPlatformWallet(platform);

        DuckVaultFactory vaultFactoryImpl = new DuckVaultFactory();
        ERC1967Proxy vaultFactoryProxy = new ERC1967Proxy(
            address(vaultFactoryImpl),
            abi.encodeCall(DuckVaultFactory.initialize, (owner, address(vaultImpl), address(configProxy), hookAddr))
        );
        vaultFactory = DuckVaultFactory(address(vaultFactoryProxy));

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

        // Same BTC->WETH v3 route DEPLOYMENT.md/RouteTables.sol already document as proven-liquid.
        Route[] memory oldTokenRoutes = new Route[](1);
        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = OLD_TOKEN;
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        oldTokenRoutes[0] = Route({shape: RouteShape.V3_STYLE, enabled: true, path: path, fees: fees, hook: address(0), fee: 0, tickSpacing: 0});
        reliquify.setRoutes(OLD_TOKEN, oldTokenRoutes);

        vm.stopPrank();

        // Real BTC balances via deal() rather than swapping for it -- a standard ERC20 storage write.
        deal(OLD_TOKEN, holder1, 3e7);
        deal(OLD_TOKEN, holder2, 3e7);
        deal(OLD_TOKEN, holder3, 4e7);
        deal(OLD_TOKEN, DEAD, 1e7);
        // Total real supply the test treats as authoritative: eligible (1e8, in BTC's 8 decimals) + dead (1e7)
        // + whatever else BTC's real totalSupply() already had before this test touched it becomes
        // this migration's lpSupply -- exercised, not hidden, by the assertion in
        // test_FullFlow_PreSeedAndPostSeedDepositsBothRedeemCorrectly.
    }

    function test_FullFlow_PreSeedAndPostSeedDepositsBothRedeemCorrectly() public {
        uint256 oldSupplyBefore = IERC20ReliquifyFork(OLD_TOKEN).totalSupply();
        uint256 deadBefore = IERC20ReliquifyFork(OLD_TOKEN).balanceOf(DEAD);

        vm.prank(leader);
        uint256 id = reliquify.proposeMigration(OLD_TOKEN, 200, 10_000, 0, 0);

        address[] memory accounts = new address[](3);
        accounts[0] = holder1; accounts[1] = holder2; accounts[2] = holder3;
        uint256[] memory balances = new uint256[](3);
        balances[0] = 3e7; balances[1] = 3e7; balances[2] = 4e7;
        vm.prank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        vm.prank(leader);
        reliquify.finalizeSnapshot(id);

        vm.prank(owner);
        address newToken = reliquify.approveMigration(id, "Reliquified BTC", "rBTC", "ipfs://test");

        // eligibleSupply (1e8) always fully reserved regardless of LP sizing -- the bug this
        // redesign fixed. lpSupply is whatever of the OLD token's real supply was neither a real
        // snapshotted depositor nor already dead.
        (,,, uint256 eligibleSupply,,, DuckReliquify.MigrationStatus status) = reliquify.getMigration(id);
        assertEq(eligibleSupply, 1e8, "eligibleSupply must be exactly the three holders' balances");
        assertEq(uint8(status), uint8(DuckReliquify.MigrationStatus.Live));
        assertEq(IERC20ReliquifyFork(newToken).totalSupply(), oldSupplyBefore, "new supply must match old token's real total supply exactly");
        assertEq(IERC20ReliquifyFork(newToken).balanceOf(DEAD), deadBefore, "dead balance must be mirrored 1:1 before any deposit");

        // Pre-seed: holder1 alone doesn't cross 50%, holder2 does.
        vm.startPrank(holder1);
        IERC20ReliquifyFork(OLD_TOKEN).approve(address(reliquify), 3e7);
        reliquify.depositPreSeed(id, 3e7);
        vm.stopPrank();

        vm.startPrank(holder2);
        IERC20ReliquifyFork(OLD_TOKEN).approve(address(reliquify), 3e7);
        reliquify.depositPreSeed(id, 3e7);
        vm.stopPrank();

        vm.prank(owner);
        reliquify.seedPool(id, 0);

        (,,,,,, DuckReliquify.MigrationStatus statusAfterSeed) = reliquify.getMigration(id);
        assertEq(uint8(statusAfterSeed), uint8(DuckReliquify.MigrationStatus.Seeded));

        vm.prank(holder1);
        reliquify.claim(id);
        assertEq(IERC20ReliquifyFork(newToken).balanceOf(holder1), 3e7, "pre-seed depositor must redeem exactly 1:1");

        vm.prank(holder2);
        reliquify.claim(id);
        assertEq(IERC20ReliquifyFork(newToken).balanceOf(holder2), 3e7);

        // Post-seed: holder3 deposits after the pool exists -- sold immediately, minted immediately,
        // proceeds buy back and burn instead of feeding the LP.
        uint256 deadBeforePostSeed = IERC20ReliquifyFork(newToken).balanceOf(DEAD);
        vm.startPrank(holder3);
        IERC20ReliquifyFork(OLD_TOKEN).approve(address(reliquify), 4e7);
        reliquify.depositPostSeed(id, 4e7, 0, 0);
        vm.stopPrank();

        assertEq(IERC20ReliquifyFork(newToken).balanceOf(holder3), 4e7, "post-seed depositor must receive exactly 1:1 immediately");
        assertGt(IERC20ReliquifyFork(newToken).balanceOf(DEAD), deadBeforePostSeed, "post-seed proceeds must have bought back and burned some new token");

        (,,,, uint256 totalDepositedFinal, uint256 reservedFinal,) = reliquify.getMigration(id);
        assertEq(totalDepositedFinal, 1e8, "every eligible token must have been depositable");
        assertEq(reservedFinal, 0, "reserved must be exactly exhausted, never negative, never short");
    }

    function test_SnapshotCorrection_DoesNotDoubleCount() public {
        vm.prank(leader);
        uint256 id = reliquify.proposeMigration(OLD_TOKEN, 200, 10_000, 0, 0);

        address[] memory accounts = new address[](1);
        accounts[0] = holder1;
        uint256[] memory balances = new uint256[](1);
        balances[0] = 100e18;
        vm.prank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        (,,, uint256 supplyAfterFirst,,,) = reliquify.getMigration(id);
        assertEq(supplyAfterFirst, 100e18);

        // Correction: same address, different (higher) balance -- must replace, not add.
        balances[0] = 250e18;
        vm.prank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        (,,, uint256 supplyAfterCorrection,,,) = reliquify.getMigration(id);
        assertEq(supplyAfterCorrection, 250e18, "a correction must replace the prior value, never add to it");
    }

    function test_ExcludeThenResubmit_Reverts() public {
        vm.prank(leader);
        uint256 id = reliquify.proposeMigration(OLD_TOKEN, 200, 10_000, 0, 0);

        address[] memory accounts = new address[](1);
        accounts[0] = holder1;
        uint256[] memory balances = new uint256[](1);
        balances[0] = 100e18;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        reliquify.submitExclusions(id, accounts);
        (,,, uint256 supplyAfterExclusion,,,) = reliquify.getMigration(id);
        assertEq(supplyAfterExclusion, 0, "excluding a snapshotted address must remove its balance from eligibleSupply");

        vm.expectRevert(DuckReliquify.AlreadyExcluded.selector);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        vm.stopPrank();
    }

    function test_AbortedMigration_RefundsOldToken() public {
        vm.prank(leader);
        uint256 id = reliquify.proposeMigration(OLD_TOKEN, 200, 10_000, 0, 0);

        address[] memory accounts = new address[](1);
        accounts[0] = holder1;
        uint256[] memory balances = new uint256[](1);
        balances[0] = 3e7;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        reliquify.finalizeSnapshot(id);
        vm.stopPrank();

        vm.prank(owner);
        reliquify.approveMigration(id, "Test", "TST", "ipfs://test");

        vm.startPrank(holder1);
        IERC20ReliquifyFork(OLD_TOKEN).approve(address(reliquify), 3e7);
        reliquify.depositPreSeed(id, 3e7);
        vm.stopPrank();

        // Never reaches 50% of a much larger eligibleSupply that never got submitted for other
        // holders in this scenario -- aborted before seedPool.
        vm.prank(leader);
        reliquify.abortMigration(id);

        uint256 balBefore = IERC20ReliquifyFork(OLD_TOKEN).balanceOf(holder1);
        vm.prank(holder1);
        reliquify.refundOldToken(id);
        assertEq(IERC20ReliquifyFork(OLD_TOKEN).balanceOf(holder1) - balBefore, 3e7, "aborted migration must refund the full deposited amount");
    }

    // ---------- rescue ----------

    function _liveMigrationWithHolder1Deposit() private returns (uint256 id, address newToken) {
        vm.prank(leader);
        id = reliquify.proposeMigration(OLD_TOKEN, 200, 10_000, 0, 0);
        address[] memory accounts = new address[](2);
        accounts[0] = holder1; accounts[1] = holder2;
        uint256[] memory balances = new uint256[](2);
        balances[0] = 3e7; balances[1] = 3e7;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        reliquify.finalizeSnapshot(id);
        vm.stopPrank();
        vm.prank(owner);
        newToken = reliquify.approveMigration(id, "Rescue Test", "rTST", "ipfs://test");
        vm.startPrank(holder1);
        IERC20ReliquifyFork(OLD_TOKEN).approve(address(reliquify), 3e7);
        reliquify.depositPreSeed(id, 3e7);
        vm.stopPrank();
    }

    function test_RescueETH_OwnerOnly_AndMovesStrayEth() public {
        vm.deal(address(reliquify), 1 ether);
        address to = makeAddr("dr-rescue-to");

        vm.prank(holder1);
        vm.expectRevert();
        reliquify.rescueETH(to, 1 ether);

        vm.prank(owner);
        reliquify.rescueETH(to, 1 ether);
        assertEq(to.balance, 1 ether);
        assertEq(address(reliquify).balance, 0);
    }

    function test_RescueERC20_UnrelatedToken_FullyRescuable() public {
        // No migration exists yet, so nothing is committed against OLD_TOKEN -- it's just a stray token.
        deal(OLD_TOKEN, address(reliquify), 5e6);
        address to = makeAddr("dr-rescue-to");
        vm.prank(owner);
        reliquify.rescueERC20(OLD_TOKEN, to, 5e6);
        assertEq(IERC20ReliquifyFork(OLD_TOKEN).balanceOf(to), 5e6);
    }

    function test_RescueERC20_CannotTouchCommittedDeposits_OnlySurplus() public {
        _liveMigrationWithHolder1Deposit();
        address to = makeAddr("dr-rescue-to");
        uint256 held = IERC20ReliquifyFork(OLD_TOKEN).balanceOf(address(reliquify));
        assertEq(held, 3e7);

        vm.prank(owner);
        vm.expectRevert(DuckReliquify.RescueExceedsSurplus.selector);
        reliquify.rescueERC20(OLD_TOKEN, to, 1);

        // Someone mistakenly sends 5e6 extra: exactly that surplus is recoverable, not one unit more.
        deal(OLD_TOKEN, address(reliquify), held + 5e6);
        vm.prank(owner);
        vm.expectRevert(DuckReliquify.RescueExceedsSurplus.selector);
        reliquify.rescueERC20(OLD_TOKEN, to, 5e6 + 1);
        vm.prank(owner);
        reliquify.rescueERC20(OLD_TOKEN, to, 5e6);
        assertEq(IERC20ReliquifyFork(OLD_TOKEN).balanceOf(to), 5e6);
        assertEq(IERC20ReliquifyFork(OLD_TOKEN).balanceOf(address(reliquify)), held, "depositor's custody untouched");
    }

    function test_RescueERC20_AbortedMigrationDeposits_StillProtectedForRefund() public {
        (uint256 id,) = _liveMigrationWithHolder1Deposit();
        vm.prank(leader);
        reliquify.abortMigration(id);

        address to = makeAddr("dr-rescue-to");
        vm.prank(owner);
        vm.expectRevert(DuckReliquify.RescueExceedsSurplus.selector);
        reliquify.rescueERC20(OLD_TOKEN, to, 1);

        vm.prank(holder1);
        reliquify.refundOldToken(id);
        assertEq(IERC20ReliquifyFork(OLD_TOKEN).balanceOf(holder1), 3e7, "refund still fully honored");
    }

    function test_RescueERC20_MigrationNewToken_AlwaysRefused() public {
        (, address newToken) = _liveMigrationWithHolder1Deposit();
        vm.prank(owner);
        vm.expectRevert(DuckReliquify.CannotRescueMigrationToken.selector);
        reliquify.rescueERC20(newToken, makeAddr("dr-rescue-to"), 1);
    }

    function test_RescueERC20_OwnerOnly() public {
        deal(OLD_TOKEN, address(reliquify), 5e6);
        vm.prank(holder1);
        vm.expectRevert();
        reliquify.rescueERC20(OLD_TOKEN, holder1, 5e6);
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
