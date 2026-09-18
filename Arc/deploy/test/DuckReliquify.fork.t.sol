// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {DuckReliquifyToken} from "duck-lib/DuckReliquifyToken.sol";

interface IHookAdminArcFork {
    function owner() external view returns (address);
    function addLauncher(address launcher_) external;
}

// Standalone mock, not Arc's real USDC-at-0x3600 construct: that address mirrors native balances
// through Arc's own execution logic (see test/utils/MockArcUsdc.sol's own comment), which has no
// totalSupply() at all -- approveMigration reads oldToken.totalSupply() directly, so the "old token"
// under test needs to be a real, standard, mintable ERC20. ARC_USDC itself is never balance/
// totalSupply-inspected by DuckReliquify (it's only ever a swap destination/pool currency), so this
// mock's absence of the real ARC_USDC quirks doesn't matter here.
contract MockOldTokenArc {
    string public constant name = "Old Arc Token";
    string public constant symbol = "OLD";
    uint8 public constant decimals = 18;
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

// Covers the bookkeeping logic (identical code to the shared-tree build, already proven end-to-end
// there against real Robinhood liquidity) plus the two things that are genuinely different on Arc:
// no native quote ever, and the adjusted DuckVault.linkPool signature. The full sell-via-router +
// seedPool integration path is NOT exercised here -- Arc has no RouteTables.sol/proven-liquid route
// yet (confirmed: zero configured routes anywhere on Arc's launch contracts, consistent with Arc
// having zero real tokens/campaigns launched so far) -- deferred until a real migration is actually
// proposed and a route can be configured against real liquidity, same as how routes get set up for
// any other Arc launch family today.
contract DuckReliquifyArcForkTest is Test {
    address constant ARC_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant ARC_POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;
    address constant CROWDFUND             = 0x0c8f0f1353f2d963D03C3eC558D20b151DaF7214;
    address constant VAULT_FACTORY         = 0xE3D4d83307E6f5A2C7B4b85436eAacAfd1B873C3;

    DuckReliquify reliquify;
    MockOldTokenArc oldToken;
    address hookAddr;
    address platformWallet;

    address leader  = makeAddr("dra-leader");
    address holder1 = makeAddr("dra-holder1");
    address holder2 = makeAddr("dra-holder2");

    function setUp() public {
        vm.createSelectFork(vm.envString("ARC_RPC_URL"));

        hookAddr = _readAddress(CROWDFUND, "v4Hook()");
        platformWallet = _readAddress(CROWDFUND, "platformWallet()");

        oldToken = new MockOldTokenArc();

        DuckReliquifyToken tokenImpl = new DuckReliquifyToken(VAULT_FACTORY);
        DuckReliquify reliquifyImpl = new DuckReliquify();
        ERC1967Proxy reliquifyProxy = new ERC1967Proxy(
            address(reliquifyImpl),
            abi.encodeCall(DuckReliquify.initialize, (address(tokenImpl), ARC_POOL_MANAGER, ARC_POSITION_MANAGER, hookAddr, platformWallet))
        );
        reliquify = DuckReliquify(payable(address(reliquifyProxy)));
        reliquify.setVaultFactory(VAULT_FACTORY);

        // Real, live hook owner on a fork -- vm.prank can act as any address regardless of who
        // actually controls the key, same as every other fork test in this suite.
        vm.prank(IHookAdminArcFork(hookAddr).owner());
        IHookAdminArcFork(hookAddr).addLauncher(address(reliquify));

        oldToken.mint(holder1, 3_000e18);
        oldToken.mint(holder2, 3_000e18);
    }

    function _readAddress(address target, string memory sig) private returns (address addr) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok, "read failed");
        addr = abi.decode(data, (address));
    }

    function test_SnapshotCorrection_DoesNotDoubleCount() public {
        vm.prank(leader);
        uint256 id = reliquify.proposeMigration(address(oldToken), 200, 10_000, 0, 0);

        address[] memory accounts = new address[](1);
        accounts[0] = holder1;
        uint256[] memory balances = new uint256[](1);
        balances[0] = 100e18;
        vm.prank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        (,,, uint256 supplyAfterFirst,,,) = reliquify.getMigration(id);
        assertEq(supplyAfterFirst, 100e18);

        balances[0] = 250e18;
        vm.prank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        (,,, uint256 supplyAfterCorrection,,,) = reliquify.getMigration(id);
        assertEq(supplyAfterCorrection, 250e18, "a correction must replace the prior value, never add to it");
    }

    function test_ExcludeThenResubmit_Reverts() public {
        vm.prank(leader);
        uint256 id = reliquify.proposeMigration(address(oldToken), 200, 10_000, 0, 0);

        address[] memory accounts = new address[](1);
        accounts[0] = holder1;
        uint256[] memory balances = new uint256[](1);
        balances[0] = 100e18;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        reliquify.submitExclusions(id, accounts);
        (,,, uint256 supplyAfterExclusion,,,) = reliquify.getMigration(id);
        assertEq(supplyAfterExclusion, 0);

        vm.expectRevert(DuckReliquify.AlreadyExcluded.selector);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        vm.stopPrank();
    }

    function test_ApproveMigration_MintsExactOldSupplyAndReservesEligible() public {
        vm.prank(leader);
        uint256 id = reliquify.proposeMigration(address(oldToken), 200, 10_000, 0, 0);

        address[] memory accounts = new address[](2);
        accounts[0] = holder1; accounts[1] = holder2;
        uint256[] memory balances = new uint256[](2);
        balances[0] = 3_000e18; balances[1] = 3_000e18;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        reliquify.finalizeSnapshot(id);
        vm.stopPrank();

        address newToken = reliquify.approveMigration(id, "Reliquified Old", "rOLD", "ipfs://test");
        (,,, uint256 eligibleSupply,, uint256 reserved,) = reliquify.getMigration(id);
        assertEq(eligibleSupply, 6_000e18);
        assertEq(reserved, 6_000e18, "reserved must equal eligibleSupply exactly at approval, untouched by LP sizing");
        (bool ok, bytes memory data) = newToken.staticcall(abi.encodeWithSignature("totalSupply()"));
        require(ok, "new token totalSupply read failed");
        assertEq(abi.decode(data, (uint256)), oldToken.totalSupply(), "new token supply must match old token's real total supply exactly");
    }

    function test_AbortedMigration_RefundsOldToken() public {
        vm.prank(leader);
        uint256 id = reliquify.proposeMigration(address(oldToken), 200, 10_000, 0, 0);

        address[] memory accounts = new address[](2);
        accounts[0] = holder1; accounts[1] = holder2;
        uint256[] memory balances = new uint256[](2);
        balances[0] = 3_000e18; balances[1] = 3_000e18;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        reliquify.finalizeSnapshot(id);
        vm.stopPrank();

        reliquify.approveMigration(id, "Test", "TST", "ipfs://test");

        vm.startPrank(holder1);
        oldToken.approve(address(reliquify), 3_000e18);
        reliquify.depositPreSeed(id, 3_000e18);
        vm.stopPrank();

        // Only holder1 deposited (3_000e18 of a 6_000e18 eligibleSupply) -- never reaches 50%... wait,
        // 3_000/6_000 is exactly 50%, which WOULD reach threshold; abort still works regardless of
        // thresholdReached since abortMigration only checks status == Live, not threshold state.
        vm.prank(leader);
        reliquify.abortMigration(id);

        uint256 balBefore = oldToken.balanceOf(holder1);
        vm.prank(holder1);
        reliquify.refundOldToken(id);
        assertEq(oldToken.balanceOf(holder1) - balBefore, 3_000e18);
    }

    // ---------- rescue ----------

    function _liveMigrationWithHolder1Deposit() private returns (uint256 id, address newToken) {
        vm.prank(leader);
        id = reliquify.proposeMigration(address(oldToken), 200, 10_000, 0, 0);
        address[] memory accounts = new address[](2);
        accounts[0] = holder1; accounts[1] = holder2;
        uint256[] memory balances = new uint256[](2);
        balances[0] = 3_000e18; balances[1] = 3_000e18;
        vm.startPrank(leader);
        reliquify.submitSnapshotBatch(id, accounts, balances);
        reliquify.finalizeSnapshot(id);
        vm.stopPrank();
        newToken = reliquify.approveMigration(id, "Rescue Test", "rTST", "ipfs://test");
        vm.startPrank(holder1);
        oldToken.approve(address(reliquify), 3_000e18);
        reliquify.depositPreSeed(id, 3_000e18);
        vm.stopPrank();
    }

    function test_RescueETH_OwnerOnly_AndMovesStrayNative() public {
        vm.deal(address(reliquify), 1 ether);
        address to = makeAddr("dra-rescue-to");

        vm.prank(holder1);
        vm.expectRevert();
        reliquify.rescueETH(to, 1 ether);

        reliquify.rescueETH(to, 1 ether);
        assertEq(to.balance, 1 ether);
        assertEq(address(reliquify).balance, 0);
    }

    function test_RescueERC20_UnrelatedToken_FullyRescuable() public {
        oldToken.mint(address(reliquify), 500e18);
        address to = makeAddr("dra-rescue-to");
        reliquify.rescueERC20(address(oldToken), to, 500e18);
        assertEq(oldToken.balanceOf(to), 500e18);
    }

    function test_RescueERC20_CannotTouchCommittedDeposits_OnlySurplus() public {
        _liveMigrationWithHolder1Deposit();
        address to = makeAddr("dra-rescue-to");

        vm.expectRevert(DuckReliquify.RescueExceedsSurplus.selector);
        reliquify.rescueERC20(address(oldToken), to, 1);

        oldToken.mint(address(reliquify), 50e18);
        vm.expectRevert(DuckReliquify.RescueExceedsSurplus.selector);
        reliquify.rescueERC20(address(oldToken), to, 50e18 + 1);
        reliquify.rescueERC20(address(oldToken), to, 50e18);
        assertEq(oldToken.balanceOf(to), 50e18);
        assertEq(oldToken.balanceOf(address(reliquify)), 3_000e18, "depositor's custody untouched");
    }

    function test_RescueERC20_AbortedMigrationDeposits_StillProtectedForRefund() public {
        (uint256 id,) = _liveMigrationWithHolder1Deposit();
        vm.prank(leader);
        reliquify.abortMigration(id);

        vm.expectRevert(DuckReliquify.RescueExceedsSurplus.selector);
        reliquify.rescueERC20(address(oldToken), makeAddr("dra-rescue-to"), 1);

        uint256 before = oldToken.balanceOf(holder1);
        vm.prank(holder1);
        reliquify.refundOldToken(id);
        assertEq(oldToken.balanceOf(holder1) - before, 3_000e18, "refund still fully honored");
    }

    function test_RescueERC20_MigrationNewToken_AlwaysRefused() public {
        (, address newToken) = _liveMigrationWithHolder1Deposit();
        vm.expectRevert(DuckReliquify.CannotRescueMigrationToken.selector);
        reliquify.rescueERC20(newToken, makeAddr("dra-rescue-to"), 1);
    }

    function test_RescueERC20_OwnerOnly() public {
        oldToken.mint(address(reliquify), 1e18);
        vm.prank(holder1);
        vm.expectRevert();
        reliquify.rescueERC20(address(oldToken), holder1, 1e18);
    }
}
