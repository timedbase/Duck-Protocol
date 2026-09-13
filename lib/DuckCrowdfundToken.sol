// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckCrowdfundToken
//
// Token implementation cloned for crowdfund launches (DuckCrowdfund). No transfer lock: during the raise
// the crowdfund contract holds the entire supply, and backers only receive tokens by claiming after the
// goal is met, so nothing circulates before the pool exists. Behaviour lives in DuckOpenToken; this
// contract exists so crowdfund tokens verify under their own name.

import {DuckOpenToken} from "./DuckOpenToken.sol";

contract DuckCrowdfundToken is DuckOpenToken {
    constructor(address vaultFactory_) DuckOpenToken(vaultFactory_) {}
}
