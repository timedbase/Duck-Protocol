// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — LaunchRouting (Arc)
//
// How the launch contracts turn native USDC into a launch's quote asset and back. Arc is a stablechain:
// native USDC and the USDC ERC-20 are one balance, so for USDC this is a unit conversion with no swap and
// nothing to wrap. Any other ERC-20 quote asset trades against USDC in a Uniswap v4 pool, through Arc's
// Universal Router with USDC paid in via Permit2 (Arc's router is the build whose exact-input-single swap
// takes the extra minHopPriceX36 field). StablechainsLaunchRouting is the only routing library in this tree,
// so it is the only one a deploy can link.
//
// Direct v4 PoolManager access is kept only for the protocol's own liquidity provisioning and buy-and-burn,
// which touch pools it already controls.

import {ARC_USDC, NATIVE_PER_USDC} from "./ArcChain.sol";

interface IERC20ApprovalRouting {
    function approve(address spender, uint256 amount) external returns (bool);
    function allowance(address owner, address spender) external view returns (uint256);
}

interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
    function allowance(address user, address token, address spender)
        external view returns (uint160 amount, uint48 expiration, uint48 nonce);
}

interface IUniversalRouter {
    function execute(bytes calldata commands, bytes[] calldata inputs, uint256 deadline) external payable;
}

interface IERC20BalanceRouting {
    function balanceOf(address account) external view returns (uint256);
}

struct PoolKey {
    address currency0;
    address currency1;
    uint24  fee;
    int24   tickSpacing;
    address hooks;
}

struct SwapParams {
    bool    zeroForOne;
    int256  amountSpecified;
    uint160 sqrtPriceLimitX96;
}

struct ModifyLiquidityParams {
    int24   tickLower;
    int24   tickUpper;
    int256  liquidityDelta;
    bytes32 salt;
}

// Liquidity provisioning plus swap() -- the latter is kept only for the internal buy-and-burn, against a
// pool the calling contract already controls (see file header).
interface IV4PoolManagerLiquidity {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feeDelta);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

// Universal Router's V4_SWAP decodes SWAP_EXACT_IN_SINGLE's params as one ABI-encoded STRUCT. It carries a `bytes`, so
// it is dynamic: abi.encode(struct) leads with an offset word that a flat abi.encode(a, b, c, ...) of the same fields
// does not have, and the router would read the pool's first currency as that offset. Arc's router is the same build
// as Robinhood Chain's, so the struct has its extra minHopPriceX36 field before hookData.
struct ExactInSingleArc {
    PoolKey poolKey;
    bool    zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes   hookData;
}

// A USDC <-> quote-asset pool on Arc's Uniswap v4. Its currencies are USDC and the quote asset the route is
// registered under, so only the rest of the pool key is stored.
struct Route {
    bool    enabled;
    address hook;
    uint24  fee;
    int24   tickSpacing;
}

interface ILaunchRoutingSelf {
    function executeSwapRoute(
        Route calldata route_, address universalRouter, address quoteToken_, bool buyQuote_,
        uint256 amountIn_, uint256 minOut_, address recipient_
    ) external returns (uint256 amountOut);
}

