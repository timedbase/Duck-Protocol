// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckLauncher} from "duck-launcher/DuckLauncher.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultFactory} from "duck-lending/DuckVaultFactory.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";
import {PoolKey, SwapParams} from "duck-lib/LaunchRouting.sol";

interface IPoolManagerSwapFork4 {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

interface IERC20Fork4 {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
    function transfer(address, uint256) external returns (bool);
}

interface IWETHFork4 {
    function approve(address, uint256) external returns (bool);
    function balanceOf(address) external view returns (uint256);
}

contract DuckProtocolLendingForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    address constant V4_STATE_VIEW       = 0xF3334192D15450CdD385c8B70e03f9A6bD9E673b;
    uint24  constant FEE_TIER            = 0;
    int24   constant TICK_SPACING        = 200;

    DuckLauncher launcher;
    DuckHookV4 hook;
    DuckToken tokenImpl;
    DuckVaultFactory vaultFactory;

    address owner    = makeAddr("dplend-owner");
    address platform = makeAddr("dplend-platform");
    address creator  = makeAddr("dplend-creator");
    address borrower = makeAddr("dplend-borrower");
    address liquidator = makeAddr("dplend-liquidator");

    address token;
    address vault;
    PoolKey poolKey;
    bool tokenIsC0;

    uint256 private _tokenSaltNonceCursor;
    address private _cbExpected;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        vm.etch(owner, "");
        vm.etch(platform, "");
        vm.etch(creator, "");
        vm.etch(borrower, "");
        vm.etch(liquidator, "");

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
        hook.setStateView(V4_STATE_VIEW);

        DuckVaultFactory vaultFactoryImpl = new DuckVaultFactory();
        ERC1967Proxy vaultFactoryProxy = new ERC1967Proxy(
            address(vaultFactoryImpl),
            abi.encodeCall(DuckVaultFactory.initialize, (owner, address(vaultImpl), address(configProxy), hookAddr))
        );
        vaultFactory = DuckVaultFactory(address(vaultFactoryProxy));

        tokenImpl = new DuckToken(address(vaultFactory));

        DuckLauncher launcherImpl = new DuckLauncher();
        ERC1967Proxy launcherProxy = new ERC1967Proxy(
            address(launcherImpl),
            abi.encodeCall(DuckLauncher.initialize, (
                WETH, address(tokenImpl), platform,
                V4_POSITION_MANAGER, V4_POOL_MANAGER, hookAddr
            ))
        );
        launcher = DuckLauncher(payable(address(launcherProxy)));
        launcher.setVaultFactory(address(vaultFactory));

        hook.addLauncher(address(launcher));
        vaultFactory.setFamily(address(launcher), true);

        vm.stopPrank();

        vm.deal(creator, 1_000 ether);
        vm.deal(borrower, 1_000 ether);
        vm.deal(liquidator, 1_000 ether);

