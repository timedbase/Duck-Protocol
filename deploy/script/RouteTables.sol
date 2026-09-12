// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — RouteTables
//
// Single source of truth for every quote token's swap routes. SetRoutes.s.sol writes these
// on-chain and SetRoutes.fork.t.sol swaps through each one, so the test proves exactly what the
// script configures. Regenerate from a fresh pool scan rather than hand-editing values.
//
// Each fee tier / tickSpacing was read off live pool state: v3 through the factory the chain's
// Universal Router itself is bound to, v4 by deriving the poolId from its PoolKey and reading
// liquidity and sqrtPriceX96 out of the PoolManager. Routes are ordered best-first by measured
// depth (USD, at ETH = $2,529.91 derived from the Robinhood USDG/WETH v3 pool); LaunchRouting
// falls through to the next entry when one reverts.

import {Route, RouteShape} from "duck-lib/LaunchRouting.sol";

library RouteTables {

    error UnsupportedChain(uint256 chainId);

    struct TokenRoutes {
        string  symbol;
        address token;
        Route[] routes;
    }

    uint256 internal constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 internal constant INK_CHAIN_ID       = 57073;

    function forChain(uint256 chainId) internal pure returns (TokenRoutes[] memory) {
        if (chainId == ROBINHOOD_CHAIN_ID) return robinhood();
        if (chainId == INK_CHAIN_ID)       return ink();
        revert UnsupportedChain(chainId);
    }

    function robinhood() internal pure returns (TokenRoutes[] memory t) {
        t = new TokenRoutes[](16);
        // BTC
        t[0].symbol = "BTC";
        t[0].token  = 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4;
        t[0].routes = new Route[](3);
        t[0].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4), _f(3000)); // $232,097
        t[0].routes[1] = _v4(2500, 25); // $49,414
        t[0].routes[2] = _v4(375, 4); // $21,066
        // USDG
        t[1].symbol = "USDG";
        t[1].token  = 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168;
        t[1].routes = new Route[](3);
        t[1].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168), _f(100)); // $12,372,281
        t[1].routes[1] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168), _f(500)); // $1,970,972
        t[1].routes[2] = _v4(100, 1); // $887,019
        // TAO
        t[2].symbol = "TAO";
        t[2].token  = 0xf3081494B87e8D5fb7960f066E931D1D0e6E3d67;
        t[2].routes = new Route[](1);
        t[2].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xf3081494B87e8D5fb7960f066E931D1D0e6E3d67), _f(10000)); // $41,331
        // U
        t[3].symbol = "U";
        t[3].token  = 0xcE24439F2D9C6a2289F741120FE202248B666666;
        t[3].routes = new Route[](1);
        t[3].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 0xcE24439F2D9C6a2289F741120FE202248B666666), _f(100, 3000)); // $10,110
        // SPY
        t[4].symbol = "SPY";
        t[4].token  = 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C;
        t[4].routes = new Route[](3);
        t[4].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x117cc2133c37B721F49dE2A7a74833232B3B4C0C), _f(500)); // $586,384
        t[4].routes[1] = _v4(1000, 10); // $79,023
        t[4].routes[2] = _v4(50000, 1000); // $22,877
        // NVDA
        t[5].symbol = "NVDA";
        t[5].token  = 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC;
        t[5].routes = new Route[](3);
        t[5].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC), _f(500)); // $511,478
        t[5].routes[1] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC), _f(3000)); // $146,223
        t[5].routes[2] = _v4(50000, 1000); // $51,463
        // SPCX
        t[6].symbol = "SPCX";
        t[6].token  = 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa;
        t[6].routes = new Route[](3);
        t[6].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa), _f(500)); // $427,586
        t[6].routes[1] = _v4(3000, 30); // $113,759
        t[6].routes[2] = _v4(10000, 200); // $17,995
        // AAPL
        t[7].symbol = "AAPL";
        t[7].token  = 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9;
        t[7].routes = new Route[](3);
        t[7].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9), _f(500)); // $130,663
        t[7].routes[1] = _v4(2500, 25); // $57,752
        t[7].routes[2] = _v4(50000, 1000); // $1,418
        // TSLA
        t[8].symbol = "TSLA";
        t[8].token  = 0x322F0929c4625eD5bAd873c95208D54E1c003b2d;
        t[8].routes = new Route[](3);
        t[8].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x322F0929c4625eD5bAd873c95208D54E1c003b2d), _f(3000)); // $190,055
        t[8].routes[1] = _v4(2500, 25); // $21,388
        t[8].routes[2] = _v4(50000, 1000); // $21,328
        // GLD
        t[9].symbol = "GLD";
        t[9].token  = 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e;
        t[9].routes = new Route[](3);
        t[9].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e), _f(10000)); // $257,278
        t[9].routes[1] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e), _f(500)); // $117,166
        t[9].routes[2] = _v4(50000, 500); // $8,068
        // GOOGL
        t[10].symbol = "GOOGL";
        t[10].token  = 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3;
        t[10].routes = new Route[](3);
        t[10].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3), _f(100, 500)); // $949,347
        t[10].routes[1] = _v4(10000, 200); // $78,743
        t[10].routes[2] = _v4(1000, 10); // $18,034
        // QQQ
        t[11].symbol = "QQQ";
        t[11].token  = 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68;
        t[11].routes = new Route[](3);
        t[11].routes[0] = _v4(10000, 200); // $114,754
        t[11].routes[1] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xD5f3879160bc7c32ebb4dC785F8a4F505888de68), _f(3000)); // $66,721
        t[11].routes[2] = _v4(9000, 90); // $6,343
        // MSTR
        t[12].symbol = "MSTR";
        t[12].token  = 0xec262a75e413fAfD0dF80480274532C79D42da09;
        t[12].routes = new Route[](3);
        t[12].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xec262a75e413fAfD0dF80480274532C79D42da09), _f(10000)); // $199,190
        t[12].routes[1] = _v4(2500, 25); // $115,557
        t[12].routes[2] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0xec262a75e413fAfD0dF80480274532C79D42da09), _f(3000)); // $36,187
        // GME
        t[13].symbol = "GME";
        t[13].token  = 0x1b0E319c6A659F002271B69dB8A7df2F911c153E;
        t[13].routes = new Route[](3);
        t[13].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x1b0E319c6A659F002271B69dB8A7df2F911c153E), _f(500)); // $55,634
        t[13].routes[1] = _v4(9000, 90); // $28,293
        t[13].routes[2] = _v4(2500, 25); // $1,307
        // AMZN
        t[14].symbol = "AMZN";
        t[14].token  = 0x12f190a9F9d7D37a250758b26824B97CE941bF54;
        t[14].routes = new Route[](2);
        t[14].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 0x12f190a9F9d7D37a250758b26824B97CE941bF54), _f(100, 3000)); // $773,877
        t[14].routes[1] = _v4(2990, 30); // $24,226
        // MSFT
        t[15].symbol = "MSFT";
        t[15].token  = 0xe93237C50D904957Cf27E7B1133b510C669c2e74;
        t[15].routes = new Route[](2);
        t[15].routes[0] = _v3(_a(0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73, 0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168, 0xe93237C50D904957Cf27E7B1133b510C669c2e74), _f(100, 3000)); // $482,597
        t[15].routes[1] = _v4(10000, 200); // $61,816
    }

    // Ink's tokenized stocks trade against Ink USDG on v3 (fee 500), and USDG's only reachable pool
    // is WETH/USDG at fee 10000, so USDG and every stock route through it. That pool is the
    // bottleneck for all eight: ~1.83 WETH / ~$12.7k USDG at scan time, so large sells back to
    // native move price sharply and rely on the caller's minOut. There is no USDT0/USDG or
    // USDC/USDG depth to hop through instead, and the hooked v4 stock/USDG pools are empty.
    function ink() internal pure returns (TokenRoutes[] memory t) {
        t = new TokenRoutes[](11);
        // BTC
        t[0].symbol = "BTC";
        t[0].token  = 0x73E0C0d45E048D25Fc26Fa3159b0aA04BfA4Db98;
        t[0].routes = new Route[](1);
        t[0].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0x0200C29006150606B650577BBE7B6248F58470c1, 0x73E0C0d45E048D25Fc26Fa3159b0aA04BfA4Db98), _f(3000, 3000)); // $496,321
        // USDT0
        t[1].symbol = "USDT0";
        t[1].token  = 0x0200C29006150606B650577BBE7B6248F58470c1;
        t[1].routes = new Route[](1);
        t[1].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0x0200C29006150606B650577BBE7B6248F58470c1), _f(3000)); // $496,321
        // USDCe
        t[2].symbol = "USDCe";
        t[2].token  = 0xF1815bd50389c46847f0Bda824eC8da914045D14;
        t[2].routes = new Route[](1);
        t[2].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0xF1815bd50389c46847f0Bda824eC8da914045D14), _f(3000)); // $21,203
        // USDG
        t[3].symbol = "USDG";
        t[3].token  = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D;
        t[3].routes = new Route[](1);
        t[3].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0xe343167631d89B6Ffc58B88d6b7fB0228795491D), _f(10000)); // $4,621
        // NVDAw
        t[4].symbol = "NVDAw";
        t[4].token  = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5;
        t[4].routes = new Route[](1);
        t[4].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0xe343167631d89B6Ffc58B88d6b7fB0228795491D, 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5), _f(10000, 500)); // $4,621
        // MSTRw
        t[5].symbol = "MSTRw";
        t[5].token  = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB;
        t[5].routes = new Route[](1);
        t[5].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0xe343167631d89B6Ffc58B88d6b7fB0228795491D, 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB), _f(10000, 500)); // $4,621
        // SPYw
        t[6].symbol = "SPYw";
        t[6].token  = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540;
        t[6].routes = new Route[](1);
        t[6].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0xe343167631d89B6Ffc58B88d6b7fB0228795491D, 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540), _f(10000, 500)); // $4,621
        // SPCXw
        t[7].symbol = "SPCXw";
        t[7].token  = 0x8e2eeD8b8B5E13Ea7BF38e50d7821d2C57309072;
        t[7].routes = new Route[](1);
        t[7].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0xe343167631d89B6Ffc58B88d6b7fB0228795491D, 0x8e2eeD8b8B5E13Ea7BF38e50d7821d2C57309072), _f(10000, 500)); // $4,621
        // AAPLw
        t[8].symbol = "AAPLw";
        t[8].token  = 0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f;
        t[8].routes = new Route[](1);
        t[8].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0xe343167631d89B6Ffc58B88d6b7fB0228795491D, 0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f), _f(10000, 500)); // $4,621
        // NFLXw
        t[9].symbol = "NFLXw";
        t[9].token  = 0x7d87fD6A379714194a797c0bBB8B40c30D250856;
        t[9].routes = new Route[](1);
        t[9].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0xe343167631d89B6Ffc58B88d6b7fB0228795491D, 0x7d87fD6A379714194a797c0bBB8B40c30D250856), _f(10000, 500)); // $4,621
        // TSLAw
        t[10].symbol = "TSLAw";
        t[10].token  = 0xc3FdBe3A68EE5dE461D30415a8165cf9Aefe1171;
        t[10].routes = new Route[](1);
        t[10].routes[0] = _v3(_a(0x4200000000000000000000000000000000000006, 0xe343167631d89B6Ffc58B88d6b7fB0228795491D, 0xc3FdBe3A68EE5dE461D30415a8165cf9Aefe1171), _f(10000, 500)); // $4,621
    }

    // Curated Ink quote tokens that are routed above but were disabled by an earlier SetRoutes run
    // (before their USDG-paired v3 pools were found), plus USDG itself. SetRoutes re-enables them.
    function inkEnable() internal pure returns (address[] memory e) {
        e = new address[](8);
        e[0] = 0xe343167631d89B6Ffc58B88d6b7fB0228795491D; // USDG
        e[1] = 0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5; // NVDAw
        e[2] = 0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB; // MSTRw
        e[3] = 0xE7E553Cd128F0011777323A0b44a7b96EA1CB540; // SPYw
        e[4] = 0x8e2eeD8b8B5E13Ea7BF38e50d7821d2C57309072; // SPCXw
        e[5] = 0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f; // AAPLw
        e[6] = 0x7d87fD6A379714194a797c0bBB8B40c30D250856; // NFLXw
        e[7] = 0xc3FdBe3A68EE5dE461D30415a8165cf9Aefe1171; // TSLAw
    }

    function _v3(address[] memory path, uint24[] memory fees) private pure returns (Route memory) {
        return Route({shape: RouteShape.V3_STYLE, enabled: true, path: path, fees: fees,
                       hook: address(0), fee: 0, tickSpacing: 0});
    }

    function _v4(uint24 fee, int24 tickSpacing) private pure returns (Route memory) {
        return Route({shape: RouteShape.V4_STYLE, enabled: true,
                       path: new address[](0), fees: new uint24[](0),
                       hook: address(0), fee: fee, tickSpacing: tickSpacing});
    }

    function _a(address a0, address a1) private pure returns (address[] memory p) {
        p = new address[](2); p[0] = a0; p[1] = a1;
    }

    function _a(address a0, address a1, address a2) private pure returns (address[] memory p) {
        p = new address[](3); p[0] = a0; p[1] = a1; p[2] = a2;
    }

    function _f(uint24 f0) private pure returns (uint24[] memory f) {
        f = new uint24[](1); f[0] = f0;
    }

    function _f(uint24 f0, uint24 f1) private pure returns (uint24[] memory f) {
        f = new uint24[](2); f[0] = f0; f[1] = f1;
    }
}
