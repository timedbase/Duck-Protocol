// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckCurveToken
//
// Token implementation cloned for bonding-curve launches (DuckBondingCurve). No transfer lock: the lock
// existed so nobody could seed the token's pool before migration, and DuckGenesisHook already refuses to
// initialize a pool its launchers haven't registered or to take liquidity from anyone but them.
// Behaviour lives in DuckOpenToken; this contract exists so curve tokens verify under their own name.

import {DuckOpenToken} from "./DuckOpenToken.sol";

contract DuckCurveToken is DuckOpenToken {
    constructor(address vaultFactory_) DuckOpenToken(vaultFactory_) {}
}
