// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — BondingCurveMath (Arc)
//
// Curve pricing, fee accounting and payouts for DuckBondingCurve. On Arc every curve is quoted in an ERC-20
// (USDC by default), so reserves and fees are tracked per quote token and always paid out as that ERC-20.

import {TokenConfig, FeeSplit} from "./DuckTypes.sol";

interface IERC20TransferBuy {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

interface ILaunchpadSelfBuy {
    function _tryMigrateExternal(address token_) external;
}

library BondingCurveMath {
    error ZeroAmount();
    error SlippageTooFewTokens();
    error LiquidityReserveViolation();
    error InsufficientPoolQuote();
    error SlippageTooLittleQuote();
    error TransferFailed();
    error NotCreator();
    error TooManyFeeSplits();
    error InvalidFeeSplitBps();
    error ZeroAddress();
    error ActivePool();
    error CloneFailed();
    error VanityAddressRequired();

    uint256 private constant BPS_DENOM      = 10_000;
    uint256 private constant CURVE_FEE_BPS  =    100;

    // totalRaised / totalAccruedFee: per quote token, what all curves hold as reserves and as unclaimed fees.
    function executeBuy(
        TokenConfig storage tc,
        address token_,
        address buyer,
        uint256 quoteIn,
        uint256 minOut,
        mapping(address => uint256) storage totalRaised,
        mapping(address => uint256) storage totalAccruedFee
    ) external returns (uint256 tokensOut, uint256 netQuoteIn, bool migrationAttemptFailed) {
        uint256 fee;
        uint256 refund;
        (tokensOut, fee, netQuoteIn, refund) = _calcBuy(tc, quoteIn, minOut);

        address quoteToken_ = tc.quoteToken;
        totalRaised[quoteToken_] += netQuoteIn - fee;
        if (fee > 0) {
            tc.accruedFee += fee;
            totalAccruedFee[quoteToken_] += fee;
        }

        migrationAttemptFailed = _finalizeBuy(tc, token_, buyer, tokensOut, refund, quoteToken_);
    }

    function executeSell(
        TokenConfig storage tc,
        address seller,
        uint256 amountIn,
        uint256 minQuoteOut,
        mapping(address => uint256) storage totalRaised,
        mapping(address => uint256) storage totalAccruedFee
    ) external returns (uint256 netQuote, uint256 raisedAfter) {
        uint256 poolQuote    = tc.virtualQuote + tc.raisedQuote;
        uint256 newPoolToks  = tc.bcTokensTotal - tc.bcTokensSold + amountIn;
        uint256 newPoolQuote = (tc.k + newPoolToks - 1) / newPoolToks;
        uint256 grossQuote   = poolQuote > newPoolQuote ? poolQuote - newPoolQuote : 0;
        if (grossQuote > tc.raisedQuote) revert InsufficientPoolQuote();
        uint256 fee = (grossQuote * CURVE_FEE_BPS + BPS_DENOM - 1) / BPS_DENOM;
        netQuote = grossQuote - fee;
        if (netQuote < minQuoteOut) revert SlippageTooLittleQuote();
        tc.raisedQuote  -= grossQuote;
        tc.bcTokensSold -= amountIn;

        address quoteToken_ = tc.quoteToken;
        uint256 agg = totalRaised[quoteToken_];
        totalRaised[quoteToken_] = grossQuote >= agg ? 0 : agg - grossQuote;

        raisedAfter = tc.raisedQuote;

        _payQuote(quoteToken_, seller, netQuote);

        if (fee > 0) {
            tc.accruedFee += fee;
            totalAccruedFee[quoteToken_] += fee;
        }
    }

    function _calcBuy(
        TokenConfig storage tc, uint256 quoteIn, uint256 minOut
    ) private returns (uint256 tokensOut, uint256 fee, uint256 netQuoteIn, uint256 refund) {
        uint256 poolQuote  = tc.virtualQuote + tc.raisedQuote;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;

        uint256 grossNeeded = ((tc.migrationTarget - tc.raisedQuote) * BPS_DENOM
                + (BPS_DENOM - CURVE_FEE_BPS) - 1)
              / (BPS_DENOM - CURVE_FEE_BPS);
        uint256 netQuote;

        if (quoteIn >= grossNeeded) {

            refund     = quoteIn - grossNeeded;
            fee        = (grossNeeded * CURVE_FEE_BPS) / BPS_DENOM;
            netQuote   = grossNeeded - fee;
            tokensOut  = poolTokens;
            netQuoteIn = grossNeeded;
        } else {
            fee        = (quoteIn * CURVE_FEE_BPS + BPS_DENOM - 1) / BPS_DENOM;
            netQuote   = quoteIn - fee;
            tokensOut  = poolTokens - ((tc.k + poolQuote + netQuote - 1) / (poolQuote + netQuote));
            netQuoteIn = quoteIn;
        }

        if (tokensOut == 0)         revert ZeroAmount();
        if (tokensOut < minOut)     revert SlippageTooFewTokens();
        if (tokensOut > poolTokens) revert LiquidityReserveViolation();

        tc.raisedQuote  += netQuote;
        tc.bcTokensSold += tokensOut;

    }

    function _finalizeBuy(
        TokenConfig storage tc, address token_, address buyer,
        uint256 tokensOut, uint256 refund, address quoteToken_
    ) private returns (bool migrationAttemptFailed) {
        if (tokensOut > 0) IERC20TransferBuy(token_).transfer(buyer, tokensOut);

        if (refund > 0) _payQuote(quoteToken_, buyer, refund);

        if (!tc.migrated && tc.raisedQuote >= tc.migrationTarget) {

            try ILaunchpadSelfBuy(address(this))._tryMigrateExternal(token_) {

            } catch {
                tc.migrationPending = true;
                migrationAttemptFailed = true;
            }
        }
    }

    function cloneCreate2(address implementation, address deployer, bytes32 userSalt)
        external returns (address instance)
    {
        bytes32 salt = keccak256(abi.encode(deployer, userSalt));
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,         0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0))              revert CloneFailed();
        if (uint16(uint160(instance)) != 0x8888) revert VanityAddressRequired();
    }

    function predictTokenAddress(address creator_, bytes32 userSalt_, address impl_, address deployer)
        external pure returns (address predicted)
    {
        bytes32 salt = keccak256(abi.encode(creator_, userSalt_));
        bytes32 initcodeHash;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,         0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, impl_))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            initcodeHash := keccak256(ptr, 0x37)
        }
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff),
            deployer,
            salt,
            initcodeHash
        )))));
    }

    function settleCurveFee(
        TokenConfig storage tc, address creator_, uint256 amount,
        mapping(address => uint256) storage totalAccruedFee,
        FeeSplit[] memory feeSplits, address platformToken_, address platformWallet_
    ) external returns (uint256 creatorCut, uint256 platformCut, bool needsBuyAndBurn) {
        address quoteToken_ = tc.quoteToken;
        uint256 agg = totalAccruedFee[quoteToken_];
        totalAccruedFee[quoteToken_] = amount >= agg ? 0 : agg - amount;

        // Curve fee is creator/platform only. The vault/creator/burn split governs the HOOK's
        // post-migration trading fee (see DuckGenesisHook.claimFees) and must not also carve into this
        // pre-migration fee -- a vault is only ever funded from the hook side.
        creatorCut  = amount / 2;
        platformCut = amount - creatorCut;

        _distributeFeeSplits(quoteToken_, creator_, creatorCut, feeSplits);

        if (platformToken_ != address(0) && quoteToken_ == platformToken_) {
            needsBuyAndBurn = true;
        } else {
            _payQuote(quoteToken_, platformWallet_, platformCut);
        }
    }

    function previewBuy(
        uint256 migrationTarget, uint256 raisedQuote, uint256 virtualQuote,
        uint256 bcTokensTotal, uint256 bcTokensSold, uint256 k, uint256 quoteIn
    ) external pure returns (uint256 tokensOut, uint256 feeQuote) {
        uint256 poolQuote   = virtualQuote + raisedQuote;
        uint256 poolTokens  = bcTokensTotal - bcTokensSold;
        uint256 grossNeeded = ((migrationTarget - raisedQuote) * BPS_DENOM + (BPS_DENOM - CURVE_FEE_BPS) - 1)
              / (BPS_DENOM - CURVE_FEE_BPS);

        if (quoteIn >= grossNeeded) {
            feeQuote  = (grossNeeded * CURVE_FEE_BPS) / BPS_DENOM;
            tokensOut = poolTokens;
        } else {
            feeQuote         = (quoteIn * CURVE_FEE_BPS + BPS_DENOM - 1) / BPS_DENOM;
            uint256 netQuote = quoteIn - feeQuote;
            tokensOut = poolTokens - ((k + poolQuote + netQuote - 1) / (poolQuote + netQuote));
        }
    }

    function previewSell(
        uint256 raisedQuote, uint256 virtualQuote, uint256 bcTokensTotal, uint256 bcTokensSold,
        uint256 k, uint256 tokensIn
    ) external pure returns (uint256 quoteOut, uint256 feeQuote) {
        uint256 poolQuote    = virtualQuote + raisedQuote;
        uint256 poolToks     = bcTokensTotal - bcTokensSold;
        uint256 newPoolToks  = poolToks + tokensIn;
        uint256 newPoolQuote = (k + newPoolToks - 1) / newPoolToks;
        uint256 grossQuote   = poolQuote > newPoolQuote ? poolQuote - newPoolQuote : 0;
        if (grossQuote > raisedQuote) return (0, 0);
        feeQuote = (grossQuote * CURVE_FEE_BPS + BPS_DENOM - 1) / BPS_DENOM;
        quoteOut = grossQuote - feeQuote;
    }

    function rescueToken(
        TokenConfig storage tc, address token_, address to, uint256 reservedRaised, uint256 reservedAccrued
    ) external returns (uint256 rescuable) {
        if (tc.token != address(0) && !tc.migrated) revert ActivePool();
        uint256 bal      = IERC20TransferBuy(token_).balanceOf(address(this));
        uint256 reserved = reservedRaised + reservedAccrued;
        if (bal <= reserved) revert ZeroAmount();
        rescuable = bal - reserved;
        if (!IERC20TransferBuy(token_).transfer(to, rescuable)) revert TransferFailed();
    }

    function setFeeSplits(
        FeeSplit[] storage feeSplits, address caller, address tcCreator, FeeSplit[] calldata splits_,
        uint256 maxFeeSplits
    ) external {
        if (tcCreator != caller) revert NotCreator();
        if (splits_.length > maxFeeSplits) revert TooManyFeeSplits();

        uint256 totalBps;
        for (uint256 i; i < splits_.length; ++i) {
            if (splits_[i].wallet == address(0)) revert ZeroAddress();
            totalBps += splits_[i].bps;
        }
        if (splits_.length > 0 && totalBps != BPS_DENOM) revert InvalidFeeSplitBps();

        while (feeSplits.length > 0) feeSplits.pop();
        for (uint256 i; i < splits_.length; ++i) {
            feeSplits.push(splits_[i]);
        }
    }

    function payCreator(
        FeeSplit[] memory splits, address creator_, address quoteToken_, uint256 amount
    ) external {
        _distributeFeeSplits(quoteToken_, creator_, amount, splits);
    }

    // Snapshotted into memory by every caller, never a live storage pointer: this loop makes an
    // external call per split, and a split wallet can be a creator-controlled contract. Reentering
    // setFeeSplits (gated only on caller == creator) mid-loop would otherwise let it replace
    // not-yet-paid entries and redirect the rest of the claim. Same fix as DuckGenesisHook._payCreator.
    function _distributeFeeSplits(address quoteToken_, address fallbackRecipient, uint256 amount, FeeSplit[] memory splits) private {
        if (splits.length == 0) {
            _payQuote(quoteToken_, fallbackRecipient, amount);
            return;
        }
        uint256 len = splits.length;
        uint256 remaining = amount;
        for (uint256 i; i < len; ++i) {
            uint256 cut = i == len - 1 ? remaining : (amount * splits[i].bps) / BPS_DENOM;
            remaining -= cut;
            _payQuote(quoteToken_, splits[i].wallet, cut);
        }
    }

    // A payout to this contract itself (sellForNative selling into its own balance) moves nothing.
    function _payQuote(address quoteToken_, address to, uint256 amount) private {
        if (amount == 0 || to == address(this)) return;
        if (!IERC20TransferBuy(quoteToken_).transfer(to, amount)) revert TransferFailed();
    }
}
