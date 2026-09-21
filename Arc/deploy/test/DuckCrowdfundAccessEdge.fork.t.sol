// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {DuckCrowdfundAccessForkTest} from "./DuckCrowdfundAccess.fork.t.sol";
import {DuckCrowdfund} from "duck-crowdfund/DuckCrowdfund.sol";
import {ARC_USDC} from "duck-lib/ArcChain.sol";

// Edge cases specific to Arc: native and ERC-20 USDC counted together against one cap, and a Merkle tree built by
// OpenZeppelin's JavaScript library verifying on Arc's crowdfund. (Arc only accepts USDC as a quote asset, so the
// reentrant-token attack that the main tree tests has no equivalent here.)
contract DuckCrowdfundAccessEdgeForkTest is DuckCrowdfundAccessForkTest {
    bytes32 constant GOLDEN_ROOT = bytes32(hex"c411cf60ff907cde4774cdd0333b5659177f17c1c6d7d547dafa0e7c55c79279");

    function _v0() internal pure returns (address who, uint256 alloc, bytes32[] memory proof) {
        who = 0x1111111111111111111111111111111111111111; alloc = 2000000000000000000;
        proof = new bytes32[](2);
        proof[0] = bytes32(hex"9694aad26366c1a13937d53fdcb3c150ebe7e3e53fa12303e176e187ae22ebe6"); proof[1] = bytes32(hex"f63859d69ba74fd67145b4af8b50f2e4b7dac93778440b45d8204b4a767dd0cc");
    }
    function _v1() internal pure returns (address who, uint256 alloc, bytes32[] memory proof) {
        who = 0x2222222222222222222222222222222222222222; alloc = 0;
        proof = new bytes32[](3);
        proof[0] = bytes32(hex"0b1d90b0e7d29c2588d86c1e1bb8a158475b96163427fae174b972cffb49e8b2"); proof[1] = bytes32(hex"ff483dc090f279fd8cb50b2866181b0b5880159bbc5818a2b945fe4ac5ff9b5a"); proof[2] = bytes32(hex"7ba02cf4b55c42f8fd672e5a65b3efd7caf4ac8714a487184618702638513e3d");
    }
    function _v2() internal pure returns (address who, uint256 alloc, bytes32[] memory proof) {
        who = 0x3333333333333333333333333333333333333333; alloc = 5000000000000000000;
        proof = new bytes32[](2);
        proof[0] = bytes32(hex"3dc412b05bc780519fa9fef313bfb123ad198b5f9ca0edd3f61d7ddb104be2c2"); proof[1] = bytes32(hex"f63859d69ba74fd67145b4af8b50f2e4b7dac93778440b45d8204b4a767dd0cc");
    }
    function _v3() internal pure returns (address who, uint256 alloc, bytes32[] memory proof) {
        who = 0x4444444444444444444444444444444444444444; alloc = 1000000000000000000;
        proof = new bytes32[](2);
        proof[0] = bytes32(hex"57cb6d5c5f3673560078a5c756817663764f42dee17eeb9732f639c3153d8076"); proof[1] = bytes32(hex"7ba02cf4b55c42f8fd672e5a65b3efd7caf4ac8714a487184618702638513e3d");
    }
    function _v4() internal pure returns (address who, uint256 alloc, bytes32[] memory proof) {
        who = 0x5555555555555555555555555555555555555555; alloc = 300000000000000000;
        proof = new bytes32[](3);
        proof[0] = bytes32(hex"0d02b43834e4ef903a8525caf00ef0d8cc8867a465e14e1533f7c53aa730641b"); proof[1] = bytes32(hex"ff483dc090f279fd8cb50b2866181b0b5880159bbc5818a2b945fe4ac5ff9b5a"); proof[2] = bytes32(hex"7ba02cf4b55c42f8fd672e5a65b3efd7caf4ac8714a487184618702638513e3d");
    }

    function test_GoldenVector_JsBuiltTreeVerifiesOnArc() public {
        uint256 id = crowdfund.campaignCount();
        assertEq(id, 0, "the vector was built for campaign id 0");
        _launch(DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Whitelist, maxPerWallet: 0, whitelistRoot: GOLDEN_ROOT, whitelistURI: "ipfs://list"}), 1_000e6);
        address w; uint256 alloc; bytes32[] memory proof;
        for (uint256 i; i < 5; ++i) {
            if (i == 0) (w, alloc, proof) = _v0();
            else if (i == 1) (w, alloc, proof) = _v1();
            else if (i == 2) (w, alloc, proof) = _v2();
            else if (i == 3) (w, alloc, proof) = _v3();
            else (w, alloc, proof) = _v4();
            assertTrue(crowdfund.isWhitelisted(id, w, alloc, proof), "the view accepts the JS proof");
            assertFalse(crowdfund.isWhitelisted(id, stranger, alloc, proof));
            vm.deal(w, 100e18);
            vm.prank(w);
            crowdfund.contributeWhitelisted{value: 5e18}(id, 0, alloc, proof); // 5 USDC, well inside every allocation here
            assertEq(crowdfund.contributed(id, w), 5e6);
        }
    }

    /// forge-config: default.fuzz.runs = 64
    function testFuzz_MixedNativeAndErc20_CountTowardOneCap(uint32[6] memory seeds) public {
        uint256 cap = 100e6;
        uint256 id = _launch(DuckCrowdfund.AccessParams({mode: DuckCrowdfund.AccessMode.Open, maxPerWallet: cap, whitelistRoot: bytes32(0), whitelistURI: ""}), 10_000e6);
        vm.deal(w1, 1_000e18);
        vm.prank(w1); usdc.approve(d.crowdfund, type(uint256).max);
        uint256 total;
        for (uint256 i; i < 6; ++i) {
            uint256 amt = 1e6 + (uint256(seeds[i]) % 60e6);        // 1..60 USDC, in ERC-20 units
            bool native = seeds[i] % 2 == 0;
            vm.prank(w1);
            if (total + amt > cap) {
                vm.expectRevert(abi.encodeWithSelector(DuckCrowdfund.ExceedsWalletCap.selector, cap, total));
                if (native) crowdfund.contribute{value: amt * 1e12}(id, 0); else crowdfund.contribute(id, amt);
            } else {
                if (native) crowdfund.contribute{value: amt * 1e12}(id, 0); else crowdfund.contribute(id, amt);
                total += amt;
            }
        }
        assertEq(crowdfund.contributed(id, w1), total);
        assertLe(total, cap);
    }
}