// External library (delegatecall) so DuckBondingCurve/DuckLauncher/DuckCrowdfund don't each inline a copy --
// same pattern as BondingCurveMath/BondingCurveMigration.
library StablechainsLaunchRouting {
    error TransferFailed();
    error RouterNotConfigured();
    error InsufficientOutput();

    event RouteSucceeded(address indexed quoteToken, uint256 indexed routeIndex, uint256 amountOut);

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    uint256 private constant CMD_V4_SWAP                 = 0x10;
    uint256 private constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 private constant ACTION_SETTLE_ALL           = 0x0c;
    uint256 private constant ACTION_TAKE_ALL             = 0x0f;

    // Native USDC in (value the caller already holds), quoteToken_ out. For USDC nothing moves unless the
    // recipient is someone else: the native already is the caller's USDC, only the units change. Dust under
    // one ERC-20 unit (1e-6 USDC) has no ERC-20 form and stays with the caller. Other quote assets try each
    // enabled route in order, via a self-call so try/catch can isolate a failing one.
    function acquireQuoteToken(
        Route[] storage list, address universalRouter, address quoteToken_, uint256 nativeIn_, uint256 minOut_, address recipient_
    ) external returns (uint256 amountOut, bool ok) {
        uint256 usdcIn = nativeIn_ / NATIVE_PER_USDC;
        if (usdcIn == 0) return (0, false);
        if (quoteToken_ == ARC_USDC) {
            if (usdcIn < minOut_) return (0, false);
            if (recipient_ != address(this)) _safeTransfer(ARC_USDC, recipient_, usdcIn);
            return (usdcIn, true);
        }
        for (uint256 i; i < list.length; ++i) {
            if (!list[i].enabled) continue;
            try ILaunchRoutingSelf(address(this)).executeSwapRoute(
                list[i], universalRouter, quoteToken_, true, usdcIn, minOut_, recipient_
            ) returns (uint256 out) {
                emit RouteSucceeded(quoteToken_, i, out);
                return (out, true);
            } catch {}
        }
        return (0, false);
    }

    // Reverse of acquireQuoteToken: quoteToken_ in, native USDC out, amountOut in native units (18 decimals).
    // USDC leaves as an ERC-20 transfer, which the recipient holds as native.
    function disposeQuoteToken(
        Route[] storage list, address universalRouter, address quoteToken_, uint256 quoteIn_, uint256 minNativeOut_, address recipient_
    ) external returns (uint256 amountOut, bool ok) {
        if (quoteIn_ == 0) return (0, false);
        if (quoteToken_ == ARC_USDC) {
            amountOut = quoteIn_ * NATIVE_PER_USDC;
            if (amountOut < minNativeOut_) return (0, false);
            if (recipient_ != address(this)) _safeTransfer(ARC_USDC, recipient_, quoteIn_);
            return (amountOut, true);
        }
        uint256 minUsdcOut = (minNativeOut_ + NATIVE_PER_USDC - 1) / NATIVE_PER_USDC;
        for (uint256 i; i < list.length; ++i) {
            if (!list[i].enabled) continue;
            try ILaunchRoutingSelf(address(this)).executeSwapRoute(
                list[i], universalRouter, quoteToken_, false, quoteIn_, minUsdcOut, recipient_
            ) returns (uint256 usdcOut) {
                emit RouteSucceeded(quoteToken_, i, usdcOut * NATIVE_PER_USDC);
                return (usdcOut * NATIVE_PER_USDC, true);
            } catch {}
        }
        return (0, false);
    }

    // One route, one direction, through the Universal Router: buyQuote_ = USDC -> quoteToken_, otherwise
    // quoteToken_ -> USDC. TAKE_ALL pays whoever called execute() (this contract), so what arrives is
    // measured and forwarded when recipient_ is someone else.
    function executeSwapRoute(
        Route calldata route_, address universalRouter, address quoteToken_, bool buyQuote_,
        uint256 amountIn_, uint256 minOut_, address recipient_
    ) external returns (uint256 amountOut) {
        // A void-return call to an address with no code would silently no-op instead of reverting.
        if (universalRouter.code.length == 0) revert RouterNotConfigured();

        address currencyIn  = buyQuote_ ? ARC_USDC : quoteToken_;
        address currencyOut = buyQuote_ ? quoteToken_ : ARC_USDC;
        bool zeroForOne = currencyIn < currencyOut;
        PoolKey memory key = PoolKey({
            currency0:   zeroForOne ? currencyIn  : currencyOut,
            currency1:   zeroForOne ? currencyOut : currencyIn,
            fee:         route_.fee,
            tickSpacing: route_.tickSpacing,
            hooks:       route_.hook
        });

        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(ExactInSingleArc(key, zeroForOne, uint128(amountIn_), uint128(minOut_), 0, ""));
        params[1] = abi.encode(currencyIn, amountIn_);
        params[2] = abi.encode(currencyOut, minOut_);
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(
            abi.encodePacked(uint8(ACTION_SWAP_EXACT_IN_SINGLE), uint8(ACTION_SETTLE_ALL), uint8(ACTION_TAKE_ALL)),
            params
        );

        _ensurePermit2Approved(currencyIn, universalRouter);
        uint256 balBefore = IERC20BalanceRouting(currencyOut).balanceOf(address(this));
        IUniversalRouter(universalRouter).execute(abi.encodePacked(uint8(CMD_V4_SWAP)), inputs, block.timestamp);
        amountOut = IERC20BalanceRouting(currencyOut).balanceOf(address(this)) - balBefore;
        if (amountOut < minOut_) revert InsufficientOutput();
        if (recipient_ != address(this)) _safeTransfer(currencyOut, recipient_, amountOut);
    }

    function _ensurePermit2Approved(address token_, address universalRouter) private {
        if (IERC20ApprovalRouting(token_).allowance(address(this), PERMIT2) < type(uint256).max / 2) {
            // Low-level, tolerant of non-standard ERC20s that return no bool -- same pattern as _safeTransfer.
            (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0x095ea7b3, PERMIT2, type(uint256).max));
            if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        }
        (uint160 amount, uint48 expiration,) = IPermit2Approve(PERMIT2).allowance(address(this), token_, universalRouter);
        if (amount < type(uint160).max / 2 || expiration <= block.timestamp) {
            IPermit2Approve(PERMIT2).approve(token_, universalRouter, type(uint160).max, type(uint48).max);
        }
    }

    function _safeTransfer(address token_, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}

