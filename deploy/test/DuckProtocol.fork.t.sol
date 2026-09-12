// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultFactory} from "duck-lending/DuckVaultFactory.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";
import {TokenConfig, FeeSplit} from "duck-lib/DuckTypes.sol";

interface IStateViewFork {
    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

interface IERC721BalanceFork {
    function balanceOf(address owner) external view returns (uint256);
}

contract DuckProtocolForkTest is Test {

    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant V4_STATE_VIEW       = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant DEAD                = 0x000000000000000000000000000000000000dEaD;

    DuckBondingCurve curve;
    DuckHookV4 hook;
    DuckToken tokenImpl;
    DuckVaultFactory vaultFactory;
    DuckVaultConfig vaultConfig;

    address owner        = makeAddr("owner");
    address feeRecipient = makeAddr("feeRecipient");
    address platform     = makeAddr("platform");
    address buyer        = makeAddr("buyer");
    address creator      = makeAddr("creator");

    uint256 private _tokenSaltNonceCursor;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        vm.etch(owner, "");
        vm.etch(feeRecipient, "");
        vm.etch(platform, "");
        vm.etch(buyer, "");
        vm.etch(creator, "");

        vm.startPrank(owner);

        DuckVaultConfig configImpl = new DuckVaultConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl), abi.encodeCall(DuckVaultConfig.initialize, (owner))
        );
        vaultConfig = DuckVaultConfig(address(configProxy));

        DuckVault vaultImpl = new DuckVault();

        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 hookInitCodeHash = keccak256(abi.encodePacked(
            type(DuckHookV4).creationCode,
            abi.encode(V4_POOL_MANAGER)
        ));
        (bytes32 hookSalt,) = _mineHookSalt(address(hookFactory), hookInitCodeHash);
        address hookAddr = hookFactory.deploy(hookSalt, V4_POOL_MANAGER, owner);
        hook = DuckHookV4(payable(hookAddr));
        require(uint160(hookAddr) & 0x3FFF == 0x2CC, "bad hook permission bits");

        DuckVaultFactory vaultFactoryImpl = new DuckVaultFactory();
        ERC1967Proxy vaultFactoryProxy = new ERC1967Proxy(
            address(vaultFactoryImpl),
            abi.encodeCall(DuckVaultFactory.initialize, (owner, address(vaultImpl), address(vaultConfig), hookAddr))
        );
        vaultFactory = DuckVaultFactory(address(vaultFactoryProxy));

        tokenImpl = new DuckToken(address(vaultFactory));

        DuckBondingCurve curveImpl = new DuckBondingCurve();
        ERC1967Proxy curveProxy = new ERC1967Proxy(
            address(curveImpl),
            abi.encodeCall(DuckBondingCurve.initialize, (
                WETH, V4_POSITION_MANAGER, V4_POOL_MANAGER,
                hookAddr, feeRecipient, address(tokenImpl)
            ))
        );
        curve = DuckBondingCurve(payable(address(curveProxy)));
        curve.setVaultFactory(address(vaultFactory));

        hook.addLauncher(address(curve));
        vaultFactory.setFamily(address(curve), true);

        vm.stopPrank();

        vm.deal(buyer, 1_000 ether);
        vm.deal(creator, 10 ether);
    }

    function _mineHookSalt(address factory, bytes32 initCodeHash)
        internal pure returns (bytes32 salt, address predicted)
    {
        for (uint256 nonce = 0; nonce < 200_000; nonce++) {
            salt = bytes32(nonce);
            predicted = _computeCreate2Address(salt, initCodeHash, factory);
            if (uint160(predicted) & 0x3FFF == 0x2CC) return (salt, predicted);
        }
        revert("hook salt not found");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer)
        internal pure returns (address addr)
    {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), initCodeHash)
            addr := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _saltFor(address creator_, bytes32 userSalt) internal pure returns (bytes32 salt) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, creator_)
            mstore(add(ptr, 32), userSalt)
            salt := keccak256(ptr, 64)
        }
    }

    function _mineTokenSalt(address creator_) internal returns (bytes32 userSalt) {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            address(tokenImpl),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 initCodeHash = keccak256(initCode);
        uint256 nonce = _tokenSaltNonceCursor;
        for (uint256 i = 0; i < 1_000_000; i++) {
            userSalt = bytes32(nonce + i);
            bytes32 salt = _saltFor(creator_, userSalt);
            address predicted = _computeCreate2Address(salt, initCodeHash, address(curve));
            if (uint16(uint160(predicted)) == 0x8888) {
                _tokenSaltNonceCursor = nonce + i + 1;
                return userSalt;
            }
        }
        revert("token salt not found");
    }

    function _baseParams(uint256 startVirtual, uint256 migrationTarget, uint16 vaultBps, bytes32 salt)
        internal pure returns (DuckBondingCurve.BaseParams memory p)
    {
        p.name                 = "Test Token";
        p.symbol               = "TEST";
        p.supplyTier            = 0;
        p.curveBps             = 8_000;
        p.liquidityBps         = 2_000;
        p.quoteToken           = address(0);
        p.startVirtualQuote    = startVirtual;
        p.migrationTargetQuote = migrationTarget;
        p.earlyBuyAmount       = 0;
        p.hookFeeBps           = 0;
        // creatorBps + vaultBps + burnBps must sum to exactly 10_000 -- burnBps stays 0 here, so
        // creator gets whatever vaultBps doesn't, same as every existing caller of this helper
        // already expects.
        p.creatorBps           = 10_000 - vaultBps;
        p.vaultBps             = vaultBps;
        p.metaURI              = "";
        p.salt                 = salt;
    }

    function _readTokenConfig(address token) internal view returns (
        address quoteToken, uint256 bcTokensSold, uint256 raisedQuote,
        bytes32 poolId, uint256 accruedFee, uint16 vaultBps,
        bool migrated, bool migrationPending
    ) {
        TokenConfig memory tc = curve.getTokenConfig(token);
        return (tc.quoteToken, tc.bcTokensSold, tc.raisedQuote, tc.poolId, tc.accruedFee, tc.vaultBps, tc.migrated, tc.migrationPending);
    }

    function test_VaultCreatedAtTokenCreation() public {
        DuckBondingCurve.BaseParams memory p = _baseParams(1 ether, 10 ether, 1000, _mineTokenSalt(creator));

        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        address vault = DuckToken(payable(token)).vault();
        assertTrue(vault != address(0), "vault must exist immediately, before any pool does");
        assertEq(DuckVault(payable(vault)).creator(), creator);
        assertFalse(DuckVault(payable(vault)).enabled(), "must not be enabled -- no pool exists pre-migration");
    }

    // The vault/creator/burn three-way split (vaultBps/creatorBps/burnBps) governs only the HOOK's
    // post-migration trading fee (see DuckHookV4.claimFees) -- a vault is never funded from the
    // pre-migration bonding-curve fee, regardless of vaultBps. claimCurveFee splits 100% of the
    // curve fee between creator and platform only.
    function test_CurveFeeNeverSplitsToVaultRegardlessOfVaultBps() public {
        DuckBondingCurve.BaseParams memory p = _baseParams(1 ether, 10 ether, 1000, _mineTokenSalt(creator));
        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        vm.prank(buyer);
        curve.buy{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);
        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);

        (, , , , , , bool migrated, ) = _readTokenConfig(token);
        assertTrue(migrated);

        address vault = DuckToken(payable(token)).vault();
        uint256 reservesBeforeClaim = DuckVault(payable(vault)).totalReserves();

        (, , , , uint256 accruedFeeFinal, , , ) = _readTokenConfig(token);
        assertGt(accruedFeeFinal, 0, "curve fee should have accrued from both buys");

        uint256 creatorBefore = creator.balance;
        curve.claimCurveFee(token);

        uint256 reservesAfterClaim = DuckVault(payable(vault)).totalReserves();
        assertEq(reservesAfterClaim, reservesBeforeClaim, "claiming the curve fee must never move anything into the vault");
        assertEq(creator.balance - creatorBefore, accruedFeeFinal / 2, "creator must receive their full, undiminished half of the curve fee");
    }

    function test_MigrationLinksVaultToRealPool() public {
        DuckBondingCurve.BaseParams memory p = _baseParams(1 ether, 10 ether, 5000, _mineTokenSalt(creator));
        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        vm.prank(buyer);
        curve.buy{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);
        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);

        (, , , bytes32 poolId, , , bool migrated, ) = _readTokenConfig(token);
        assertTrue(migrated);

        address vault = DuckToken(payable(token)).vault();
        assertTrue(DuckVault(payable(vault)).enabled(), "linkPool must have fired synchronously during migrate()");
        assertEq(DuckVault(payable(vault)).poolId(), poolId);
        assertEq(DuckVault(payable(vault)).currency(), WETH, "native-quoted curve must normalize to WETH, never native, on the vault");

        (uint160 sqrtPriceX96,,,) = IStateViewFork(V4_STATE_VIEW).getSlot0(poolId);
        assertGt(sqrtPriceX96, 0, "pool should be initialized with a nonzero price");

        assertGt(
            IERC721BalanceFork(V4_POSITION_MANAGER).balanceOf(DEAD), 0,
            "migration should have minted a real LP position, permanently burned to DEAD"
        );
    }

    function test_ZeroVaultBpsMeansCreatorKeepsEverything() public {
        DuckBondingCurve.BaseParams memory p = _baseParams(1 ether, 10 ether, 0, _mineTokenSalt(creator));
        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        // Vault/lending is opt-in: vaultBps == 0 means no vault is ever deployed for this token at
        // all, not just that it receives a zero cut.
        assertEq(DuckToken(payable(token)).vault(), address(0), "0 vaultBps must mean no vault is deployed at all");

        vm.prank(buyer);
        curve.buy{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);
        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);

        (, , , , uint256 accruedFeeBeforeClaim, , , ) = _readTokenConfig(token);
        assertGt(accruedFeeBeforeClaim, 0, "migration should have left a real curve fee to claim");

        curve.claimCurveFee(token);

        assertEq(DuckToken(payable(token)).vault(), address(0), "claiming fees must never retroactively deploy a vault");
    }

    // Hard fork stress test: real token launches and real buys from many distinct wallets, not the
    // single-creator/single-buyer shape every other test in this file uses. Specifically hammers the
    // curve-fee/vault fix above (test_CurveFeeNeverSplitsToVaultRegardlessOfVaultBps) at scale --
    // across 20 real tokens, spanning every vaultBps value from 0% to 100%, each migrated and its
    // curve fee claimed by different wallets, confirming the invariant holds for every one of them,
    // not just a single hand-picked case.
    function test_HardFork_ManyTokensManyWalletsCurveFeeNeverLeaksToVault() public {
        uint256 NUM_TOKENS = 20;
        uint256 NUM_TRADERS = 15;
        uint16[6] memory vaultBpsCycle = [uint16(0), 1000, 3000, 5000, 7000, 10_000];

        address[] memory creators = new address[](NUM_TOKENS);
        address[] memory traders = new address[](NUM_TRADERS);
        for (uint256 i = 0; i < NUM_TOKENS; i++) {
            creators[i] = makeAddr(string.concat("hf-creator-", vm.toString(i)));
            vm.deal(creators[i], 10 ether);
        }
        for (uint256 i = 0; i < NUM_TRADERS; i++) {
            traders[i] = makeAddr(string.concat("hf-trader-", vm.toString(i)));
            vm.deal(traders[i], 100 ether);
        }

        address[] memory tokens = new address[](NUM_TOKENS);
        address[] memory vaults = new address[](NUM_TOKENS);

        for (uint256 i = 0; i < NUM_TOKENS; i++) {
            uint16 vb = vaultBpsCycle[i % 6];
            DuckBondingCurve.BaseParams memory p = _baseParams(1 ether, 10 ether, vb, _mineTokenSalt(creators[i]));
            vm.prank(creators[i]);
            tokens[i] = curve.createToken{value: 0.0005 ether}(p);
            vaults[i] = DuckToken(payable(tokens[i])).vault();
            assertEq(vaults[i] == address(0), vb == 0, "vault must exist iff vaultBps > 0, for every token in the batch");
        }

        // Two distinct traders per token, cycled from a shared pool of 15 -- realistic "many wallets
        // revisiting many tokens" shape rather than one buyer per token.
        for (uint256 i = 0; i < NUM_TOKENS; i++) {
            address traderA = traders[i % NUM_TRADERS];
            address traderB = traders[(i + 7) % NUM_TRADERS];
            vm.prank(traderA);
            curve.buy{value: 1 ether}(tokens[i], 0, 0, block.timestamp + 1 hours);
            vm.prank(traderB);
            curve.buy{value: 50 ether}(tokens[i], 0, 0, block.timestamp + 1 hours);
        }

        uint256 totalCreatorGain;
        uint256 platformBefore = feeRecipient.balance;

        for (uint256 i = 0; i < NUM_TOKENS; i++) {
            (, , , , , , bool migrated, ) = _readTokenConfig(tokens[i]);
            assertTrue(migrated, "every token in the batch must have migrated given these buy sizes");

            uint256 vaultReservesBefore = vaults[i] == address(0) ? 0 : DuckVault(payable(vaults[i])).totalReserves();
            (, , , , uint256 accruedFee, , , ) = _readTokenConfig(tokens[i]);
            assertGt(accruedFee, 0, "every migrated token must have a real curve fee to claim");

            uint256 creatorBefore = creators[i].balance;
            curve.claimCurveFee(tokens[i]);

            uint256 vaultReservesAfter = vaults[i] == address(0) ? 0 : DuckVault(payable(vaults[i])).totalReserves();
            assertEq(
                vaultReservesAfter, vaultReservesBefore,
                "claiming the curve fee must never move funds into the vault, at ANY vaultBps -- vault is hook-funded only"
            );

            uint256 creatorGain = creators[i].balance - creatorBefore;
            assertEq(creatorGain, accruedFee / 2, "creator must receive exactly half the curve fee regardless of vaultBps");
            totalCreatorGain += creatorGain;
        }

        uint256 totalPlatformGain = feeRecipient.balance - platformBefore;
        assertGt(totalPlatformGain, 0, "platform must have collected its half across every claim in the batch");
        assertApproxEqAbs(
            totalPlatformGain, totalCreatorGain, NUM_TOKENS,
            "aggregate platform and creator takes must match within integer-division dust across the whole batch"
        );
    }

    // Regression test for a fee-split reentrancy bug found during a fresh audit of the launchpad:
    // BondingCurveMath._distributeFeeSplits used to take a live `FeeSplit[] storage` reference and
    // pay each split with its own external call (native .call for a native-quoted curve). A creator
    // who lists a contract they control as one of their own split wallets could, from that
    // contract's receive() hook mid-payout, reenter DuckBondingCurve.setFeeSplits (gated only by
    // caller == creator, which their own contract satisfies) and replace not-yet-paid split entries
    // with attacker-controlled wallets -- stealing from co-recipients (e.g. a co-founder) they'd
    // originally configured. Fixed by snapshotting the splits into memory before the payout loop
    // (see BondingCurveMath._distributeFeeSplits and DuckBondingCurve.claimCurveFee). This test
    // proves the fix: the co-founder's share must land correctly despite the reentrant attempt.
    function test_FeeSplitReentrancy_CannotRedirectCoRecipientsShareMidPayout() public {
        MaliciousFeeSplitCreator attacker = new MaliciousFeeSplitCreator(curve);
        vm.deal(address(attacker), 10 ether);
        address legitCoFounder = makeAddr("legitCoFounder");
        address attackerLoot = makeAddr("attackerLoot");

        DuckBondingCurve.BaseParams memory p = _baseParams(1 ether, 10 ether, 0, _mineTokenSalt(address(attacker)));
        address token = attacker.createTokenAndConfigureSplits{value: 0.0005 ether}(p, legitCoFounder, attackerLoot);

        vm.prank(buyer);
        curve.buy{value: 1 ether}(token, 0, 0, block.timestamp + 1 hours);
        vm.prank(buyer);
        curve.buy{value: 50 ether}(token, 0, 0, block.timestamp + 1 hours);

        (, , , , uint256 accruedFeeFinal, , bool migrated, ) = _readTokenConfig(token);
        assertTrue(migrated);
        assertGt(accruedFeeFinal, 0);

        curve.claimCurveFee(token);

        assertTrue(attacker.reentered(), "the reentrant setFeeSplits attempt must actually have fired");
        assertGt(legitCoFounder.balance, 0, "the co-founder's originally-configured share must still be paid");
        assertEq(attackerLoot.balance, 0, "the reentrant replacement must NOT have redirected anything to the attacker");
    }
}

contract MaliciousFeeSplitCreator {
    DuckBondingCurve public curve;
    address public token;
    address public legitCoFounder;
    address public attackerLoot;
    bool public reentered;

    constructor(DuckBondingCurve curve_) {
        curve = curve_;
    }

    function createTokenAndConfigureSplits(
        DuckBondingCurve.BaseParams memory p, address legitCoFounder_, address attackerLoot_
    ) external payable returns (address t) {
        t = curve.createToken{value: msg.value}(p);
        token = t;
        legitCoFounder = legitCoFounder_;
        attackerLoot = attackerLoot_;

        FeeSplit[] memory splits = new FeeSplit[](2);
        splits[0] = FeeSplit({wallet: address(this), bps: 5000});
        splits[1] = FeeSplit({wallet: legitCoFounder_, bps: 5000});
        curve.setFeeSplits(t, splits);
    }

    receive() external payable {
        if (!reentered && token != address(0)) {
            reentered = true;
            FeeSplit[] memory malicious = new FeeSplit[](2);
            malicious[0] = FeeSplit({wallet: address(this), bps: 5000});
            malicious[1] = FeeSplit({wallet: attackerLoot, bps: 5000});
            curve.setFeeSplits(token, malicious);
        }
    }
}
