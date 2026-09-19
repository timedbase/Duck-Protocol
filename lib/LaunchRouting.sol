// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — LaunchRouting
//
// Swap execution routes through Uniswap's Universal Router (verified live on Robinhood Chain and
// Ink; both run a newer v4-periphery than Uniswap's npm package, and Robinhood's is a bespoke fork
// with an extra per-hop price-floor field -- see LaunchRoutingExec for how each is handled). Direct
// v4 PoolManager access is kept only for this protocol's own liquidity provisioning and
// buy-and-burn, which touch pools it already controls. ERC20 quote tokens pay via Permit2;
// _ensurePermit2Approved grants and refreshes both approvals lazily.

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

interface IWETHRouting {
    function deposit() external payable;
    function withdraw(uint256 amount) external;
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

// Universal Router's V4_SWAP decodes SWAP_EXACT_IN_SINGLE's params as one ABI-encoded STRUCT, and this one carries a
// `bytes`, so it is dynamic: abi.encode(struct) leads with an offset word that a flat abi.encode(a, b, c, ...) of
// the same fields does not have. Encode these structs, never the loose fields. Robinhood's fork has the extra
// minHopPriceX36 field before hookData; Ink's doesn't (see LaunchRoutingExec.ROBINHOOD_CHAIN_ID).
struct ExactInSingle {
    PoolKey poolKey;
    bool    zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    bytes   hookData;
}
struct ExactInSingleRobinhood {
    PoolKey poolKey;
    bool    zeroForOne;
    uint128 amountIn;
    uint128 amountOutMinimum;
    uint256 minHopPriceX36;
    bytes   hookData;
}

struct ModifyLiquidityParams {
    int24   tickLower;
    int24   tickUpper;
    int256  liquidityDelta;
    bytes32 salt;
}

// Liquidity provisioning plus swap() -- the latter is kept only for DuckBondingCurve's internal
// buy-and-burn, against a pool this contract already controls (see file header).
interface IV4PoolManagerLiquidity {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory params, bytes calldata hookData)
        external returns (int256 callerDelta, int256 feeDelta);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

// V4_STYLE swaps against a pool whose other currency is NATIVE ETH (address(0)). V4_WETH_STYLE is the same swap
// against a pool paired with WRAPPED native (WETH) instead -- which is what every DuckGenesisHook pool is, since the
// hook never uses address(0) -- wrapping/unwrapping around it so callers still deal only in native ETH.
// Appended last so the existing values keep their numbers.
enum RouteShape { V3_STYLE, V4_STYLE, V4_WETH_STYLE }

struct Route {
    RouteShape shape;
    bool       enabled;
    address[]  path;        // V3_STYLE only: WETH-anchored token path (forward order, native->quote), 2+ addresses
                            // V4_WETH_STYLE only: exactly one address, the wrapped native token the pool is paired with
    uint24[]   fees;        // V3_STYLE only: per-hop fee tiers, path.length - 1 entries
    address    hook;        // V4_STYLE and V4_WETH_STYLE only
    uint24     fee;         // V4_STYLE and V4_WETH_STYLE only
    int24      tickSpacing; // V4_STYLE and V4_WETH_STYLE only
}

interface ILaunchRoutingSelf {
    function executeSwapRoute(
        Route calldata route_, address universalRouter, address quoteToken_, bool nativeIn_,
        uint256 amountIn_, uint256 minOut_, address recipient_
    ) external payable returns (uint256 amountOut);
}

// External library (delegatecall) so DuckBondingCurve/DuckLauncher/DuckCrowdfund don't each inline
// a copy -- same pattern as BondingCurveMath/BondingCurveMigration.
library LaunchRoutingExec {
    error TransferFailed();
    error NativeTransferFailed();
    error RouterNotConfigured();
    error InvalidRoute();

    event RouteSucceeded(address indexed quoteToken, uint256 indexed routeIndex, uint256 amountOut);

    address internal constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;

    // Verified against the actual deployed source on both chains, not the generic npm package --
    // both run a newer v4-periphery with action ids shifted by two vs. the older layout.
    uint256 private constant CMD_V3_SWAP_EXACT_IN = 0x00;
    uint256 private constant CMD_WRAP_ETH         = 0x0b;
    uint256 private constant CMD_UNWRAP_WETH      = 0x0c;
    uint256 private constant CMD_V4_SWAP          = 0x10;

    uint256 private constant ACTION_SWAP_EXACT_IN_SINGLE = 0x06;
    uint256 private constant ACTION_SETTLE_ALL           = 0x0c;
    uint256 private constant ACTION_TAKE_ALL             = 0x0f;

    // Robinhood's Universal Router fork adds a 6th field (uint256 minHopPriceX36, an optional
    // per-hop price floor) to ExactInputSingleParams where vanilla Uniswap has sqrtPriceLimitX96;
    // Ink's canonical deployment drops that field. Not interchangeable, so built chain-conditionally.
    // (V3's own minHopPriceX36 *array* param is separately appended, not embedded -- an empty array
    // there is silently ignored by a vanilla decoder, no branching needed; see _swapV3.)
    uint256 private constant ROBINHOOD_CHAIN_ID = 4663;

    // Universal Router's own ActionConstants sentinels: address(1) = "recipient is msg.sender of
    // execute()", address(2) = "recipient is Universal Router's own balance".
    address private constant UR_ADDRESS_THIS = address(0x0000000000000000000000000000000000000002);

    // Forward: native ETH in, quote currency out (buy). Tries each enabled route, falling back on
    // revert -- via a self-call so try/catch can isolate the failure.
    function acquireQuoteToken(
        Route[] storage list, address universalRouter, address quoteToken_, uint256 nativeIn_, uint256 minOut_, address recipient_
    ) external returns (uint256 amountOut, bool ok) {
        for (uint256 i; i < list.length; ++i) {
            if (!list[i].enabled) continue;
            try ILaunchRoutingSelf(address(this)).executeSwapRoute{value: nativeIn_}(
                list[i], universalRouter, quoteToken_, true, nativeIn_, minOut_, recipient_
            ) returns (uint256 out) {
                emit RouteSucceeded(quoteToken_, i, out);
                return (out, true);
            } catch {}
        }
        return (0, false);
    }

    // Reverse of acquireQuoteToken: sells a held ERC20 quote balance for native ETH (sellForNative).
    function disposeQuoteToken(
        Route[] storage list, address universalRouter, address quoteToken_, uint256 quoteIn_, uint256 minNativeOut_, address recipient_
    ) external returns (uint256 amountOut, bool ok) {
        for (uint256 i; i < list.length; ++i) {
            if (!list[i].enabled) continue;
            try ILaunchRoutingSelf(address(this)).executeSwapRoute(
                list[i], universalRouter, quoteToken_, false, quoteIn_, minNativeOut_, recipient_
            ) returns (uint256 out) {
                emit RouteSucceeded(quoteToken_, i, out);
                return (out, true);
            } catch {}
        }
        return (0, false);
    }

    // Executes exactly one configured route, in the given direction, through Universal Router.
    // nativeIn_ true = native ETH -> quoteToken_ (buy); false = quoteToken_ -> native ETH (sell).
    function executeSwapRoute(
        Route calldata route_, address universalRouter, address quoteToken_, bool nativeIn_,
        uint256 amountIn_, uint256 minOut_, address recipient_
    ) external returns (uint256 amountOut) {
        // A void-return call to an address with no code would otherwise silently no-op instead of
        // reverting -- fail loudly rather than return a false amountOut=0.
        if (universalRouter.code.length == 0) revert RouterNotConfigured();

        address outCurrency = nativeIn_ ? quoteToken_ : address(0);
        uint256 balBefore = _balanceOf(outCurrency, recipient_);

        if (route_.shape == RouteShape.V3_STYLE) {
            _swapV3(universalRouter, route_.path, route_.fees, nativeIn_, amountIn_, minOut_, recipient_, quoteToken_);
        } else if (route_.shape == RouteShape.V4_STYLE) {
            _swapV4(universalRouter, route_.hook, route_.fee, route_.tickSpacing, quoteToken_, nativeIn_, amountIn_, minOut_, recipient_);
        } else {
            if (route_.path.length != 1) revert InvalidRoute();
            _swapV4Weth(universalRouter, route_.path[0], route_.hook, route_.fee, route_.tickSpacing, quoteToken_, nativeIn_, amountIn_, minOut_, recipient_);
        }

        amountOut = _balanceOf(outCurrency, recipient_) - balBefore;
    }

    function _swapV3(
        address universalRouter, address[] calldata path, uint24[] calldata fees,
        bool nativeIn_, uint256 amountIn_, uint256 minOut_, address recipient_, address quoteToken_
    ) private {
        bytes memory commands = new bytes(2);
        bytes[] memory inputs = new bytes[](2);
        // Robinhood's fork extends V3_SWAP_EXACT_IN with a trailing per-hop min-price array; empty
        // disables it there and is silently unread on a vanilla deployment, so always safe to append.
        uint256[] memory noHopPriceFloor = new uint256[](0);

        if (nativeIn_) {
            // WRAP_ETH into the router's own balance, then V3_SWAP_EXACT_IN pays from that balance
            // (payerIsUser=false) straight to recipient_ -- no extra forwarding needed.
            commands[0] = bytes1(uint8(CMD_WRAP_ETH));
            commands[1] = bytes1(uint8(CMD_V3_SWAP_EXACT_IN));
            inputs[0] = abi.encode(UR_ADDRESS_THIS, amountIn_);
            inputs[1] = abi.encode(recipient_, amountIn_, minOut_, _encodeV3Path(path, fees), false, noHopPriceFloor);
            IUniversalRouter(universalRouter).execute{value: amountIn_}(commands, inputs, block.timestamp);
        } else {
            // Pulls quoteToken_ via Permit2 (payerIsUser=true), lands intermediate WETH in the
            // router's own balance, then UNWRAP_WETH pays recipient_. Path runs quoteToken_->WETH,
            // reversed from the WETH->quoteToken_ order routes are configured in.
            _ensurePermit2Approved(quoteToken_, universalRouter);
            commands[0] = bytes1(uint8(CMD_V3_SWAP_EXACT_IN));
            commands[1] = bytes1(uint8(CMD_UNWRAP_WETH));
            inputs[0] = abi.encode(UR_ADDRESS_THIS, amountIn_, uint256(0), _encodeV3PathReversed(path, fees), true, noHopPriceFloor);
            inputs[1] = abi.encode(recipient_, minOut_);
            IUniversalRouter(universalRouter).execute(commands, inputs, block.timestamp);
        }
    }

    function _swapV4(
        address universalRouter, address hook_, uint24 fee_, int24 tickSpacing_, address quoteToken_,
        bool nativeIn_, uint256 amountIn_, uint256 minOut_, address recipient_
    ) private {
        address currencyIn  = nativeIn_ ? address(0) : quoteToken_;
        address currencyOut = nativeIn_ ? quoteToken_ : address(0);
        bool zeroForOne = currencyIn < currencyOut;
        PoolKey memory key = PoolKey({
            currency0:   zeroForOne ? currencyIn  : currencyOut,
            currency1:   zeroForOne ? currencyOut : currencyIn,
            fee:         fee_,
            tickSpacing: tickSpacing_,
            hooks:       hook_
        });

        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _v4SwapInput(key, zeroForOne, currencyIn, currencyOut, amountIn_, minOut_);
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(uint8(CMD_V4_SWAP));

        if (!nativeIn_) _ensurePermit2Approved(quoteToken_, universalRouter);

        // TAKE_ALL always pays whoever called execute() (us), never an arbitrary recipient -- so
        // measure what arrives and forward it on when recipient_ is someone else.
        uint256 balBeforeSelf = _balanceOf(currencyOut, address(this));
        if (nativeIn_) {
            IUniversalRouter(universalRouter).execute{value: amountIn_}(commands, inputs, block.timestamp);
        } else {
            IUniversalRouter(universalRouter).execute(commands, inputs, block.timestamp);
        }
        if (recipient_ != address(this)) {
            uint256 received = _balanceOf(currencyOut, address(this)) - balBeforeSelf;
            if (received > 0) {
                if (currencyOut == address(0)) {
                    _safeSendNative(recipient_, received);
                } else {
                    _safeTransfer(currencyOut, recipient_, received);
                }
            }
        }
    }

    // The same single-pool v4 swap as _swapV4, against a pool paired with WETH rather than native ETH. The caller still
    // sees native ETH on the native side: a buy wraps the ETH first, a sell unwraps what the swap pays out. Every
    // token amount the router touches is a real ERC20 (WETH included), so both sides settle through Permit2.
    function _swapV4Weth(
        address universalRouter, address weth_, address hook_, uint24 fee_, int24 tickSpacing_, address quoteToken_,
        bool nativeIn_, uint256 amountIn_, uint256 minOut_, address recipient_
    ) private {
        address currencyIn  = nativeIn_ ? weth_ : quoteToken_;
        address currencyOut = nativeIn_ ? quoteToken_ : weth_;

        if (nativeIn_) IWETHRouting(weth_).deposit{value: amountIn_}();
        _swapV4Exact(universalRouter, hook_, fee_, tickSpacing_, currencyIn, currencyOut, amountIn_, minOut_);

        // TAKE_ALL paid this contract (the caller of execute()); pass the proceeds on in the form the caller wants.
        if (nativeIn_) {
            if (recipient_ != address(this)) {
                uint256 received = _balanceOf(currencyOut, address(this));
                if (received > 0) _safeTransfer(currencyOut, recipient_, received);
            }
        } else {
            uint256 wethBalance = _balanceOf(weth_, address(this));
            if (wethBalance > 0) IWETHRouting(weth_).withdraw(wethBalance);
            if (recipient_ != address(this)) {
                uint256 nativeBalance = address(this).balance;
                if (nativeBalance > 0) _safeSendNative(recipient_, nativeBalance);
            }
        }
    }

    // One exact-input single-pool swap through Universal Router between two ERC20 currencies, paid out to this
    // contract (TAKE_ALL always pays the caller of execute()). Same encoding as _swapV4, including Robinhood's extra
    // field, for pools where neither side is native.
    function _swapV4Exact(
        address universalRouter, address hook_, uint24 fee_, int24 tickSpacing_,
        address currencyIn, address currencyOut, uint256 amountIn_, uint256 minOut_
    ) private {
        bool zeroForOne = currencyIn < currencyOut;
        PoolKey memory key = PoolKey({
            currency0:   zeroForOne ? currencyIn  : currencyOut,
            currency1:   zeroForOne ? currencyOut : currencyIn,
            fee:         fee_,
            tickSpacing: tickSpacing_,
            hooks:       hook_
        });
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = _v4SwapInput(key, zeroForOne, currencyIn, currencyOut, amountIn_, minOut_);
        bytes memory commands = new bytes(1);
        commands[0] = bytes1(uint8(CMD_V4_SWAP));

        _ensurePermit2Approved(currencyIn, universalRouter);
        IUniversalRouter(universalRouter).execute(commands, inputs, block.timestamp);
    }

    // The single V4_SWAP input: SWAP_EXACT_IN_SINGLE, then SETTLE_ALL (pay currencyIn) and TAKE_ALL (receive
    // currencyOut, always to the caller of execute()).
    function _v4SwapInput(
        PoolKey memory key, bool zeroForOne, address currencyIn, address currencyOut, uint256 amountIn_, uint256 minOut_
    ) private view returns (bytes memory) {
        bytes memory actions = abi.encodePacked(
            uint8(ACTION_SWAP_EXACT_IN_SINGLE), uint8(ACTION_SETTLE_ALL), uint8(ACTION_TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        params[0] = block.chainid == ROBINHOOD_CHAIN_ID
            ? abi.encode(ExactInSingleRobinhood(key, zeroForOne, uint128(amountIn_), uint128(minOut_), 0, ""))
            : abi.encode(ExactInSingle(key, zeroForOne, uint128(amountIn_), uint128(minOut_), ""));
        params[1] = abi.encode(currencyIn, amountIn_);
        params[2] = abi.encode(currencyOut, minOut_);
        return abi.encode(actions, params);
    }

    function _ensurePermit2Approved(address token_, address universalRouter) private {
        if (IERC20ApprovalRouting(token_).allowance(address(this), PERMIT2) < type(uint256).max / 2) {
            // Low-level, tolerant of non-standard ERC20s that return no bool (a plain interface call
            // would revert on those) -- same pattern as _safeTransfer.
            (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0x095ea7b3, PERMIT2, type(uint256).max));
            if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
        }
        (uint160 amount, uint48 expiration,) = IPermit2Approve(PERMIT2).allowance(address(this), token_, universalRouter);
        if (amount < type(uint160).max / 2 || expiration <= block.timestamp) {
            IPermit2Approve(PERMIT2).approve(token_, universalRouter, type(uint160).max, type(uint48).max);
        }
    }

    function _balanceOf(address currency, address account) private view returns (uint256) {
        if (currency == address(0)) return account.balance;
        return IERC20BalanceRouting(currency).balanceOf(account);
    }

    function _encodeV3Path(address[] calldata path, uint24[] calldata fees) private pure returns (bytes memory encoded) {
        encoded = abi.encodePacked(path[0]);
        for (uint256 i; i < fees.length; ++i) {
            encoded = abi.encodePacked(encoded, fees[i], path[i + 1]);
        }
    }

    // Same path walked back-to-front: fees stay paired with the same token boundary, only the
    // traversal order (and so the swap direction) flips.
    function _encodeV3PathReversed(address[] calldata path, uint24[] calldata fees) private pure returns (bytes memory encoded) {
        uint256 n = path.length;
        encoded = abi.encodePacked(path[n - 1]);
        for (uint256 i = n - 1; i > 0; --i) {
            encoded = abi.encodePacked(encoded, fees[i - 1], path[i - 1]);
        }
    }

    function _safeTransfer(address token_, address to, uint256 amount) private {
        (bool ok, bytes memory data) = token_.call(abi.encodeWithSelector(0xa9059cbb, to, amount));
        if (!ok || (data.length > 0 && !abi.decode(data, (bool)))) revert TransferFailed();
    }

    function _safeSendNative(address to, uint256 amount) private {
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }
}

abstract contract LaunchRouting {

    error Unauthorized();
    error TransferFailed();
    error InsufficientOutput();

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

    function _setUniversalRouter(address router_) internal {
        universalRouter = router_;
        emit UniversalRouterUpdated(router_);
    }

    function _acquireQuoteToken(address quoteToken_, uint256 nativeIn_, uint256 minOut_, address recipient_)
        internal returns (uint256 amountOut, bool ok)
    {
        (amountOut, ok) = LaunchRoutingExec.acquireQuoteToken(routes[quoteToken_], universalRouter, quoteToken_, nativeIn_, minOut_, recipient_);
    }

    // Reverse of _acquireQuoteToken: sells a held ERC20 quote balance for native ETH (sellForNative).
    function _disposeQuoteToken(address quoteToken_, uint256 quoteIn_, uint256 minNativeOut_, address recipient_)
        internal returns (uint256 amountOut, bool ok)
    {
        (amountOut, ok) = LaunchRoutingExec.disposeQuoteToken(routes[quoteToken_], universalRouter, quoteToken_, quoteIn_, minNativeOut_, recipient_);
    }

    // Self-call entry point: the library calls back in here so try/catch can catch a bad route's
    // revert and move on to the next one.
    function executeSwapRoute(
        Route calldata route_, address universalRouter_, address quoteToken_, bool nativeIn_,
        uint256 amountIn_, uint256 minOut_, address recipient_
    ) external payable returns (uint256 amountOut) {
        if (msg.sender != address(this)) revert Unauthorized();
        amountOut = LaunchRoutingExec.executeSwapRoute(route_, universalRouter_, quoteToken_, nativeIn_, amountIn_, minOut_, recipient_);
    }

    // Liquidity straight into the PoolManager singleton -- no PositionManager, Permit2, or position
    // NFT. The position is keyed by (owner, tickLower, tickUpper, salt) with owner = the calling
    // contract, so it stays locked as long as that contract never calls modifyLiquidity to remove it
    // -- the same "can never be rugged" guarantee the old mint-to-DEAD NFT gave, without the NFT.
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

    // Reached from both _mintFullRangeDirect (liquidity add) and _executeV4Swap (internal
    // buy-and-burn) -- the op tag prefixed to the unlock() payload tells them apart.
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

        // BalanceDelta packs signed amount0 high, amount1 low. Adding liquidity means we owe the
        // pool, so both come back <= 0; negate to get what to pay in.
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

        if (currencyIn_ == address(0)) {
            IV4PoolManagerLiquidity(msg.sender).settle{value: amountIn_}();
        } else {
            IV4PoolManagerLiquidity(msg.sender).sync(currencyIn_);
            _safeTransfer(currencyIn_, msg.sender, amountIn_);
            IV4PoolManagerLiquidity(msg.sender).settle();
        }
        IV4PoolManagerLiquidity(msg.sender).take(currencyOut_, recipient_, amountOut);
        return abi.encode(amountOut);
    }

    function _settleCurrency(address currency, uint256 amount) private {
        if (amount == 0) return;
        if (currency == address(0)) {
            IV4PoolManagerLiquidity(msg.sender).settle{value: amount}();
        } else {
            IV4PoolManagerLiquidity(msg.sender).sync(currency);
            _safeTransfer(currency, msg.sender, amount);
            IV4PoolManagerLiquidity(msg.sender).settle();
        }
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
