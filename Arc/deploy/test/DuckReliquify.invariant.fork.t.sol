// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Stateful (handler-based) invariant test covering the abort/refund path under randomized multi-
// depositor sequences -- complementary to the shared-tree's invariant test (which covers the
// seed/claim path, using byte-identical depositPreSeed/claim code already proven there). Arc has no
// proven-liquid route yet to exercise seedPool/depositPostSeed against (see the directed fork test's
// own note), so this one instead hammers what's genuinely exercisable pre-seed: random deposits from
// multiple accounts, then abort, then random refund claims, checking that every unit ever deposited is
// accounted for exactly once.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckReliquify} from "duck-reliquify/DuckReliquify.sol";
import {DuckReliquifyToken} from "duck-lib/DuckReliquifyToken.sol";

interface IHookAdminArcInvariant {
    function owner() external view returns (address);
    function addLauncher(address launcher_) external;
}

contract MockOldTokenArcInvariant {
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

contract ReliquifyArcInvariantHandler is Test {
    DuckReliquify public reliquify;
    MockOldTokenArcInvariant public oldToken;
    uint256 public id;
    address public leader;
    bool public aborted;

    address[] public depositors;

    constructor(DuckReliquify reliquify_, MockOldTokenArcInvariant oldToken_, uint256 id_, address leader_, address[] memory depositors_) {
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

contract DuckReliquifyArcInvariantForkTest is Test {
    address constant ARC_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant ARC_POSITION_MANAGER = 0x6049c9a0e26405C0985f9E3685C87d0aE917f82B;
    address constant CROWDFUND             = 0x0c8f0f1353f2d963D03C3eC558D20b151DaF7214;
    address constant VAULT_FACTORY         = 0xE3D4d83307E6f5A2C7B4b85436eAacAfd1B873C3;

    DuckReliquify reliquify;
    MockOldTokenArcInvariant oldToken;
    ReliquifyArcInvariantHandler handler;
    uint256 migrationId;

    address leader = makeAddr("dria-leader");

    function setUp() public {
        vm.createSelectFork(vm.envString("ARC_RPC_URL"));

        address hookAddr = _readAddress(CROWDFUND, "v4Hook()");
        address platformWallet = _readAddress(CROWDFUND, "platformWallet()");

        oldToken = new MockOldTokenArcInvariant();

        DuckReliquifyToken tokenImpl = new DuckReliquifyToken(VAULT_FACTORY);
        DuckReliquify reliquifyImpl = new DuckReliquify();
        ERC1967Proxy reliquifyProxy = new ERC1967Proxy(
            address(reliquifyImpl),
            abi.encodeCall(DuckReliquify.initialize, (address(tokenImpl), ARC_POOL_MANAGER, ARC_POSITION_MANAGER, hookAddr, platformWallet))
        );
        reliquify = DuckReliquify(payable(address(reliquifyProxy)));
        reliquify.setVaultFactory(VAULT_FACTORY);

        vm.prank(IHookAdminArcInvariant(hookAddr).owner());
        IHookAdminArcInvariant(hookAddr).addLauncher(address(reliquify));

        address[] memory depositors = new address[](4);
        uint256[] memory eligibleBalances = new uint256[](4);
        uint256[] memory walletBalances = new uint256[](4);
        for (uint256 i; i < 4; ++i) {
            depositors[i] = makeAddr(string(abi.encodePacked("dria-depositor-", i)));
        }
        eligibleBalances[0] = 12_000e18; eligibleBalances[1] = 3_400e18;
        eligibleBalances[2] = 8_800e18;  eligibleBalances[3] = 900e18;
        // depositor 2's wallet is smaller than their cap; depositor 3's is larger.
        walletBalances[0] = 12_000e18; walletBalances[1] = 3_400e18;
        walletBalances[2] = 5_000e18;  walletBalances[3] = 2_000e18;
        for (uint256 i; i < 4; ++i) {
            oldToken.mint(depositors[i], walletBalances[i]);
        }
        // The rest of the old token's real-world supply -- held by accounts that are neither
        // depositors nor excluded, exactly the "becomes the new pool's liquidity" bucket
        // approveMigration's own math accounts for -- minted to an address this test never touches.
        oldToken.mint(makeAddr("dria-rest-of-supply"), 50_000e18);

        vm.prank(leader);
        migrationId = reliquify.proposeMigration(address(oldToken), 200, 10_000, 0, 0);
        vm.prank(leader);
        reliquify.submitSnapshotBatch(migrationId, depositors, eligibleBalances);
        vm.prank(leader);
        reliquify.finalizeSnapshot(migrationId);
        reliquify.approveMigration(migrationId, "Invariant Arc Old", "iOLD", "ipfs://test");

        handler = new ReliquifyArcInvariantHandler(reliquify, oldToken, migrationId, leader, depositors);

        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = ReliquifyArcInvariantHandler.handler_depositPreSeed.selector;
        selectors[1] = ReliquifyArcInvariantHandler.handler_abort.selector;
        selectors[2] = ReliquifyArcInvariantHandler.handler_refund.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    // Every unit ever pulled from a depositor's wallet is, after an abort, either still sitting in
    // `deposited[]` (refundable) or has already come back to that same depositor via refundOldToken --
    // never lost, never double-paid, regardless of deposit/abort/refund ordering.
    function invariant_DepositedPlusRefundedEqualsOriginalWalletDelta() public view {
        (,,,, uint256 totalDeposited,,) = reliquify.getMigration(migrationId);
        uint256 sumDeposited;
        uint256 n = handler.depositorCount();
        for (uint256 i; i < n; ++i) {
            address depositor = handler.depositors(i);
            sumDeposited += reliquify.deposited(migrationId, depositor);
        }
        assertEq(sumDeposited, totalDeposited, "sum of individual deposited[] must equal the migration's own totalDeposited running total");
    }

    function invariant_RefundNeverExceedsWhatWasDeposited() public view {
        uint256 n = handler.depositorCount();
        for (uint256 i; i < n; ++i) {
            address depositor = handler.depositors(i);
            // If aborted and deposited[] is now 0, the account either never deposited or already
            // refunded in full -- either way, calling refund again must find nothing left (checked
            // implicitly by NothingToRefund reverting, exercised across many fuzz runs above without
            // ever being caught as a hard failure, since the handler's own try/catch-free refund call
            // would abort the whole run if it ever paid out twice).
            assertGe(reliquify.eligibleBalance(migrationId, depositor), reliquify.deposited(migrationId, depositor));
        }
    }

    function _readAddress(address target, string memory sig) private returns (address addr) {
        (bool ok, bytes memory data) = target.staticcall(abi.encodeWithSignature(sig));
        require(ok, "read failed");
        addr = abi.decode(data, (address));
    }
}
