// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckReliquifyToken
//
// Token implementation cloned for a Reliquify migration. No transfer lock: DuckReliquify holds the
// entire fixed supply from mint until each depositor claims/receives their 1:1 share, so nothing
// circulates before the new pool exists. Behaviour lives in DuckOpenToken; this contract exists so
// migrated tokens verify under their own name.

import {DuckOpenToken} from "./DuckOpenToken.sol";

contract DuckReliquifyToken is DuckOpenToken {
    constructor(address vaultFactory_) DuckOpenToken(vaultFactory_) {}
}
