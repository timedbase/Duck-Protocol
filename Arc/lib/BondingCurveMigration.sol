// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — BondingCurveMigration (Arc)
//
// Registers curve tokens and moves a finished curve into its DuckGenesisHook pool. On Arc a curve's quote
// asset is always an ERC-20, so the raised amount goes into the pool as it is -- nothing to wrap -- and the
// tokens (DuckCurveToken) never carry a transfer lock to lift.

import {TokenConfig} from "./DuckTypes.sol";
import {V4Minting} from "./V4Minting.sol";
import {PoolKey} from "./LaunchRouting.sol";

interface IDuckTokenMig {
    function balanceOf(address account) external view returns (uint256);
}

// Self-call back into the LaunchRouting-derived contract (DuckBondingCurve) that delegatecalled into this
// library -- msg.sender/address(this) are already that contract's, so this resolves to its own
// _mintFullRangeDirect.
interface IMintFullRangeDirectMig {
    function mintFullRangeDirect(address singleton_, PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity)
        external returns (uint256 amount0, uint256 amount1);
}

interface IERC20BalanceMig {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ITokenVaultLookupMig {
    function vault() external view returns (address);
}

interface IDuckVaultLinkMig {
    function linkPool(address currency, bytes32 poolId, bool tokenIsCurrency0, uint8 currencyDecimals) external;
}

interface IERC20MetaMig {
    function decimals() external view returns (uint8);
}

library BondingCurveMigration {
    error LiquidityReserveViolation();
    error InsufficientContractBalance();
    error HookNotSet();
    error TransferFailed();

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
        address positionManager;
        address singleton;
        uint24  fee;
        int24   tickSpacing;
    }

    // totalRaised: per quote token, the reserves all curves hold (kept back from rescueToken).
    function migrate(
        TokenConfig storage tc,
        address token_,
        mapping(address => uint256) storage totalRaised,
        MigrationConfig calldata cfg
    ) external returns (bytes32 poolId) {
        tc.migrated          = true;
        tc.migrationPending  = false;

        uint256 migrationAmount = tc.raisedQuote;
        uint256 liqTokens       = tc.liquidityTokens;

        if (IDuckTokenMig(token_).balanceOf(address(this)) < liqTokens) revert LiquidityReserveViolation();
        _release(tc.quoteToken, migrationAmount, totalRaised);

        poolId = _mintV4(tc, token_, migrationAmount, liqTokens, cfg);
        tc.raisedQuote = 0;
    }

    function emergencyMigrate(
        TokenConfig storage tc,
        address token_,
        address to,
        mapping(address => uint256) storage totalRaised
    ) external returns (uint256 migrationAmount, uint256 liqTokens) {
        tc.migrated         = true;
        tc.migrationPending = false;

        migrationAmount = tc.raisedQuote;
        liqTokens       = tc.liquidityTokens;
        address quote_  = tc.quoteToken;

        _release(quote_, migrationAmount, totalRaised);
        tc.raisedQuote = 0;

        if (liqTokens > 0) {
            if (!IERC20BalanceMig(token_).transfer(to, liqTokens)) revert TransferFailed();
        }
        if (migrationAmount > 0) {
            if (!IERC20BalanceMig(quote_).transfer(to, migrationAmount)) revert TransferFailed();
        }
    }

    // Checks the curve really holds a finished curve's reserve, then takes it out of the per-quote total.
    function _release(address quote_, uint256 amount, mapping(address => uint256) storage totalRaised) private {
        if (amount > IERC20BalanceMig(quote_).balanceOf(address(this))) revert InsufficientContractBalance();
        uint256 agg = totalRaised[quote_];
        totalRaised[quote_] = amount >= agg ? 0 : agg - amount;
    }

    function _mintV4(
        TokenConfig storage tc, address token_, uint256 migrationAmount, uint256 liqTokens,
        MigrationConfig calldata cfg
    ) private returns (bytes32 poolId) {
        if (cfg.hook == address(0)) revert HookNotSet();

        address quote_ = tc.quoteToken;
        (address token0, address token1, uint256 amount0, uint256 amount1) = token_ < quote_
            ? (token_, quote_, liqTokens,       migrationAmount)
            : (quote_, token_, migrationAmount, liqTokens);

        // Reward config is no longer set here -- DuckBondingCurve.createToken sets it at mint time now,
        // using the same p.quoteToken this function also uses (Arc has no native-quote wrap, so the two
        // can never disagree). No legacy token template exists on Arc to preserve a fallback path for.
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
            try IDuckVaultLinkMig(vault).linkPool(quote_, poolId, token_ == token0, IERC20MetaMig(quote_).decimals()) {} catch {}
        }
    }

    function _doMint(
        TokenConfig storage tc, MigrationConfig calldata cfg, address token_,
        address token0, address token1, uint256 amount0, uint256 amount1
    ) private returns (bytes32 poolId) {
        // Built field-by-field into a named local, not one big struct-literal call argument -- with
        // this many fields, encoding it inline can hit stack-too-deep even under via-IR.
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
        // this contract, permanently (see LaunchRouting._mintFullRangeDirect).
        IMintFullRangeDirectMig(address(this)).mintFullRangeDirect(cfg.singleton, key, tickLower, tickUpper, liquidity);
    }
}
