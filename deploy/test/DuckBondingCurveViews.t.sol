// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckCurveToken} from "duck-lib/DuckCurveToken.sol";
import {DuckBondingCurveViews} from "duck-bonding-curve/DuckBondingCurveViews.sol";
import {TokenConfig} from "duck-lib/DuckTypes.sol";
import {SupplyTiers} from "duck-lib/SupplyTiers.sol";

contract DuckBondingCurveViewsTest is Test {
    DuckBondingCurve curve;
    DuckBondingCurveViews views_;
    DuckCurveToken tokenImpl;

    address owner = makeAddr("owner");
    address platformWallet = makeAddr("platform");
    address creator = makeAddr("creator");
    address dummyWeth = makeAddr("weth");
    address dummyV4PM = makeAddr("v4pm");
    address dummyV4Singleton = makeAddr("v4singleton");
    // DuckOpenToken.initToken now requires a real (non-zero) hook/poolManager at mint time -- reward
    // config is set there now, not through a later setRewardConfig call (see its own comment).
    address dummyV4Hook = makeAddr("v4hook");

    function setUp() public {
        vm.startPrank(owner);
        tokenImpl = new DuckCurveToken(address(0));
        DuckBondingCurve impl = new DuckBondingCurve();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(DuckBondingCurve.initialize, (
                dummyWeth, dummyV4PM, dummyV4Singleton, dummyV4Hook,
                platformWallet, address(tokenImpl)
            ))
        );
        curve = DuckBondingCurve(payable(address(proxy)));
        vm.stopPrank();

        views_ = new DuckBondingCurveViews(address(curve));

        vm.deal(creator, 10 ether);
    }

    function _mineVanitySalt(uint256 seed) internal view returns (bytes32 userSalt) {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            address(tokenImpl),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = 0; i < 200_000; i++) {
            userSalt = bytes32(seed + i);
            bytes32 salt = keccak256(abi.encode(creator, userSalt));
            address predicted = address(uint160(uint256(keccak256(abi.encodePacked(
                bytes1(0xff), address(curve), salt, initCodeHash
            )))));
            if (uint16(uint160(predicted)) == 0x8888) return userSalt;
        }
        revert("salt not found");
    }

    function _createNativeToken() internal returns (address token) {
        DuckBondingCurve.BaseParams memory p;
        p.name = "Test";
        p.symbol = "TEST";
        p.supplyTier = 0;
        p.curveBps = 8_000;
        p.liquidityBps = 2_000;
        p.quoteToken = address(0);
        p.startVirtualQuote = 1 ether;
        p.migrationTargetQuote = 10 ether;
        p.hookFeeBps = 0;
        p.creatorBps = 10_000;
        p.metaURI = "";
        p.salt = _mineVanitySalt(1);

        vm.prank(creator);
        token = curve.createToken{value: 0.0005 ether}(p);
    }

    function test_ViewsMatchDirectStorageReads() public {
        address token = _createNativeToken();

        TokenConfig memory tc = curve.getTokenConfig(token);

        assertEq(tc.token, token, "sanity: token field itself must round-trip");
        assertFalse(tc.migrated, "fresh token should not be migrated");
        assertGt(tc.bcTokensTotal, 0);
        assertEq(tc.bcTokensSold, 0);
        assertEq(tc.virtualQuote, 1 ether);
        assertGt(tc.k, 0);
        assertEq(tc.raisedQuote, 0);
        assertEq(tc.migrationTarget, 10 ether);

        uint256 expectedPrice = ((tc.virtualQuote + tc.raisedQuote) * 1e18) / (tc.bcTokensTotal - tc.bcTokensSold);
        assertEq(views_.getSpotPrice(token), expectedPrice, "getSpotPrice must match a manual computation from the same fields");

        (uint256 tokensOut, ) = views_.getAmountOut(token, 0.1 ether);
        assertGt(tokensOut, 0, "getAmountOut must price a real buy on a live, unmigrated token");

        (uint256 quoteOut, uint256 feeQuote) = views_.getAmountOutSell(token, 1e18);
        assertEq(quoteOut, 0);
        assertEq(feeQuote, 0);
    }

    function test_ViewsRevertOnUnknownToken() public {
        vm.expectRevert(DuckBondingCurveViews.UnknownToken.selector);
        views_.getSpotPrice(makeAddr("not-a-token"));

        (uint256 tokensOut, uint256 feeQuote) = views_.getAmountOut(makeAddr("not-a-token"), 1 ether);
        assertEq(tokensOut, 0);
        assertEq(feeQuote, 0);
    }

    function test_NonDefaultSupplyTierProducesRealCorrectSupply() public {
        DuckBondingCurve.BaseParams memory p;
        p.name = "Test3";
        p.symbol = "TEST3";
        p.supplyTier = 5;
        p.curveBps = 8_000;
        p.liquidityBps = 2_000;
        p.quoteToken = address(0);
        p.startVirtualQuote = 1 ether;
        p.migrationTargetQuote = 10 ether;
        p.hookFeeBps = 0;
        p.creatorBps = 10_000;
        p.metaURI = "";
        p.salt = _mineVanitySalt(2_000_000);

        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        TokenConfig memory tc = curve.getTokenConfig(token);
        assertEq(tc.totalSupply, 100_000_000_000_000e18, "tier 3 must resolve to 100T on the real TokenConfig");
        assertEq(DuckCurveToken(payable(token)).totalSupply(), 100_000_000_000_000e18, "the real deployed token's own totalSupply must match too");
    }

    function test_InvalidSupplyTierReverts() public {
        DuckBondingCurve.BaseParams memory p;
        p.name = "Test4";
        p.symbol = "TEST4";
        p.supplyTier = 7;
        p.curveBps = 8_000;
        p.liquidityBps = 2_000;
        p.quoteToken = address(0);
        p.startVirtualQuote = 1 ether;
        p.migrationTargetQuote = 10 ether;
        p.hookFeeBps = 0;
        p.creatorBps = 10_000;
        p.metaURI = "";
        p.salt = _mineVanitySalt(3_000_000);

        vm.prank(creator);
        vm.expectRevert(abi.encodeWithSelector(SupplyTiers.InvalidSupplyTier.selector, 7));
        curve.createToken{value: 0.0005 ether}(p);
    }

    function test_PredictTokenAddressMatchesRealClone() public {
        bytes32 salt = _mineVanitySalt(1_000_000);
        address predicted = views_.predictTokenAddress(creator, salt, address(tokenImpl));

        DuckBondingCurve.BaseParams memory p;
        p.name = "Test2";
        p.symbol = "TEST2";
        p.supplyTier = 0;
        p.curveBps = 8_000;
        p.liquidityBps = 2_000;
        p.quoteToken = address(0);
        p.startVirtualQuote = 1 ether;
        p.migrationTargetQuote = 10 ether;
        p.hookFeeBps = 0;
        p.creatorBps = 10_000;
        p.metaURI = "";
        p.salt = salt;

        vm.prank(creator);
        address token = curve.createToken{value: 0.0005 ether}(p);

        assertEq(token, predicted, "predictTokenAddress must match the real CREATE2 clone address");
    }
}