        _launchAndFundBorrower();
    }

    function _launchAndFundBorrower() internal {
        DuckLauncher.LaunchParams memory p;
        p.name = "Duck Lend";
        p.symbol = "DLEND";
        p.metaURI = "";
        p.feeWallet = address(0);
        p.positionManager = V4_POSITION_MANAGER;
        p.quoteToken = address(0);
        p.vanitySalt = _mineTokenSalt(creator);
        p.launchMarketCap = 200 ether;
        p.minQuoteOut = 0;
        p.minTokensOut = 0;
        p.hookFeeBps = 0;
        // Vault/lending is opt-in as of the vaultBps==0-skips-vault-deployment change -- this whole
        // test file is about borrowing against a real vault, so it needs one to actually exist.
        p.vaultBps = 10_000;
        p.revertOnInstantBuyFailure = false;

        vm.prank(creator);
        (token,) = launcher.launch{value: 0.0005 ether + 1 ether}(p);

        vault = DuckToken(payable(token)).vault();
        tokenIsC0 = token < address(0) ? true : false;
        tokenIsC0 = false;

        poolKey = PoolKey({
            currency0: address(0),
            currency1: token,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });

        uint256 creatorTokens = DuckToken(payable(token)).balanceOf(creator);
        vm.startPrank(creator);
        DuckToken(payable(token)).transfer(borrower, creatorTokens / 2);
        DuckToken(payable(token)).transfer(liquidator, creatorTokens / 10);
        vm.stopPrank();
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
            address predicted = _computeCreate2Address(salt, initCodeHash, address(launcher));
            if (uint16(uint160(predicted)) == 0x8888) {
                _tokenSaltNonceCursor = nonce + i + 1;
                return userSalt;
            }
        }
        revert("token salt not found");
    }

    function _pokeOracle(address from, uint256 amount) internal {
        vm.prank(from);
        IERC20Fork4(token).approve(address(this), amount);
        _cbExpected = V4_POOL_MANAGER;
        IPoolManagerSwapFork4(V4_POOL_MANAGER).unlock(abi.encode(false, amount, from));
        _cbExpected = address(0);
    }

    function _realBuy(uint256 nativeIn) internal {
        vm.deal(address(this), nativeIn);
        _cbExpected = V4_POOL_MANAGER;
        IPoolManagerSwapFork4(V4_POOL_MANAGER).unlock(abi.encode(true, nativeIn, address(this)));
        _cbExpected = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == _cbExpected, "unauthorized callback");
        (bool isBuy, uint256 amountIn, address trader_) = abi.decode(data, (bool, uint256, address));

        if (isBuy) {
            int256 buyDelta = IPoolManagerSwapFork4(msg.sender).swap(
                poolKey,
                SwapParams({
                    zeroForOne: true,
                    amountSpecified: -int256(amountIn),
                    sqrtPriceLimitX96: 4295128740
                }),
                ""
            );

            uint256 actualNativeIn = uint256(uint128(-int128(buyDelta >> 128)));
            IPoolManagerSwapFork4(msg.sender).settle{value: actualNativeIn}();
            uint256 tokenOut = uint256(uint128(int128(buyDelta)));
            IPoolManagerSwapFork4(msg.sender).take(token, trader_, tokenOut);
            return "";
        }

        int256 delta = IPoolManagerSwapFork4(msg.sender).swap(
            poolKey,
            SwapParams({
                zeroForOne: false,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: 1461446703485210103287273052203988822378723970342 - 1
            }),
            ""
        );

        uint256 actualTokenIn = uint256(uint128(-int128(delta)));

        (bool ok,) = token.call(abi.encodeWithSelector(0x23b872dd, trader_, address(this), actualTokenIn));
        require(ok, "transferFrom failed");
        IPoolManagerSwapFork4(msg.sender).sync(token);
        (bool ok2,) = token.call(abi.encodeWithSelector(0xa9059cbb, msg.sender, actualTokenIn));
        require(ok2, "transfer to pool manager failed");
        IPoolManagerSwapFork4(msg.sender).settle();

        int128 nativeDelta = int128(delta >> 128);
        uint256 amountOut = uint256(uint128(nativeDelta));
        IPoolManagerSwapFork4(msg.sender).take(address(0), trader_, amountOut);

        return "";
    }

    function _buildOracleHistory() internal {

        uint256 t = block.timestamp;
        uint256 b = block.number;
        for (uint256 i = 1; i <= 10; i++) {
            vm.warp(t + i * 1_800);
            vm.roll(b + i);
            _pokeOracle(liquidator, 1e18);
        }
    }

    function _fundVault(uint256 amount) internal {
        deal(WETH, address(launcher), amount);
        vm.prank(address(launcher));
        IWETHFork4(WETH).approve(vault, type(uint256).max);
        vm.prank(address(launcher));
        DuckVault(payable(vault)).depositFees(amount);
    }

    function test_BorrowAgainstRealLaunchedTokenWithRealTwap() public {
        _buildOracleHistory();
        _fundVault(10 ether);

        vm.prank(borrower);
        DuckToken(payable(token)).approve(vault, type(uint256).max);
        vm.prank(borrower);
        DuckVault(payable(vault)).addCollateral(1_000_000e18);

        uint256 healthBefore = DuckVault(payable(vault)).healthFactorBps(borrower);
        assertEq(healthBefore, type(uint256).max, "no debt yet -- health factor must report max");

        uint256 borrowerNativeBefore = borrower.balance;
        vm.prank(borrower);
        DuckVault(payable(vault)).borrow(0.01 ether);

        assertEq(borrower.balance, borrowerNativeBefore, "borrow pays out WETH (an ERC20), not native");
        assertEq(IWETHFork4(WETH).balanceOf(borrower), 0.01 ether, "borrower should hold real WETH from the real vault");

        uint256 health = DuckVault(payable(vault)).healthFactorBps(borrower);
        assertGt(health, 10_000, "a small borrow against ample collateral must stay healthy");
    }

    function test_ExcessiveBorrowRevertsEvenWithRealTwapAndLiquidity() public {
        _buildOracleHistory();
        _fundVault(10 ether);

        vm.prank(borrower);
        DuckToken(payable(token)).approve(vault, type(uint256).max);
        vm.prank(borrower);
        DuckVault(payable(vault)).addCollateral(1_000_000e18);

        vm.prank(borrower);
        vm.expectRevert(DuckVault.ExceedsMaxLtv.selector);
        DuckVault(payable(vault)).borrow(5 ether);
    }

    function test_TriggerBuybackExecutesRealSwapAndBurn() public {
        _buildOracleHistory();
        _fundVault(10 ether);

        vm.prank(borrower);
        DuckToken(payable(token)).approve(vault, type(uint256).max);
        vm.prank(borrower);
        DuckVault(payable(vault)).addCollateral(1_000_000e18);

        vm.prank(borrower);
        DuckVault(payable(vault)).borrow(0.01 ether);

        vm.warp(block.timestamp + 90 days);

        vm.prank(borrower);
        IWETHFork4(WETH).approve(vault, type(uint256).max);
        deal(WETH, borrower, 1 ether);
        vm.prank(borrower);
        DuckVault(payable(vault)).repay(type(uint128).max);

        uint256 pendingBefore = DuckVault(payable(vault)).pendingBuyback();
        assertGt(pendingBefore, 0, "real interest over 90 days should have earmarked a nonzero buyback cut");

        address DEAD = 0x000000000000000000000000000000000000dEaD;
        uint256 deadBalanceBefore = IERC20Fork4(token).balanceOf(DEAD);

        // Advance a block: the 90-day warp above only moved block.timestamp, not block.number, so
        // without this the buyback's own swap would land in the same block as _buildOracleHistory's
        // last swap -- fine under a real 90-day gap (obviously many real blocks would have passed),
        // but the hook's SameBlockSwap guard keys on tx.origin, which Foundry's vm.prank doesn't vary,
        // so same block + same tx.origin here would look like the same trader swapping twice.
        vm.roll(block.number + 1);
        uint256 burned = DuckVault(payable(vault)).triggerBuyback();

        assertGt(burned, 0, "the real swap should have bought a nonzero amount of the token");
        assertEq(IERC20Fork4(token).balanceOf(DEAD), deadBalanceBefore + burned, "the bought-back tokens must actually be burned");
        assertLt(DuckVault(payable(vault)).pendingBuyback(), pendingBefore, "pendingBuyback must shrink by what was swept");
    }

    function _maxSafeBorrow() internal returns (uint256 maxAmt) {

        uint256 lo = 0.01 ether;
        uint256 hi = 5 ether;
        for (uint256 i = 0; i < 30; i++) {
            uint256 mid = (lo + hi) / 2;
            uint256 snap = vm.snapshotState();
            vm.prank(borrower);
            try DuckVault(payable(vault)).borrow(mid) {
                lo = mid;
            } catch {
                hi = mid;
            }
            vm.revertToState(snap);
        }
        maxAmt = lo;
    }

    function _dumpHeldStashUntilLiquidatable() internal {
        uint256 total = DuckToken(payable(token)).balanceOf(address(this));
        uint256 chunk = total / 20;
        uint256 t = block.timestamp;
        uint256 b = block.number;

        for (uint256 i = 1; i <= 20; i++) {
            vm.warp(t + i * 1_800);
            vm.roll(b + i);
            _pokeOracle(address(this), chunk);
            if (DuckVault(payable(vault)).healthFactorBps(borrower) < 10_000) return;
        }
    }

    function test_LiquidationTriggersOnRealSustainedPriceCrash() public {

        vm.warp(block.timestamp + 60);
        vm.roll(block.number + 1);
        _realBuy(150 ether);

        _buildOracleHistory();
        _fundVault(10 ether);

        vm.prank(borrower);
        DuckToken(payable(token)).approve(vault, type(uint256).max);
        vm.prank(borrower);
        DuckVault(payable(vault)).addCollateral(1_000_000e18);

        uint256 borrowAmount = _maxSafeBorrow();
        vm.prank(borrower);
        DuckVault(payable(vault)).borrow(borrowAmount);

        uint256 healthBefore = DuckVault(payable(vault)).healthFactorBps(borrower);
        assertGt(healthBefore, 10_000, "a max-LTV borrow must still be healthy the instant it's opened");

        _dumpHeldStashUntilLiquidatable();

        uint256 healthAfter = DuckVault(payable(vault)).healthFactorBps(borrower);
        assertLt(healthAfter, 10_000, "a real, sustained sell-off must be able to push a max-LTV position underwater");

        (uint128 collBefore, uint128 principalBefore,,) = DuckVault(payable(vault)).loans(borrower);
        assertGt(principalBefore, 0, "borrower must still show real outstanding debt going into liquidation");

        deal(WETH, liquidator, 10 ether);
        vm.prank(liquidator);
        IWETHFork4(WETH).approve(vault, type(uint256).max);

        uint256 liquidatorTokensBefore = IERC20Fork4(token).balanceOf(liquidator);

        vm.prank(liquidator);
        DuckVault(payable(vault)).liquidate(borrower, type(uint256).max);

        (uint128 collAfter, uint128 principalAfter,,) = DuckVault(payable(vault)).loans(borrower);
        assertLt(collAfter, collBefore, "liquidation must have seized real collateral from the borrower's position");
        assertLt(principalAfter, principalBefore, "liquidation must have cleared real debt");
        assertGt(
            IERC20Fork4(token).balanceOf(liquidator), liquidatorTokensBefore,
            "the liquidator must actually receive the seized collateral token"
        );
    }

    // Immediately after launch, minPoolAge (defaults to 24h -- see DuckVaultConfig) is now the
    // first thing that blocks a borrow, a fresh-audit fix: it used to be configured but never
    // actually enforced, so nothing stopped borrowing against a pool the instant it existed. The
    // oracle itself would ALSO correctly refuse (see DuckHookOracle.t.sol's own dedicated coverage
    // for that fix), but minPoolAge is checked first and is the more fundamental of the two gates.
    function test_RealOracleDegradesGracefullyWithoutHistory() public {

        _fundVault(10 ether);

        vm.prank(borrower);
        DuckToken(payable(token)).approve(vault, type(uint256).max);
        vm.prank(borrower);
        DuckVault(payable(vault)).addCollateral(1_000_000e18);

        vm.prank(borrower);
        vm.expectRevert(DuckVault.PoolTooYoung.selector);
        DuckVault(payable(vault)).borrow(1 ether);
    }

    receive() external payable {}
}
