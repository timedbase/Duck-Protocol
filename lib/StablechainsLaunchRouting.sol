// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — StablechainsLaunchRouting
//
// LaunchRoutingExec's instance for stablechains, chains whose native gas token is a stablecoin mirrored
// one-to-one by an ERC-20 (Arc: native USDC and the USDC ERC-20 at 0x3600...). It has the same external
// functions and selectors as LaunchRoutingExec and is linked in its place when the launch families are
// deployed on a stablechain; the families' own code is identical on every chain. Differences:
//   - native <-> the stablecoin ERC-20 is a unit conversion, not a swap (no WETH, no wrapping);
//   - the chain's Universal Router encoding (Arc's takes minHopPriceX36, like Robinhood's);
//   - a raw-native quote is refused at creation (requireQuoteSupported).
// Every other route (V4-style, through the chain's Universal Router) behaves as in LaunchRoutingExec.

import {IERC20ApprovalRouting, IPermit2Approve, IUniversalRouter, IERC20BalanceRouting, PoolKey, RouteShape, Route, ILaunchRoutingSelf} from "./LaunchRouting.sol";

library StablechainsLaunchRouting {
    error TransferFailed();
    error NativeTransferFailed();
    error RouterNotConfigured();
    error NativeQuoteUnsupported();

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

    uint256 private constant ARC_CHAIN_ID = 5042;

    // Per-stablechain settings. `usdc` is the chain's ERC-20 mirror of its native stablecoin (the same
    // balance, no wrapping); `nativeScale` converts native units to that ERC-20's units; `minHopRouter`
    // is whether the chain's Universal Router takes the extra minHopPriceX36 swap field. A chain with no
    // entry gets no mirror and the vanilla encoding.
    //   Arc: USDC is native gas at 18 decimals, mirrored by the ERC-20 at 0x3600... at 6 decimals, and its
    //   Universal Router is the same build as Robinhood's (identical bytecode apart from immutables).
    function _stablechain() private view returns (address usdc, uint256 nativeScale, bool minHopRouter) {
        if (block.chainid == ARC_CHAIN_ID) return (0x3600000000000000000000000000000000000000, 1e12, true);
        return (address(0), 0, block.chainid == ROBINHOOD_CHAIN_ID);
    }

    // Universal Router's own ActionConstants sentinels: address(1) = "recipient is msg.sender of
    // execute()", address(2) = "recipient is Universal Router's own balance".
    address private constant UR_ADDRESS_THIS = address(0x0000000000000000000000000000000000000002);

    // Forward: native ETH in, quote currency out (buy). Tries each enabled route, falling back on
    // revert -- via a self-call so try/catch can isolate the failure.
    function acquireQuoteToken(
        Route[] storage list, address universalRouter, address quoteToken_, uint256 nativeIn_, uint256 minOut_, address recipient_
    ) external returns (uint256 amountOut, bool ok) {
        (address usdc, uint256 scale,) = _stablechain();
        if (usdc != address(0) && quoteToken_ == usdc) return _acquireMirror(scale, nativeIn_, minOut_, recipient_);
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
        (address usdc, uint256 scale,) = _stablechain();
        if (usdc != address(0) && quoteToken_ == usdc) return _disposeMirror(usdc, scale, quoteIn_, minNativeOut_, recipient_);
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
        } else {
            _swapV4(universalRouter, route_.hook, route_.fee, route_.tickSpacing, quoteToken_, nativeIn_, amountIn_, minOut_, recipient_);
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

        bytes memory actions = abi.encodePacked(
            uint8(ACTION_SWAP_EXACT_IN_SINGLE), uint8(ACTION_SETTLE_ALL), uint8(ACTION_TAKE_ALL)
        );
        bytes[] memory params = new bytes[](3);
        (,, bool minHopRouter) = _stablechain();
        params[0] = minHopRouter
            ? abi.encode(key, zeroForOne, uint128(amountIn_), uint128(minOut_), uint256(0), bytes(""))
            : abi.encode(key, zeroForOne, uint128(amountIn_), uint128(minOut_), bytes(""));
        params[1] = abi.encode(currencyIn, amountIn_);
        params[2] = abi.encode(currencyOut, minOut_);

        bytes memory commands = new bytes(1);
        commands[0] = bytes1(uint8(CMD_V4_SWAP));
        bytes[] memory inputs = new bytes[](1);
        inputs[0] = abi.encode(actions, params);

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

    // On a stablechain a token is quoted in the stablecoin ERC-20, never raw native: native-quoted pools,
    // curves and raises go through WETH-shaped steps (wrap at migration, a WETH vault currency) these
    // chains have no WETH for, and a vault priced in 18-decimal native units but paying out a 6-decimal
    // ERC-20 would value collateral 1e12 too high. Paying and receiving native still works through the
    // mirror below; only choosing address(0) as the quote is refused.
    function requireQuoteSupported(address quote_) external view {
        (address usdc,,) = _stablechain();
        if (usdc != address(0) && quote_ == address(0)) revert NativeQuoteUnsupported();
    }

    // Native in, the stablecoin ERC-20 out. The native already belongs to the calling contract (it came in
    // as msg.value), so its ERC-20 balance already includes it: amountOut is only the unit conversion.
    // Dust below one ERC-20 unit has no ERC-20 representation and stays with the caller as native. For
    // another recipient, exactly the whole-unit part is forwarded, which lands in their ERC-20 balance.
    function _acquireMirror(uint256 scale, uint256 nativeIn_, uint256 minOut_, address recipient_) private returns (uint256 amountOut, bool ok) {
        amountOut = nativeIn_ / scale;
        if (amountOut == 0 || amountOut < minOut_) return (0, false);
        if (recipient_ != address(this)) _safeSendNative(recipient_, amountOut * scale);
        return (amountOut, true);
    }

    // The stablecoin ERC-20 in, native out: an ERC-20 transfer, which the recipient receives as native.
    // amountOut is in native units, like every other route's native output.
    function _disposeMirror(address usdc, uint256 scale, uint256 quoteIn_, uint256 minNativeOut_, address recipient_) private returns (uint256 amountOut, bool ok) {
        amountOut = quoteIn_ * scale;
        if (quoteIn_ == 0 || amountOut < minNativeOut_) return (0, false);
        if (recipient_ != address(this)) _safeTransfer(usdc, recipient_, quoteIn_);
        return (amountOut, true);
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
