// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {PoolKey, ExactInSingleArc} from "duck-lib/LaunchRouting.sol";

// Universal Router's V4_SWAP reads SWAP_EXACT_IN_SINGLE's params as one ABI-encoded struct. These vectors come from the
// main app's own encoder (viem's encodeAbiParameters over the same tuple, frontend/src/chain/dex.js), which is what
// users' swaps already go through on Arc (same router build as Robinhood Chain), so matching them byte for byte is the check that
// the on-chain routes speak the router's real format. (A flat abi.encode of the loose fields has no leading offset
// word and does not match: that was the bug.)
contract RouteEncodingTest is Test {
    function _key() private pure returns (PoolKey memory) {
        return PoolKey({
            currency0: 0x3600000000000000000000000000000000000000,
            currency1: 0x1111111111111111111111111111111111111111,
            fee: 0,
            tickSpacing: 200,
            hooks: 0x6A44E6a1dF1e4cC329Dda87389ecA12DA9422aCC
        });
    }

    function test_Arc_MatchesTheAppsEncoder() public pure {
        bytes memory got = abi.encode(ExactInSingleArc(_key(), true, 1234567, 7654321, 0, ""));
        assertEq(got, hex"000000000000000000000000000000000000000000000000000000000000002000000000000000000000000036000000000000000000000000000000000000000000000000000000000000001111111111111111111111111111111111111111000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c80000000000000000000000006a44e6a1df1e4cc329dda87389eca12da9422acc0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000000000000000000000000000000000000012d687000000000000000000000000000000000000000000000000000000000074cbb1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001400000000000000000000000000000000000000000000000000000000000000000");
    }

    function test_FlatEncodingIsNotTheRoutersFormat() public pure {
        bytes memory flat = abi.encode(_key(), true, uint128(1234567), uint128(7654321), uint256(0), bytes(""));
        assertTrue(keccak256(flat) != keccak256(abi.encode(ExactInSingleArc(_key(), true, 1234567, 7654321, 0, ""))));
    }
}

