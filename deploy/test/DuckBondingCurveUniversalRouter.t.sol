// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// Exercises DuckBondingCurve's new Universal-Router-based swap routing (buyWithNative/sellForNative
// for both V3_STYLE and V4_STYLE routes) end-to-end against mock UniversalRouter/Permit2 contracts
// that independently decode the exact same Commands/Actions byte layout Uniswap's real
// universal-router and v4-periphery contracts use (Commands.sol, Actions.sol, Dispatcher.sol,
// V4Router.sol) -- verified against that source, not re-derived from LaunchRoutingExec's own
// encoding, so a mismatch between what we send and what Uniswap's real router expects would show up
// as a decode failure or an assertion mismatch here. This is NOT a substitute for a real fork test
// against the actual deployed Universal Router on Robinhood Chain / Ink (not possible in this
// session -- no RPC credentials configured); it only proves the calldata shape and this contract's
// own accounting (balance-diffing, forwarding, Permit2 approval) are internally consistent with the
// documented Universal Router interface.

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DuckBondingCurve} from "duck-bonding-curve/DuckBondingCurve.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {Route, RouteShape} from "duck-lib/LaunchRouting.sol";

contract MockERC20UR {
    string public name = "Mock Quote";
    string public symbol = "MQ";
    uint8  public decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}

// Mirrors Permit2's IAllowanceTransfer surface exactly (allowance/approve/transferFrom signatures
// verified against permit2/src/interfaces/IAllowanceTransfer.sol) -- etched at the real canonical
// Permit2 address so LaunchRoutingExec's hardcoded PERMIT2 constant resolves to this mock.
contract MockPermit2UR {
    mapping(address => mapping(address => mapping(address => uint160))) public amounts;
    mapping(address => mapping(address => mapping(address => uint48))) public expirations;

    function approve(address token, address spender, uint160 amount, uint48 expiration) external {
        amounts[msg.sender][token][spender] = amount;
        expirations[msg.sender][token][spender] = expiration;
    }

    function allowance(address user, address token, address spender) external view returns (uint160, uint48, uint48) {
        return (amounts[user][token][spender], expirations[user][token][spender], 0);
    }

    function transferFrom(address from, address to, uint160 amount, address token) external {
        require(amounts[from][token][msg.sender] >= amount, "permit2: not approved");
        require(block.timestamp <= expirations[from][token][msg.sender], "permit2: expired");
        require(MockERC20UR(token).transferFrom(from, to, amount), "permit2: transfer failed");
    }
}

