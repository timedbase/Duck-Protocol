// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckBondingCurveViews

import {BondingCurveMath} from "duck-lib/BondingCurveMath.sol";
import {TokenConfig} from "duck-lib/DuckTypes.sol";

interface IDuckBondingCurveTokens {
    function getTokenConfig(address token) external view returns (TokenConfig memory);
}

contract DuckBondingCurveViews {
    error UnknownToken();

    address public immutable bondingCurve;

    constructor(address bondingCurve_) {
        bondingCurve = bondingCurve_;
    }

    function getAmountOut(address token_, uint256 quoteIn)
        external view
        returns (uint256 tokensOut, uint256 feeQuote)
    {
        TokenConfig memory tc = IDuckBondingCurveTokens(bondingCurve).getTokenConfig(token_);
        if (tc.token == address(0) || tc.migrated) return (0, 0);
        return BondingCurveMath.previewBuy(tc.migrationTarget, tc.raisedQuote, tc.virtualQuote, tc.bcTokensTotal, tc.bcTokensSold, tc.k, quoteIn);
    }

    function getAmountOutSell(address token_, uint256 tokensIn)
        external view
        returns (uint256 quoteOut, uint256 feeQuote)
    {
        TokenConfig memory tc = IDuckBondingCurveTokens(bondingCurve).getTokenConfig(token_);
        if (tc.token == address(0) || tc.migrated || tc.bcTokensSold < tokensIn) return (0, 0);
        return BondingCurveMath.previewSell(tc.raisedQuote, tc.virtualQuote, tc.bcTokensTotal, tc.bcTokensSold, tc.k, tokensIn);
    }

    function getSpotPrice(address token_) external view returns (uint256 price) {
        TokenConfig memory tc = IDuckBondingCurveTokens(bondingCurve).getTokenConfig(token_);
        if (tc.token == address(0)) revert UnknownToken();
        uint256 poolQuote  = tc.virtualQuote + tc.raisedQuote;
        uint256 poolTokens = tc.bcTokensTotal - tc.bcTokensSold;
        if (poolTokens == 0) return type(uint256).max;
        price = (poolQuote * 1e18) / poolTokens;
    }

    function predictTokenAddress(address creator_, bytes32 userSalt_, address impl_)
        external view
        returns (address predicted)
    {
        predicted = BondingCurveMath.predictTokenAddress(creator_, userSalt_, impl_, bondingCurve);
    }
}
