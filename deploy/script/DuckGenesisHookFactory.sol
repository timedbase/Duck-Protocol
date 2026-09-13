// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {DuckGenesisHook} from "duck-shared/DuckGenesisHook.sol";

contract DuckGenesisHookFactory {
    error DeployFailed();
    error Unauthorized();

    // salt derives purely from public inputs, so without this anyone could front-run a pending
    // deploy() with the same salt and themselves as newOwner_, claiming the predictable hook address
    // with a real, correctly-wired DuckGenesisHook they own.
    address private immutable _deployer;

    constructor() {
        _deployer = msg.sender;
    }

    // The hook's constructor reverts unless its address carries exactly REQUIRED_PERMISSIONS (0x2ACC)
    // in the low 14 bits, so the salt has to be mined first: iterate salts through predict() until
    // `uint160(addr) & 0x3FFF == 0x2ACC`.
    function deploy(
        bytes32 salt,
        address poolManager_,
        address newOwner_
    ) external returns (address hook) {
        if (msg.sender != _deployer) revert Unauthorized();
        // Raw create2 with precomputed creation code, not a typed `new DuckGenesisHook{salt}(...)`:
        // the hook is large enough that a typed new-expression can hit stack-too-deep under via-IR.
        bytes memory initCode = _initCode(poolManager_);
        assembly {
            hook := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (hook == address(0)) revert DeployFailed();
        DuckGenesisHook(payable(hook)).transferOwnership(newOwner_);
    }

    function predict(bytes32 salt, address poolManager_) external view returns (address) {
        bytes32 h = keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(_initCode(poolManager_))));
        return address(uint160(uint256(h)));
    }

    function initCodeHash(address poolManager_) external pure returns (bytes32) {
        return keccak256(_initCode(poolManager_));
    }

    function _initCode(address poolManager_) private pure returns (bytes memory) {
        return abi.encodePacked(type(DuckGenesisHook).creationCode, abi.encode(poolManager_));
    }
}
