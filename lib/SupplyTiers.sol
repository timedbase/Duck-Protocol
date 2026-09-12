// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — SupplyTiers

library SupplyTiers {
    error InvalidSupplyTier(uint8 tier);

    function resolve(uint8 tier) internal pure returns (uint256 supply) {
        if (tier == 0) return 1_000_000_000e18;
        if (tier == 1) return 10_000_000_000e18;
        if (tier == 2) return 100_000_000_000e18;
        if (tier == 3) return 1_000_000_000_000e18;
        if (tier == 4) return 10_000_000_000_000e18;
        if (tier == 5) return 100_000_000_000_000e18;
        if (tier == 6) return 1_000_000_000_000_000e18;
        revert InvalidSupplyTier(tier);
    }
}