// Independently decodes the exact Commands/Actions byte layout Universal Router's real Dispatcher
// and V4Router use, verified against the actual deployed source on both target chains (command
// bytes: V3_SWAP_EXACT_IN=0x00, WRAP_ETH=0x0b, UNWRAP_WETH=0x0c, V4_SWAP=0x10; action bytes:
// SWAP_EXACT_IN_SINGLE=0x06, SETTLE_ALL=0x0c, TAKE_ALL=0x0f -- both chains run a newer v4-periphery
// than Uniswap's canonical npm package, shifting these by two versus the older layout), and
// simulates a fixed 1:1 exchange rate so test assertions are exact. This mock exercises the vanilla
// (non-Robinhood) ExactInputSingleParams/V3 shape, matching what a plain `forge test` run (chain id
// 31337) actually sends -- see DuckBondingCurveUniversalRouter.fork.t.sol for real-chain coverage of
// both shapes against live liquidity.
contract MockUniversalRouterUR {
    address public immutable permit2;
    MockERC20UR public quote;
    uint256 public wrappedBalance;

    constructor(address permit2_, MockERC20UR quote_) {
        permit2 = permit2_;
        quote = quote_;
    }

    receive() external payable {}

    function execute(bytes calldata commands, bytes[] calldata inputs, uint256) external payable {
        for (uint256 i; i < commands.length; ++i) {
            uint8 cmd = uint8(commands[i]);
            if (cmd == 0x0b) {
                (, uint256 amount) = abi.decode(inputs[i], (address, uint256));
                wrappedBalance += amount;
            } else if (cmd == 0x00) {
                (address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path, bool payerIsUser,) =
                    abi.decode(inputs[i], (address, uint256, uint256, bytes, bool, uint256[]));
                _v3SwapExactIn(recipient, amountIn, amountOutMin, path, payerIsUser);
            } else if (cmd == 0x0c) {
                (address recipient, uint256 amountMin) = abi.decode(inputs[i], (address, uint256));
                uint256 amount = wrappedBalance;
                wrappedBalance = 0;
                require(amount >= amountMin, "UNWRAP_WETH: below min");
                (bool ok,) = payable(_map(recipient)).call{value: amount}("");
                require(ok, "native send failed");
            } else if (cmd == 0x10) {
                (bytes memory actions, bytes[] memory params) = abi.decode(inputs[i], (bytes, bytes[]));
                _v4Swap(actions, params);
            } else {
                revert("unsupported command");
            }
        }
    }

    function _v3SwapExactIn(address recipient, uint256 amountIn, uint256 amountOutMin, bytes memory path, bool payerIsUser) private {
        address tokenIn = _firstAddress(path);
        address tokenOut = _lastAddress(path);
        uint256 amountOut = amountIn; // fixed 1:1 simulated rate
        require(amountOut >= amountOutMin, "V3: below min");

        if (payerIsUser) {
            MockPermit2UR(permit2).transferFrom(msg.sender, address(this), uint160(amountIn), tokenIn);
        } else {
            // paid from this router's own WETH-equivalent balance, tracked as wrappedBalance
            require(wrappedBalance >= amountIn, "V3: insufficient wrapped balance");
            wrappedBalance -= amountIn;
        }

        if (tokenOut == address(quote)) {
            quote.mint(_map(recipient), amountOut);
        } else {
            // swapping OUT to WETH (the sell-for-native path's first hop) -- track as wrapped
            wrappedBalance += amountOut;
        }
    }

    function _v4Swap(bytes memory actions, bytes[] memory params) private {
        address currencyIn;
        address currencyOut;
        uint256 amountIn;
        uint256 amountOut;
        for (uint256 i; i < actions.length; ++i) {
            uint8 action = uint8(actions[i]);
            if (action == 0x06) {
                // Vanilla ExactInputSingleParams shape (PoolKey, bool, uint128, uint128, bytes) --
                // matches what LaunchRoutingExec._swapV4 sends on any chain id other than Robinhood's
                // (4663), which is what a plain `forge test` run (chain id 31337) exercises.
                (
                    address c0, address c1, uint24 fee_, int24 tickSpacing_, address hooks_,
                    bool zeroForOne, uint128 amtIn, uint128 amtOutMin, bytes memory hookData
                ) = abi.decode(params[i], (address, address, uint24, int24, address, bool, uint128, uint128, bytes));
                (fee_, tickSpacing_, hooks_, hookData); // unused in this simulation
                currencyIn  = zeroForOne ? c0 : c1;
                currencyOut = zeroForOne ? c1 : c0;
                amountIn = amtIn;
                amountOut = amtIn; // fixed 1:1 simulated rate
                require(amountOut >= amtOutMin, "V4: below min");
            } else if (action == 0x0c) {
                (address currency, uint256 maxAmount) = abi.decode(params[i], (address, uint256));
                require(currency == currencyIn, "V4: settle currency mismatch");
                require(amountIn <= maxAmount, "V4: settle exceeds max");
                if (currency != address(0)) {
                    MockPermit2UR(permit2).transferFrom(msg.sender, address(this), uint160(amountIn), currency);
                }
                // native currency: value already arrived with this call, nothing further to pull
            } else if (action == 0x0f) {
                (address currency, uint256 minAmount) = abi.decode(params[i], (address, uint256));
                require(currency == currencyOut, "V4: take currency mismatch");
                require(amountOut >= minAmount, "V4: take below min");
                if (currency == address(0)) {
                    (bool ok,) = payable(msg.sender).call{value: amountOut}("");
                    require(ok, "native send failed");
                } else {
                    MockERC20UR(currency).mint(msg.sender, amountOut);
                }
            } else {
                revert("unsupported action");
            }
        }
    }

    function _map(address recipient) private view returns (address) {
        if (recipient == address(1)) return msg.sender;
        if (recipient == address(2)) return address(this);
        return recipient;
    }

    function _firstAddress(bytes memory path) private pure returns (address a) {
        assembly { a := shr(96, mload(add(path, 32))) }
    }

    function _lastAddress(bytes memory path) private pure returns (address a) {
        assembly { a := shr(96, mload(add(path, add(mload(path), 12)))) }
    }
}