abstract contract LaunchRouting {

    error Unauthorized();
    error TransferFailed();
    error InsufficientOutput();
    error NativeQuoteUnsupported();

    uint160 private constant ROUTING_MIN_SQRT_PRICE = 4295128739;
    uint160 private constant ROUTING_MAX_SQRT_PRICE = 1461446703485210103287273052203988822378723970342;
    uint8   private constant ROUTING_OP_SWAP          = 1;
    uint8   private constant ROUTING_OP_ADD_LIQUIDITY = 2;

    mapping(address => Route[]) public routes;
    address public universalRouter;

    event RouteSucceeded(address indexed quoteToken, uint256 indexed routeIndex, uint256 amountOut);
    event RoutesSet(address indexed quoteToken, uint256 count);
    event UniversalRouterUpdated(address indexed router);

    address private _cbExpected;

    function _setRoutes(address quoteToken_, Route[] memory routes_) internal {
        delete routes[quoteToken_];
        for (uint256 i; i < routes_.length; ++i) {
            routes[quoteToken_].push(routes_[i]);
        }
        emit RoutesSet(quoteToken_, routes_.length);
    }

    // Every quote asset on Arc is an ERC-20. address(0) would name native USDC, which is ARC_USDC itself;
    // accepting it would bring native-currency pools and a second, 18-decimal unit of USDC into the protocol.
    function _requireQuoteSupported(address quote_) internal pure {
        if (quote_ == address(0)) revert NativeQuoteUnsupported();
    }

    function _setUniversalRouter(address router_) internal {
        universalRouter = router_;
        emit UniversalRouterUpdated(router_);
    }

    function _acquireQuoteToken(address quoteToken_, uint256 nativeIn_, uint256 minOut_, address recipient_)
        internal returns (uint256 amountOut, bool ok)
    {
        (amountOut, ok) = StablechainsLaunchRouting.acquireQuoteToken(routes[quoteToken_], universalRouter, quoteToken_, nativeIn_, minOut_, recipient_);
    }

    // Reverse of _acquireQuoteToken: a held quote balance out as native USDC (sellForNative).
    function _disposeQuoteToken(address quoteToken_, uint256 quoteIn_, uint256 minNativeOut_, address recipient_)
        internal returns (uint256 amountOut, bool ok)
    {
        (amountOut, ok) = StablechainsLaunchRouting.disposeQuoteToken(routes[quoteToken_], universalRouter, quoteToken_, quoteIn_, minNativeOut_, recipient_);
    }

    // Self-call entry point: the library calls back in here so try/catch can catch a bad route's revert and
    // move on to the next one.
    function executeSwapRoute(
        Route calldata route_, address universalRouter_, address quoteToken_, bool buyQuote_,
        uint256 amountIn_, uint256 minOut_, address recipient_
    ) external returns (uint256 amountOut) {
        if (msg.sender != address(this)) revert Unauthorized();
        amountOut = StablechainsLaunchRouting.executeSwapRoute(route_, universalRouter_, quoteToken_, buyQuote_, amountIn_, minOut_, recipient_);
    }

    // Liquidity straight into the PoolManager singleton -- no PositionManager, Permit2, or position NFT. The
    // position is keyed by (owner, tickLower, tickUpper, salt) with owner = the calling contract, so it stays
    // locked as long as that contract never calls modifyLiquidity to remove it (and DuckGenesisHook refuses
    // removal outright).
    function _mintFullRangeDirect(
        address singleton_,
        PoolKey memory key,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity
    ) internal returns (uint256 amount0, uint256 amount1) {
        _cbExpected = singleton_;
        bytes memory result = IV4PoolManagerLiquidity(singleton_).unlock(
            abi.encode(ROUTING_OP_ADD_LIQUIDITY, abi.encode(key, tickLower, tickUpper, liquidity))
        );
        _cbExpected = address(0);
        (amount0, amount1) = abi.decode(result, (uint256, uint256));
    }

    // Internal buy-and-burn only: swaps directly against a pool this contract already controls.
    function _executeV4Swap(
        address singleton_,
        address hook_,
        uint24  fee_,
        int24   tickSpacing_,
        address currencyIn_,
        address currencyOut_,
        uint256 amountIn_,
        uint256 minOut_,
        address recipient_
    ) internal returns (uint256 amountOut) {
        _cbExpected = singleton_;
        bytes memory result = IV4PoolManagerLiquidity(singleton_).unlock(
            abi.encode(ROUTING_OP_SWAP, abi.encode(hook_, fee_, tickSpacing_, currencyIn_, currencyOut_, amountIn_, minOut_, recipient_))
        );
        _cbExpected = address(0);
        amountOut = abi.decode(result, (uint256));
    }

    // Self-call wrapper for library callers (BondingCurveMigration) running via delegatecall: their
    // address(this) is already this contract, so the call resolves back into _mintFullRangeDirect.
    function mintFullRangeDirect(address singleton_, PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external returns (uint256 amount0, uint256 amount1)
    {
        if (msg.sender != address(this)) revert Unauthorized();
        return _mintFullRangeDirect(singleton_, key, tickLower, tickUpper, liquidity);
    }

    // Reached from both _mintFullRangeDirect (liquidity add) and _executeV4Swap (internal buy-and-burn) --
    // the op tag prefixed to the unlock() payload tells them apart.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (_cbExpected == address(0) || msg.sender != _cbExpected) revert Unauthorized();
        (uint8 op, bytes memory payload) = abi.decode(data, (uint8, bytes));
        if (op == ROUTING_OP_SWAP) return _handleSwapCallback(payload);

        (PoolKey memory key, int24 tickLower, int24 tickUpper, uint128 liquidity) =
            abi.decode(payload, (PoolKey, int24, int24, uint128));

        (int256 callerDelta, ) = IV4PoolManagerLiquidity(msg.sender).modifyLiquidity(
            key,
            ModifyLiquidityParams({tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: int256(uint256(liquidity)), salt: bytes32(0)}),
            ""
        );

        // BalanceDelta packs signed amount0 high, amount1 low. Adding liquidity means we owe the pool, so
        // both come back <= 0; negate to get what to pay in.
        uint256 amount0 = uint256(uint128(-int128(callerDelta >> 128)));
        uint256 amount1 = uint256(uint128(-int128(callerDelta)));

        _settleCurrency(key.currency0, amount0);
        _settleCurrency(key.currency1, amount1);

        return abi.encode(amount0, amount1);
    }

    function _handleSwapCallback(bytes memory data) private returns (bytes memory) {
        (address hook_, uint24 fee_, int24 tickSpacing_, address currencyIn_, address currencyOut_, uint256 amountIn_, uint256 minOut_, address recipient_) =
            abi.decode(data, (address, uint24, int24, address, address, uint256, uint256, address));

        bool zeroForOne = currencyIn_ < currencyOut_;
        PoolKey memory key = PoolKey({
            currency0:   zeroForOne ? currencyIn_  : currencyOut_,
            currency1:   zeroForOne ? currencyOut_ : currencyIn_,
            fee:         fee_,
            tickSpacing: tickSpacing_,
            hooks:       hook_
        });
        int256 delta = IV4PoolManagerLiquidity(msg.sender).swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -int256(amountIn_),
                sqrtPriceLimitX96: zeroForOne ? ROUTING_MIN_SQRT_PRICE + 1 : ROUTING_MAX_SQRT_PRICE - 1
            }),
            ""
        );
        uint256 amountOut = zeroForOne ? uint256(uint128(int128(delta))) : uint256(uint128(int128(delta >> 128)));
        if (amountOut < minOut_) revert InsufficientOutput();

        _settleCurrency(currencyIn_, amountIn_);
        IV4PoolManagerLiquidity(msg.sender).take(currencyOut_, recipient_, amountOut);
        return abi.encode(amountOut);
    }

    // Both currencies of every pool here are ERC-20s: sync, transfer in, settle.
    function _settleCurrency(address currency, uint256 amount) private {
        if (amount == 0) return;
        IV4PoolManagerLiquidity(msg.sender).sync(currency);
        _safeTransfer(currency, msg.sender, amount);
        IV4PoolManagerLiquidity(msg.sender).settle();
    }

    function _safeTransfer(address token_, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeTransferFrom(address token_, address from, address to, uint256 amount) internal {
        if (amount == 0) return;
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0x23b872dd, from, to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }
}
