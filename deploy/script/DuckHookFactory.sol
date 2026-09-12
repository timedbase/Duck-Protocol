// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {DuckHookV4} from "duck-shared/DuckHookV4.sol";

contract DuckHookFactory {
    error DeployFailed();
    error Unauthorized();

    // salt derives purely from public inputs, so without this anyone could front-run a pending
    // deploy() with the same salt and themselves as newOwner_, claiming the predictable hook address
    // with a real, correctly-wired DuckHookV4 they own.
    address private immutable _deployer;

    constructor() {
        _deployer = msg.sender;
    }

    function deploy(
        bytes32 salt,
        address poolManager_,
        address newOwner_
    ) external returns (address hook) {
        if (msg.sender != _deployer) revert Unauthorized();
        // Raw create2 with precomputed creation code, not a typed `new DuckHookV4{salt}(...)`:
        // DuckHookV4 is large enough that a typed new-expression hits stack-too-deep even under
        // via-IR. Raw create2 skips that constructor-arg/immutable codegen entirely.
        bytes memory initCode = abi.encodePacked(type(DuckHookV4).creationCode, abi.encode(poolManager_));
        assembly {
            hook := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (hook == address(0)) revert DeployFailed();
        DuckHookV4(payable(hook)).transferOwnership(newOwner_);
    }
}
