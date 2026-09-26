// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family -- deploy Liquifier to Robinhood Chain (4663), Ink (57073) or Arc (5042), at the
// SAME address on every one of them.
//
// Replaces the canonical Multicall3 as the approval target for QuiverX's self-built swap router
// engine (backend/src/chain/router/*), after a live incident: a bot drained Multicall3 approvals
// within one block of being granted, since Multicall3 executes arbitrary calldata for anyone, not
// just the approver. See liquifier/Liquifier.sol's header for the full explanation.
//
// This does NOT go through DuckProtocol's own per-chain DeterministicProxyFactory (Robinhood/Ink
// share one instance, Arc has a separate one at a different address -- confirmed live this session --
// so a proxy deployed through either would land at a DIFFERENT address on Arc than on Robinhood/Ink).
// Instead it uses forge's own default CREATE2 singleton factory (0x4e59b44847b379578588920cA78FbF26
// c0B4956C, the "Nick's method" deployer nearly every EVM chain has) via plain salted `new`
// expressions -- confirmed via eth_getCode to have real, identical bytecode on all three chains this
// session. Since a standard (non-Duck) ERC1967Proxy's address depends on BOTH the implementation
// address AND the exact init calldata (both are constructor arguments folded into the CREATE2 init
// code hash), nobody can front-run this salt to a DIFFERENT owner/treasury/feeBps without already
// knowing -- and matching -- the exact parameters this script uses; DuckProtocol's own factory's
// separate "deploy with empty init data, then atomically initialize" dance exists to solve a
// different problem (letting a factory owned by someone else pick the real owner after the fact) that
// doesn't apply here, where every parameter is already known upfront.
//
// Required env: DEPLOYER_ADDRESS (or PRIVATE_KEY) -- becomes the proxy's owner. TREASURY_ADDRESS --
// the multisig every fee is paid to; this script refuses to run without it rather than defaulting to
// the deployer, since silently routing real fee revenue to a throwaway deployer key is exactly the
// kind of mistake worth failing loudly on. Optional: FEE_BPS (defaults to 50, i.e. the same 0.5%
// SWAP_FEE_BPS default the backend uses).
//
// Router02/SwapRouter02/UniversalRouter/InkyPump addresses below are the SAME ones independently
// verified live on-chain this session for backend/src/chain/router/addresses.ts -- not re-derived,
// not guessed.
//
// Drop --broadcast for a dry run against live state first. Deploy to each chain in turn with the
// SAME DEPLOYER_ADDRESS/PRIVATE_KEY (the address matching that key affects nothing about the
// resulting Liquifier address -- CREATE2 here doesn't depend on the sender's own address at all,
// only the salts/bytecode/init data below -- but using the same key everywhere is still the sane
// default so one person/wallet is responsible for every chain's deploy transaction).

import {Script, console} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Liquifier} from "duck-liquifier/Liquifier.sol";

