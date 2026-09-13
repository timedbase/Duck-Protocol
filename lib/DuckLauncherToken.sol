// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckLauncherToken
//
// Token implementation cloned for instant-pool launches (DuckLauncher). No transfer lock: the whole
// supply goes into the pool in the launch transaction, so the token trades from its first block.
// Behaviour lives in DuckOpenToken; this contract exists so launcher tokens verify under their own name.

import {DuckOpenToken} from "./DuckOpenToken.sol";

contract DuckLauncherToken is DuckOpenToken {
    constructor(address vaultFactory_) DuckOpenToken(vaultFactory_) {}
}
