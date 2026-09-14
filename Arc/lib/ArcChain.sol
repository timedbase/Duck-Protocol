// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — Arc chain constants
//
// Arc mainnet (5042) is a stablechain: USDC is the native gas token, at 18 decimals, and the ERC-20 at
// ARC_USDC is the same balance at 6 decimals -- moving one moves the other. There is no WETH and nothing to
// wrap. Every quote asset in this tree is an ERC-20; native USDC paid in or out is that same USDC, converted
// by NATIVE_PER_USDC.

uint256 constant ARC_CHAIN_ID = 5042;
address constant ARC_USDC = 0x3600000000000000000000000000000000000000;
uint256 constant NATIVE_PER_USDC = 1e12;

error NotArcChain(uint256 chainId);

// Run by the Arc contracts' constructors, so this build can't be deployed to another chain by mistake.
function requireArcChain() view {
    if (block.chainid != ARC_CHAIN_ID) revert NotArcChain(block.chainid);
}