contract DeployLiquifier is Script {
    error UnsupportedChain(uint256 chainId);
    error TreasuryNotSet();

    uint256 constant ROBINHOOD_CHAIN_ID = 4663;
    uint256 constant INK_CHAIN_ID       = 57073;
    uint256 constant ARC_CHAIN_ID       = 5042;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3; // canonical, identical on all three chains

    // Verified live via eth_getCode this session -- see backend/src/chain/router/addresses.ts's own
    // header comment for the sourcing/verification method.
    address constant RH_V2_ROUTER02      = 0x89e5DB8B5aA49aA85AC63f691524311AEB649eba;
    address constant RH_SWAP_ROUTER02    = 0xCaf681a66D020601342297493863E78C959E5cb2;
    address constant RH_UNIVERSAL_ROUTER = 0x204FAca1764B154221e35c0d20aBb3c525710498;

    address constant INK_SWAP_ROUTER02    = 0x177778F19E89dD1012BdBe603F144088A95C4B53;
    address constant INK_UNIVERSAL_ROUTER = 0x661E93cca42AfacB172121EF892830cA3b70F08d;
    address constant INK_INKYPUMP_PROXY   = 0x4cC8F6d5B7cE150CCC0A9B7664532B1283b96AC4;

    address constant ARC_V2_ROUTER02      = 0x1f7d7550B1b028f7571E69A784071F0205FD2EfA;
    address constant ARC_SWAP_ROUTER02    = 0x53BF6B0684Ec7eF91e1387Da3D1a1769bC5A6F77;
    address constant ARC_UNIVERSAL_ROUTER = 0x8702463e73f74d0b6765aBceb314Ef07aCb92650;

    // "v1" -- Liquifier is new infrastructure, not an upgrade of anything. The SAME salts on every
    // chain, with the SAME implementation bytecode and the SAME (owner, treasury, feeBps, permit2)
    // init params, is exactly what makes the resulting proxy address identical everywhere.
    bytes32 constant SALT_LIQUIFIER_IMPL  = keccak256("duckfun.liquifier.v1.Liquifier.impl");
    bytes32 constant SALT_LIQUIFIER_PROXY = keccak256("duckfun.liquifier.v1.Liquifier.proxy");

    function run() external returns (address implAddr, address proxyAddr) {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer    = deployerKey != 0 ? vm.addr(deployerKey) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "Set DEPLOYER_ADDRESS (with --account/--ledger) or PRIVATE_KEY");

        address treasury = vm.envOr("TREASURY_ADDRESS", address(0));
        if (treasury == address(0)) revert TreasuryNotSet();
        uint16 feeBps = uint16(vm.envOr("FEE_BPS", uint256(50)));

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast(deployer);
        }

        // Same salt + same bytecode -> same implementation address on every chain (routed through
        // forge's default CREATE2 singleton factory automatically whenever a `{salt: ...}` is used
        // with --broadcast).
        implAddr = address(new Liquifier{salt: SALT_LIQUIFIER_IMPL}());

        // Same salt + same implementation + same init params -> same proxy address on every chain.
        bytes memory initData = abi.encodeCall(Liquifier.initialize, (deployer, treasury, feeBps, PERMIT2));
        proxyAddr = address(new ERC1967Proxy{salt: SALT_LIQUIFIER_PROXY}(implAddr, initData));
        Liquifier liquifier = Liquifier(payable(proxyAddr));

        if (block.chainid == ROBINHOOD_CHAIN_ID) {
            liquifier.setAllowedTarget(RH_V2_ROUTER02, true);
            liquifier.setAllowedTarget(RH_SWAP_ROUTER02, true);
            liquifier.setAllowedTarget(RH_UNIVERSAL_ROUTER, true);
            liquifier.setAllowedTarget(PERMIT2, true);
        } else if (block.chainid == INK_CHAIN_ID) {
            // No canonical Uniswap V2 on Ink -- matches chain/router/index.ts's own IN_SCOPE set.
            liquifier.setAllowedTarget(INK_SWAP_ROUTER02, true);
            liquifier.setAllowedTarget(INK_UNIVERSAL_ROUTER, true);
            liquifier.setAllowedTarget(PERMIT2, true);
            liquifier.setAllowedTarget(INK_INKYPUMP_PROXY, true);
        } else if (block.chainid == ARC_CHAIN_ID) {
            liquifier.setAllowedTarget(ARC_V2_ROUTER02, true);
            liquifier.setAllowedTarget(ARC_SWAP_ROUTER02, true);
            liquifier.setAllowedTarget(ARC_UNIVERSAL_ROUTER, true);
            liquifier.setAllowedTarget(PERMIT2, true);
        } else {
            revert UnsupportedChain(block.chainid);
        }

        vm.stopBroadcast();

        console.log("=== Liquifier deployed, chain", block.chainid, "===");
        console.log("Liquifier impl:  ", implAddr);
        console.log("Liquifier proxy: ", proxyAddr);
        console.log("owner:           ", deployer);
        console.log("treasury:        ", treasury);
        console.log("feeBps:          ", feeBps);
    }
}