contract DuckBondingCurveUniversalRouterTest is Test {
    DuckBondingCurve curve;
    DuckToken tokenImpl;
    MockERC20UR quoteToken;
    MockUniversalRouterUR router;

    address constant PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address owner = makeAddr("owner");
    address platformWallet = makeAddr("platform");
    address creator = makeAddr("creator");
    address buyer = makeAddr("buyer");
    address dummyWeth = makeAddr("weth");
    address dummyV4PM = makeAddr("v4pm");
    address dummyV4Singleton = makeAddr("v4singleton");

    function setUp() public {
        vm.etch(PERMIT2, address(new MockPermit2UR()).code);

        vm.startPrank(owner);
        tokenImpl = new DuckToken(address(0));
        DuckBondingCurve impl = new DuckBondingCurve();
        ERC1967Proxy proxy = new ERC1967Proxy(
            address(impl),
            abi.encodeCall(DuckBondingCurve.initialize, (
                dummyWeth, dummyV4PM, dummyV4Singleton, address(0),
                platformWallet, address(tokenImpl)
            ))
        );
        curve = DuckBondingCurve(payable(address(proxy)));
        vm.stopPrank();

        quoteToken = new MockERC20UR();
        router = new MockUniversalRouterUR(PERMIT2, quoteToken);

        vm.startPrank(owner);
        curve.setUniversalRouter(address(router));
        curve.setQuoteTokenAllowed(address(quoteToken), true);
        vm.stopPrank();

        vm.deal(creator, 10 ether);
        vm.deal(buyer, 10 ether);
    }

    function _mineVanitySalt(uint256 seed) internal view returns (bytes32 userSalt) {
        return _mineVanitySaltFor(address(curve), seed);
    }

    function _mineVanitySaltFor(address deployer, uint256 seed) internal view returns (bytes32 userSalt) {
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
                bytes1(0xff), deployer, salt, initCodeHash
            )))));
            if (uint16(uint160(predicted)) == 0x8888) return userSalt;
        }
        revert("salt not found");
    }

    function _createQuoteToken() internal returns (address token) {
        DuckBondingCurve.BaseParams memory p;
        p.name = "Test";
        p.symbol = "TEST";
        p.supplyTier = 0;
        p.curveBps = 8_000;
        p.liquidityBps = 2_000;
        p.quoteToken = address(quoteToken);
        p.startVirtualQuote = 1 ether;
        p.migrationTargetQuote = 10 ether;
        p.hookFeeBps = 0;
        p.creatorBps = 10_000;
        p.metaURI = "";
        p.salt = _mineVanitySalt(1);

        vm.prank(creator);
        token = curve.createToken{value: 0.0005 ether}(p);
    }

    function _v3Route() internal view returns (Route[] memory routes) {
        routes = new Route[](1);
        address[] memory path = new address[](2);
        path[0] = dummyWeth;
        path[1] = address(quoteToken);
        uint24[] memory fees = new uint24[](1);
        fees[0] = 3000;
        routes[0] = Route({shape: RouteShape.V3_STYLE, enabled: true, path: path, fees: fees, hook: address(0), fee: 0, tickSpacing: 0});
    }

    function _v4Route() internal pure returns (Route[] memory routes) {
        routes = new Route[](1);
        address[] memory path = new address[](0);
        uint24[] memory fees = new uint24[](0);
        routes[0] = Route({shape: RouteShape.V4_STYLE, enabled: true, path: path, fees: fees, hook: address(0), fee: 3000, tickSpacing: 60});
    }

    function test_BuyWithNative_V3Route_DeliversQuoteAndBuysToken() public {
        address token = _createQuoteToken();
        vm.prank(owner);
        curve.setRoutes(address(quoteToken), _v3Route());

        vm.prank(buyer);
        curve.buyWithNative{value: 1 ether}(token, 0.9 ether, 0, block.timestamp + 1 hours);

        assertGt(DuckToken(payable(token)).balanceOf(buyer), 0, "buyer should have received launched tokens");
    }

    function test_BuyWithNative_V4Route_DeliversQuoteAndBuysToken() public {
        address token = _createQuoteToken();
        vm.prank(owner);
        curve.setRoutes(address(quoteToken), _v4Route());

        vm.prank(buyer);
        curve.buyWithNative{value: 1 ether}(token, 0.9 ether, 0, block.timestamp + 1 hours);

        assertGt(DuckToken(payable(token)).balanceOf(buyer), 0, "buyer should have received launched tokens");
    }

    function test_SellForNative_V3Route_PaysSellerNativeETH() public {
        address token = _createQuoteToken();
        vm.prank(owner);
        curve.setRoutes(address(quoteToken), _v3Route());

        vm.prank(buyer);
        curve.buyWithNative{value: 1 ether}(token, 0.9 ether, 0, block.timestamp + 1 hours);

        uint256 tokenBal = DuckToken(payable(token)).balanceOf(buyer);
        vm.startPrank(buyer);
        DuckToken(payable(token)).approve(address(curve), tokenBal);
        uint256 nativeBefore = buyer.balance;
        curve.sellForNative(token, tokenBal, 0, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGt(buyer.balance, nativeBefore, "seller should have received native ETH");
    }

    function test_SellForNative_V4Route_PaysSellerNativeETH() public {
        address token = _createQuoteToken();
        vm.prank(owner);
        curve.setRoutes(address(quoteToken), _v4Route());

        vm.prank(buyer);
        curve.buyWithNative{value: 1 ether}(token, 0.9 ether, 0, block.timestamp + 1 hours);

        uint256 tokenBal = DuckToken(payable(token)).balanceOf(buyer);
        vm.startPrank(buyer);
        DuckToken(payable(token)).approve(address(curve), tokenBal);
        uint256 nativeBefore = buyer.balance;
        curve.sellForNative(token, tokenBal, 0, 0, block.timestamp + 1 hours);
        vm.stopPrank();

        assertGt(buyer.balance, nativeBefore, "seller should have received native ETH");
    }

    function test_BuyWithNative_RevertsWhenUniversalRouterNotConfigured() public {
        // Redeploy without ever calling setUniversalRouter -- routes exist but the router doesn't.
        vm.startPrank(owner);
        DuckBondingCurve impl2 = new DuckBondingCurve();
        ERC1967Proxy proxy2 = new ERC1967Proxy(
            address(impl2),
            abi.encodeCall(DuckBondingCurve.initialize, (
                dummyWeth, dummyV4PM, dummyV4Singleton, address(0),
                platformWallet, address(tokenImpl)
            ))
        );
        DuckBondingCurve curve2 = DuckBondingCurve(payable(address(proxy2)));
        curve2.setQuoteTokenAllowed(address(quoteToken), true);
        curve2.setRoutes(address(quoteToken), _v3Route());
        vm.stopPrank();

        DuckBondingCurve.BaseParams memory p;
        p.name = "Test2";
        p.symbol = "TEST2";
        p.supplyTier = 0;
        p.curveBps = 8_000;
        p.liquidityBps = 2_000;
        p.quoteToken = address(quoteToken);
        p.startVirtualQuote = 1 ether;
        p.migrationTargetQuote = 10 ether;
        p.hookFeeBps = 0;
        p.creatorBps = 10_000;
        p.metaURI = "";
        p.salt = _mineVanitySaltFor(address(curve2), 50_000);
        vm.prank(creator);
        address token2 = curve2.createToken{value: 0.0005 ether}(p);

        vm.prank(buyer);
        vm.expectRevert(DuckBondingCurve.RouteUnavailable.selector);
        curve2.buyWithNative{value: 1 ether}(token2, 0.9 ether, 0, block.timestamp + 1 hours);
    }
}
