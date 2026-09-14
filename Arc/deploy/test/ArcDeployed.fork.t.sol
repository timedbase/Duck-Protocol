// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// ArcProtocolForkTest's end-to-end checks, run against the contracts actually deployed on Arc mainnet by
// DeployDuckProtocolArc (broadcast 2026-09-14) instead of a fresh deploy inside the fork: curve, launcher and
// crowdfund on USDC, native and ERC-20, through the live DuckGenesisHook, vaults and Arc's PoolManager.
//
//   ARC_RPC_URL=https://rpc.arc-scan.org forge test --match-path test/ArcDeployed.fork.t.sol

import {ArcProtocolForkTest} from "./ArcProtocol.fork.t.sol";
import {MockArcUsdc} from "./utils/MockArcUsdc.sol";
import {ARC_USDC} from "duck-lib/ArcChain.sol";
import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckLauncher} from "duck-launcher/DuckLauncher.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {DuckGenesisHook} from "duck-shared/DuckGenesisHook.sol";

contract ArcDeployedForkTest is ArcProtocolForkTest {
    function setUp() public override {
        vm.createSelectFork(vm.envOr("ARC_RPC_URL", string("https://rpc.arc-scan.org")));
        assertEq(block.chainid, 5042, "Arc mainnet fork");
        vm.etch(ARC_USDC, address(new MockArcUsdc()).code);
        vm.allowCheatcodes(ARC_USDC);

        owner    = 0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7;
        platform = 0x1c723Cf0451e6635C748283a3e87413079E7C198;

        d.proxyFactory    = 0x3C94F9a48Ce7Ae50CeC57ddeE29F786a5bADe01b;
        d.vaultConfig     = 0xb0d1E41Af535a986e61A9ce39ea31e7ef65A4EE8;
        d.vaultImpl       = 0xf2D432D939Ce85539886967fEbB08b329D556b3F;
        d.hookFactory     = 0x66080d1fD50779A1Bc663472571deFACa24B73Ba;
        d.hook            = 0x6A44E6a1dF1e4cC329Dda87389ecA12DA9422aCC;
        d.vaultFactory    = 0xE3D4d83307E6f5A2C7B4b85436eAacAfd1B873C3;
        d.curveToken      = 0x096E8400214ce0D24BC31266eA4FfE2F02A63f91;
        d.launcherToken   = 0x07288E38f6f7FdDc4f45521723aBCBEb68da0855;
        d.crowdfundToken  = 0xd26a394CE738B9cbdE41745e3392b48AF8309D18;
        d.curve           = 0xFD5FAE76B375e1dA6A3F1759eB84B26b39dE706C;
        d.curveViews      = 0x927Eb28e767a07F4470Db96A1eC31cb637315cB2;
        d.launcher        = 0xf916E628503639DCb4726d4B75745Ad678dc4d02;
        d.crowdfund       = 0x0c8f0f1353f2d963D03C3eC558D20b151DaF7214;
        d.governorFactory = 0x3271b5e9F53E5096508519126528373Adc4e3Aec;

        curve = DuckBondingCurve(payable(d.curve));
        launcher = DuckLauncher(payable(d.launcher));
        crowdfund = DuckCrowdfund(payable(d.crowdfund));
        hook = DuckGenesisHook(payable(d.hook));
    }
}
