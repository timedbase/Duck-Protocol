// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Vm} from "forge-std/Vm.sol";

// Stand-in for Arc's USDC ERC-20 at 0x3600... in forge tests. On Arc that contract moves native balances
// through the chain's own execution logic, which forge's EVM doesn't have. This mock follows the same rule
// with cheatcodes: an account's ERC-20 balance is its native balance / 1e12, and a transfer moves native.
// Etch it at ARC_USDC and allow it cheatcodes.
contract MockArcUsdc {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));
    uint256 private constant NATIVE_PER_USDC = 1e12;

    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function name() external pure returns (string memory) { return "USDC"; }
    function symbol() external pure returns (string memory) { return "USDC"; }
    function decimals() external pure returns (uint8) { return 6; }

    function balanceOf(address account) public view returns (uint256) {
        return account.balance / NATIVE_PER_USDC;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint256 value) external returns (bool) {
        _move(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= value, "USDC: allowance");
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - value;
        _move(from, to, value);
        return true;
    }

    function _move(address from, address to, uint256 value) private {
        uint256 native = value * NATIVE_PER_USDC;
        require(from.balance >= native, "USDC: balance");
        vm.deal(from, from.balance - native);
        vm.deal(to, to.balance + native);
        emit Transfer(from, to, value);
    }
}
