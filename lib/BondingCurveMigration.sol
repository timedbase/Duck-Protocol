// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — BondingCurveMigration

import {TokenConfig} from "./DuckTypes.sol";
import {V4Minting} from "./V4Minting.sol";
import {Route, RouteShape, PoolKey} from "./LaunchRouting.sol";

interface IDuckTokenMig {
    function balanceOf(address account) external view returns (uint256);
    function postLaunchUnlock() external;
    function setRewardConfig(address hook_, address currency_, address poolManager_) external;
}

// Self-call back into whichever LaunchRouting-derived contract (DuckBondingCurve) delegatecalled
// into this library -- msg.sender/address(this) are already that contract's, so this resolves to
// its own _mintFullRangeDirect, same pattern as LaunchRouting._acquireQuoteToken's this.executeRoute.
interface IMintFullRangeDirectMig {
    function mintFullRangeDirect(address singleton_, PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external returns (uint256 amount0, uint256 amount1);
}

interface IERC20BalanceMig {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface IWETH9Mig {
    function deposit() external payable;
}

interface ITokenVaultLookupMig {
    function vault() external view returns (address);
}

interface IDuckVaultLinkMig {
    function linkPool(address currency, bytes32 poolId, bool tokenIsCurrency0, uint8 currencyDecimals, bool poolQuoteIsNative) external;
    function depositFees(uint256 amount) external;
}

interface IERC20MetaMig {
    function decimals() external view returns (uint8);
    function approve(address spender, uint256 amount) external returns (bool);
}

library BondingCurveMigration {
    error LiquidityReserveViolation();
    error InsufficientContractBalance();
    error HookNotSet();
    error TransferFailed();
    error NativeTransferFailed();

    // No position NFT or locker: liquidity goes straight into the PoolManager singleton, owned by
    // this contract and never withdrawn. With a 0% pool fee there's nothing to claim back anyway, so
    // permanent-by-construction is a simpler route to the same guarantee a burned NFT gave.

    function registerToken(
        TokenConfig storage tc,
        address[] storage allTokens,
        mapping(address => address[]) storage tokensByCreator,
        address token_,
        address creator_,
        address quoteToken_,
        uint256 supply,
        uint256 liqTokens,
        uint256 bcTokens,
        uint256 virtualQuote_,
        uint256 migrationTarget_,
        uint256 hookFeeBps_,
        uint16  creatorBps_,
        uint16  vaultBps_,
        uint16  burnBps_
    ) external {
        tc.token           = token_;
        tc.creator         = creator_;
        tc.quoteToken      = quoteToken_;
        tc.totalSupply     = supply;
        tc.liquidityTokens = liqTokens;
        tc.bcTokensTotal   = bcTokens;
        tc.bcTokensSold    = 0;
        tc.virtualQuote    = virtualQuote_;
        tc.k               = virtualQuote_ * bcTokens;
        tc.raisedQuote     = 0;
        tc.accruedFee      = 0;
        tc.hookFeeBps      = hookFeeBps_;
        tc.creatorBps      = creatorBps_;
        tc.vaultBps        = vaultBps_;
        tc.burnBps         = burnBps_;
        tc.migrationTarget = migrationTarget_;
        tc.creationBlock   = block.number;
        tc.migrated        = false;

        allTokens.push(token_);
        tokensByCreator[creator_].push(token_);
    }

    struct MigrationConfig {
        address hook;
        address weth;
        address positionManager;
        address singleton;
        uint24  fee;
        int24   tickSpacing;
    }

    function migrate(
        TokenConfig storage tc,
        address token_,
        uint256 totalRaisedETH,
        mapping(address => uint256) storage totalRaisedERC,
        MigrationConfig calldata cfg
    ) external returns (uint256 newTotalRaisedETH, bytes32 poolId) {
        tc.migrated          = true;
        tc.migrationPending  = false;

        uint256 migrationAmount = tc.raisedQuote;
        uint256 liqTokens       = tc.liquidityTokens;

        if (IDuckTokenMig(token_).balanceOf(address(this)) < liqTokens)
            revert LiquidityReserveViolation();

        newTotalRaisedETH = totalRaisedETH;
        if (tc.quoteToken == address(0)) {
            if (migrationAmount > address(this).balance) revert InsufficientContractBalance();
            newTotalRaisedETH = migrationAmount >= totalRaisedETH ? 0 : totalRaisedETH - migrationAmount;
        } else {
            if (migrationAmount > IERC20BalanceMig(tc.quoteToken).balanceOf(address(this))) revert InsufficientContractBalance();
            uint256 agg = totalRaisedERC[tc.quoteToken];
            totalRaisedERC[tc.quoteToken] = migrationAmount >= agg ? 0 : agg - migrationAmount;
        }

        poolId = _mintV4(tc, token_, migrationAmount, liqTokens, cfg);

        IDuckTokenMig(token_).postLaunchUnlock();
        tc.raisedQuote = 0;
    }

    function emergencyMigrate(
        TokenConfig storage tc,
        address token_,
        address to,
        uint256 totalRaisedETH,
        mapping(address => uint256) storage totalRaisedERC
    ) external returns (uint256 newTotalRaisedETH, uint256 migrationAmount, uint256 liqTokens) {
        tc.migrated         = true;
        tc.migrationPending = false;

        migrationAmount = tc.raisedQuote;
        liqTokens       = tc.liquidityTokens;
        address quote_  = tc.quoteToken;

        if (quote_ == address(0)) {
            if (migrationAmount > address(this).balance) revert InsufficientContractBalance();
            newTotalRaisedETH = migrationAmount >= totalRaisedETH ? 0 : totalRaisedETH - migrationAmount;
        } else {
            if (migrationAmount > IERC20BalanceMig(quote_).balanceOf(address(this))) revert InsufficientContractBalance();
            newTotalRaisedETH = totalRaisedETH;
            uint256 agg = totalRaisedERC[quote_];
            totalRaisedERC[quote_] = migrationAmount >= agg ? 0 : agg - migrationAmount;
        }
        tc.raisedQuote = 0;

        IDuckTokenMig(token_).postLaunchUnlock();

        if (liqTokens > 0) {
            if (!IERC20BalanceMig(token_).transfer(to, liqTokens)) revert TransferFailed();
        }
        _payQuote(quote_, to, migrationAmount);
    }

    function _payQuote(address quoteToken_, address to, uint256 amount) private {
        if (amount == 0) return;
        if (quoteToken_ == address(0)) {
            (bool ok,) = payable(to).call{value: amount}("");
            if (!ok) revert NativeTransferFailed();
        } else {
            if (!IERC20BalanceMig(quoteToken_).transfer(to, amount)) revert TransferFailed();
        }
    }

    function _mintV4(
        TokenConfig storage tc, address token_, uint256 migrationAmount, uint256 liqTokens,
        MigrationConfig calldata cfg
    ) private returns (bytes32 poolId) {
        if (cfg.hook == address(0)) revert HookNotSet();

        address quote_ = tc.quoteToken;
        bool wasNative = quote_ == address(0);
        if (wasNative) {
            quote_ = cfg.weth;
            IWETH9Mig(cfg.weth).deposit{value: migrationAmount}();
        }

        (address token0, address token1, uint256 amount0, uint256 amount1) = token_ < quote_
            ? (token_, quote_, liqTokens,       migrationAmount)
            : (quote_, token_, migrationAmount, liqTokens);

        // Must run BEFORE _doMint: that's what first moves real balance into the PoolManager, and
        // DuckToken only excludes poolManagerAddr once it's non-zero, so setting it first keeps that
        // transfer from counting as a new "holder". tc.quoteToken is still the ORIGINAL unwrapped
        // value (address(0) for native), matching depositHolderReward -- not the WETH-wrapped quote_.
        IDuckTokenMig(token_).setRewardConfig(cfg.hook, tc.quoteToken, cfg.singleton);

        poolId = _doMint(tc, cfg, token_, token0, token1, amount0, amount1);

        _finishMint(tc, cfg, token_, token0, poolId, quote_);
    }

    function _finishMint(
        TokenConfig storage tc, MigrationConfig calldata cfg, address token_,
        address token0, bytes32 poolId, address quote_
    ) private {
        tc.pair   = cfg.singleton;
        tc.poolId = poolId;

        address vault = ITokenVaultLookupMig(token_).vault();
        if (vault != address(0)) {

            try IDuckVaultLinkMig(vault).linkPool(quote_, poolId, token_ == token0, IERC20MetaMig(quote_).decimals(), false) {} catch {}
        }
    }

    function _doMint(
        TokenConfig storage tc, MigrationConfig calldata cfg, address token_,
        address token0, address token1, uint256 amount0, uint256 amount1
    ) private returns (bytes32 poolId) {
        // Built field-by-field into a named local, not one big struct-literal call argument -- with
        // this many fields, encoding it inline can hit stack-too-deep even under via-IR (same fix as
        // DuckHookV4.registerPool for the identical reason).
        V4Minting.MintFullRangeSetupParams memory p;
        p.positionManager = cfg.positionManager;
        p.hook            = cfg.hook;
        p.token           = token_;
        p.token0          = token0;
        p.token1          = token1;
        p.amount0         = amount0;
        p.amount1         = amount1;
        p.creator         = tc.creator;
        p.hookFeeBps      = tc.hookFeeBps;
        p.creatorBps      = tc.creatorBps;
        p.vaultBps        = tc.vaultBps;
        p.burnBps         = tc.burnBps;
        p.fee             = cfg.fee;
        p.tickSpacing     = cfg.tickSpacing;

        PoolKey memory key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        (poolId, key, tickLower, tickUpper, liquidity) = V4Minting.setupFullRangePool(p);

        // No position NFT: liquidity is added straight to the PoolManager singleton itself, owned by
        // this contract, permanently (see LaunchRouting._mintFullRangeDirect) -- the same "can never
        // be rugged" guarantee the old mint-to-DEAD NFT gave, without ever creating the NFT.
        IMintFullRangeDirectMig(address(this)).mintFullRangeDirect(cfg.singleton, key, tickLower, tickUpper, liquidity);
    }
}
