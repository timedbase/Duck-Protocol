// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckProtocol shared types

struct FeeSplit {
    address wallet;
    uint16  bps;
}

struct TokenConfig {
    address   token;
    address   creator;
    address   quoteToken;

    uint256 totalSupply;
    uint256 liquidityTokens;
    uint256 bcTokensTotal;
    uint256 bcTokensSold;

    uint256 virtualQuote;
    uint256 k;
    uint256 raisedQuote;
    uint256 migrationTarget;

    address pair;
    bytes32 poolId;

    uint256 accruedFee;
    uint256 hookFeeBps;

    // Fully flexible three-way split of the 70% vault/creator/burn remainder (see
    // DuckHookV4.claimFees) -- must sum to exactly 10_000.
    uint16  creatorBps;
    uint16  vaultBps;
    uint16  burnBps;

    uint256 creationBlock;

    bool migrated;
    bool migrationPending;
}
