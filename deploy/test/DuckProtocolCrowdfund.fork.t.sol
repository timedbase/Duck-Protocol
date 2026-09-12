// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultFactory} from "duck-lending/DuckVaultFactory.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";
import {PoolKey, SwapParams} from "duck-lib/LaunchRouting.sol";

interface IStateViewFork3 {
    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
}

interface IPoolManagerSwapFork3 {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

interface IERC20Fork3 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

contract DuckProtocolCrowdfundForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant V4_STATE_VIEW       = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    address constant USDG                = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
    uint24  constant FEE_TIER            = 0;
    int24   constant TICK_SPACING        = 200;

    DuckCrowdfund crowdfund;
    DuckHookV4 hook;
    DuckToken tokenImpl;
    DuckVaultFactory vaultFactory;

    address owner    = makeAddr("dpc-owner");
    address platform = makeAddr("dpc-platform");
    address creator  = makeAddr("dpc-creator");
    address backer   = makeAddr("dpc-backer");
    address trader   = makeAddr("dpc-trader");

    uint256 private _tokenSaltNonceCursor;
    address private _cbExpected;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        vm.etch(owner, "");
        vm.etch(platform, "");
        vm.etch(creator, "");
        vm.etch(backer, "");
        vm.etch(trader, "");

        vm.startPrank(owner);

