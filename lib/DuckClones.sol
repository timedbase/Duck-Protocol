// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckClones

library DuckClones {
    error CloneFailed();
    error VanityAddressRequired();

    function clone(address implementation, address creator, bytes32 userSalt)
        external returns (address instance)
    {
        instance = _create2Clone(implementation, keccak256(abi.encode(creator, userSalt)));
    }

    function cloneVanity(address implementation, address creator, bytes32 userSalt, uint16 suffix)
        external returns (address instance)
    {
        instance = _create2Clone(implementation, keccak256(abi.encode(creator, userSalt)));
        if (uint16(uint160(instance)) != suffix) revert VanityAddressRequired();
    }

    function predict(address implementation, address creator, bytes32 userSalt, address deployerContract)
        external pure returns (address predicted)
    {
        bytes32 salt = keccak256(abi.encode(creator, userSalt));
        bytes32 initcodeHash;
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,            0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            initcodeHash := keccak256(ptr, 0x37)
        }
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), deployerContract, salt, initcodeHash
        )))));
    }

    function _create2Clone(address implementation, bytes32 salt) private returns (address instance) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr,            0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0)) revert CloneFailed();
    }
}