        DuckVaultConfig configImpl = new DuckVaultConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl), abi.encodeCall(DuckVaultConfig.initialize, (owner))
        );
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

        tokenImpl = new DuckToken(address(vaultFactory));

        DuckCrowdfund crowdfundImpl = new DuckCrowdfund();
        ERC1967Proxy crowdfundProxy = new ERC1967Proxy(
            address(crowdfundImpl),
            abi.encodeCall(DuckCrowdfund.initialize, (
                WETH, address(tokenImpl),
                V4_POOL_MANAGER, V4_POSITION_MANAGER, hookAddr, platform
            ))
        );
        crowdfund = DuckCrowdfund(payable(address(crowdfundProxy)));
        crowdfund.setVaultFactory(address(vaultFactory));

        hook.addLauncher(address(crowdfund));
        vaultFactory.setFamily(address(crowdfund), true);

        vm.stopPrank();

        vm.deal(creator, 1_000 ether);
        vm.deal(backer, 1_000 ether);
        vm.deal(trader, 1_000 ether);
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
            address predicted = _computeCreate2Address(salt, initCodeHash, address(crowdfund));
            if (uint16(uint160(predicted)) == 0x8888) {
                _tokenSaltNonceCursor = nonce + i + 1;
                return userSalt;
            }
        }
        revert("token salt not found");
    }

    // USDG sits behind an EIP-1967 proxy on Robinhood Chain, and deal()'s
    // brute-force storage-slot search (stdStore) can't find a balance slot
    // to overwrite through that indirection -- pull real balance from a
    // real, large holder instead. The real V4 PoolManager itself holds a
    // large USDG balance (pooled liquidity across every USDG pool), which
    // is more than enough for realistic test amounts.
    function _giveUsdg(address to, uint256 amount) internal {
        vm.prank(V4_POOL_MANAGER);
        IERC20Fork3(USDG).transfer(to, amount);
    }

    function test_NonDefaultSupplyTierProducesRealCorrectSupply() public {
        vm.prank(creator);
        (, address token) = crowdfund.launch{value: 0.0005 ether}(
            "Duck Raise", "DRAISE", "", address(0), 10 ether, 0, _mineTokenSalt(creator), 0, 9000, 1000, 0, 3
        );

        assertEq(DuckToken(payable(token)).totalSupply(), 1_000_000_000_000e18, "tier 3 must resolve to 1T on the real deployed token");
    }

    function test_VaultCreatedAtLaunchButNotLinkedUntilSuccessfulFinalize() public {
        vm.prank(creator);
        (, address token) = crowdfund.launch{value: 0.0005 ether}(
            "Duck Raise", "DRAISE", "", address(0), 10 ether, 0, _mineTokenSalt(creator), 0, 9000, 1000, 0, 0
        );

        address vault = DuckToken(payable(token)).vault();
        assertTrue(vault != address(0), "vault must exist immediately at launch");
        assertFalse(DuckVault(payable(vault)).enabled(), "must not be enabled until a real pool exists");

        vm.prank(backer);
        crowdfund.contribute{value: 10 ether}(0, 0);

        vm.warp(block.timestamp + 2 hours + 1);
        crowdfund.finalize(0);

        assertTrue(DuckVault(payable(vault)).enabled(), "linkPool must have fired during a successful finalize");
        assertEq(DuckVault(payable(vault)).currency(), WETH, "native-quoted campaign must normalize to WETH on the vault");

        (bool finalized, bool succeeded, address campaignToken) = _readCampaignOutcome(0);
        assertTrue(finalized);
        assertTrue(succeeded);
        assertEq(campaignToken, token);

        (uint160 sqrtPriceX96,,,) = IStateViewFork3(V4_STATE_VIEW).getSlot0(DuckVault(payable(vault)).poolId());
        assertGt(sqrtPriceX96, 0, "pool should be initialized with a nonzero price");
    }

    function test_FailedCampaignLeavesVaultPermanentlyUnlinked() public {
        vm.prank(creator);
        (, address token) = crowdfund.launch{value: 0.0005 ether}(
            "Duck Raise", "DRAISE", "", address(0), 100 ether, 0, _mineTokenSalt(creator), 0, 9000, 1000, 0, 0
        );

        address vault = DuckToken(payable(token)).vault();

        vm.prank(backer);
        crowdfund.contribute{value: 1 ether}(0, 0);

        vm.warp(block.timestamp + 2 hours + 1);
        crowdfund.finalize(0);

        (bool finalized, bool succeeded,) = _readCampaignOutcome(0);
        assertTrue(finalized);
        assertFalse(succeeded);
        assertFalse(DuckVault(payable(vault)).enabled(), "a failed campaign must leave the vault unlinked, not error");
    }

    function test_RealSellSwapAfterSuccessfulRaiseSplitsToVault() public {
        vm.prank(creator);
        (, address token) = crowdfund.launch{value: 0.0005 ether}(
            "Duck Raise", "DRAISE", "", address(0), 10 ether, 0, _mineTokenSalt(creator), 0, 5000, 5000, 0, 0
        );

        vm.prank(backer);
        crowdfund.contribute{value: 10 ether}(0, 0);
        vm.warp(block.timestamp + 2 hours + 1);
        crowdfund.finalize(0);

        address vault = DuckToken(payable(token)).vault();
        assertTrue(DuckVault(payable(vault)).enabled());

        vm.prank(backer);
        crowdfund.claim(0);
        uint256 backerTokens = DuckToken(payable(token)).balanceOf(backer);
        assertGt(backerTokens, 0, "backer should be able to claim their pro-rata share after a successful raise");

        vm.prank(backer);
        DuckToken(payable(token)).transfer(trader, backerTokens);

        uint256 reservesBefore = DuckVault(payable(vault)).totalReserves();

        bool tokenIsC0 = token < WETH;
        PoolKey memory key = PoolKey({
            currency0: tokenIsC0 ? token : WETH,
            currency1: tokenIsC0 ? WETH : token,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });

        uint256 sellAmount = backerTokens / 10;
        vm.prank(trader);
        IERC20Fork3(token).approve(address(this), sellAmount);
        _sell(key, token, tokenIsC0, sellAmount, trader);

        bytes32 poolId = DuckVault(payable(vault)).poolId();
        assertGt(hook.accruedFees(poolId), 0, "the sell should have accrued a hook fee");

        hook.claimFees(poolId);

        uint256 reservesAfter = DuckVault(payable(vault)).totalReserves();
        assertGt(reservesAfter, reservesBefore, "vault must have received its 50% cut of the hook fee");
    }

    function test_Erc20QuotedCampaignContributesDirectlyAndNeverSwaps() public {
        uint256 goal = 50_000e6; // USDG has 6 decimals

        vm.prank(owner);
        crowdfund.setQuoteAssetAllowed(USDG, true);

        vm.prank(creator);
        (, address token) = crowdfund.launch{value: 0.0005 ether}(
            "Duck Raise", "DRAISE", "", USDG, goal, 0, _mineTokenSalt(creator), 0, 9000, 1000, 0, 0
        );

        _giveUsdg(backer, goal);
        vm.startPrank(backer);
        IERC20Fork3(USDG).approve(address(crowdfund), goal);
        crowdfund.contribute(0, goal);
        vm.stopPrank();

        assertEq(IERC20Fork3(USDG).balanceOf(address(crowdfund)), goal, "contribution must land directly in the real quote ERC20");
        assertEq(address(crowdfund).balance, 0, "an ERC20-quoted campaign must never hold native currency");

        vm.warp(block.timestamp + 2 hours + 1);
        crowdfund.finalize(0);

        (bool finalized, bool succeeded,) = _readCampaignOutcome(0);
        assertTrue(finalized);
        assertTrue(succeeded, "campaign must succeed with no swap needed -- funds already in the right asset");

        address vault = DuckToken(payable(token)).vault();
        assertTrue(DuckVault(payable(vault)).enabled(), "linkPool must have fired during a successful finalize");
        assertEq(DuckVault(payable(vault)).currency(), USDG, "vault currency must be the real USDG quote asset, confirming no swap ever substituted a different asset");
    }

    function test_Erc20QuotedCampaignRefundsInSameAsset() public {
        uint256 goal = 500_000e6; // USDG has 6 decimals
        uint256 contribution = 10_000e6;

        vm.prank(owner);
        crowdfund.setQuoteAssetAllowed(USDG, true);

        vm.prank(creator);
        crowdfund.launch{value: 0.0005 ether}(
            "Duck Raise", "DRAISE", "", USDG, goal, 0, _mineTokenSalt(creator), 0, 9000, 1000, 0, 0
        );

        _giveUsdg(backer, contribution);
        vm.startPrank(backer);
        IERC20Fork3(USDG).approve(address(crowdfund), contribution);
        crowdfund.contribute(0, contribution);
        vm.stopPrank();

        vm.warp(block.timestamp + 2 hours + 1);
        crowdfund.finalize(0);

        (bool finalized, bool succeeded,) = _readCampaignOutcome(0);
        assertTrue(finalized);
        assertFalse(succeeded, "raise fell short of the goal");

        uint256 balBefore = IERC20Fork3(USDG).balanceOf(backer);
        vm.prank(backer);
        crowdfund.claimRefund(0);
        assertEq(IERC20Fork3(USDG).balanceOf(backer) - balBefore, contribution, "refund must return the real quote ERC20, not native");
    }

    function test_Erc20QuotedCampaignRejectsAttachedNativeValue() public {
        uint256 goal = 50_000e6; // USDG has 6 decimals
        uint256 contribution = 10_000e6;

        vm.prank(owner);
        crowdfund.setQuoteAssetAllowed(USDG, true);

        vm.prank(creator);
        crowdfund.launch{value: 0.0005 ether}(
            "Duck Raise", "DRAISE", "", USDG, goal, 0, _mineTokenSalt(creator), 0, 9000, 1000, 0, 0
        );

        _giveUsdg(backer, contribution);
        vm.startPrank(backer);
        IERC20Fork3(USDG).approve(address(crowdfund), contribution);
        vm.expectRevert(DuckCrowdfund.NativeNotAccepted.selector);
        crowdfund.contribute{value: 1 wei}(0, contribution);
        vm.stopPrank();
    }

    function _readCampaignOutcome(uint256 campaignId) internal view returns (bool finalized, bool succeeded, address token) {
        (, , , , , , bool finalized_, bool succeeded_, address token_) = crowdfund.getCampaignCore(campaignId);
        return (finalized_, succeeded_, token_);
    }

    function _sell(PoolKey memory key, address token, bool tokenIsC0, uint256 amountIn, address trader_) internal {
        _cbExpected = V4_POOL_MANAGER;
        IPoolManagerSwapFork3(V4_POOL_MANAGER).unlock(abi.encode(key, token, tokenIsC0, amountIn, trader_));
        _cbExpected = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == _cbExpected, "unauthorized callback");
        (PoolKey memory key, address token, bool tokenIsC0, uint256 amountIn, address trader_) =
            abi.decode(data, (PoolKey, address, bool, uint256, address));

        int256 delta = IPoolManagerSwapFork3(msg.sender).swap(
            key,
            SwapParams({
                zeroForOne: tokenIsC0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: tokenIsC0 ? 4295128739 + 1 : 1461446703485210103287273052203988822378723970342 - 1
            }),
            ""
        );

        (bool ok,) = token.call(abi.encodeWithSelector(0x23b872dd, trader_, address(this), amountIn));
        require(ok, "transferFrom failed");
        IPoolManagerSwapFork3(msg.sender).sync(token);
        (bool ok2,) = token.call(abi.encodeWithSelector(0xa9059cbb, msg.sender, amountIn));
        require(ok2, "transfer to pool manager failed");
        IPoolManagerSwapFork3(msg.sender).settle();

        address quote = tokenIsC0 ? key.currency1 : key.currency0;
        int128 quoteDelta = tokenIsC0 ? int128(delta) : int128(delta >> 128);
        uint256 amountOut = uint256(uint128(quoteDelta));
        IPoolManagerSwapFork3(msg.sender).take(quote, trader_, amountOut);

        return "";
    }
}
