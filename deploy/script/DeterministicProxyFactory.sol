// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

// OZ's ERC1967Proxy (v5.6+) reverts on empty init data unless a subclass opts in via
// _unsafeAllowUninitialized. It guards against exactly the front-running risk this file's atomic
// deploy()/deployAndTransferOwnership() already close -- the proxy is never observable uninitialized,
// since initialize() runs in the same transaction, right after CREATE2. This is that opt-in.
contract UninitializedERC1967Proxy is ERC1967Proxy {
    constructor(address implementation) ERC1967Proxy(implementation, "") {}

    function _unsafeAllowUninitialized() internal pure override returns (bool) {
        return true;
    }
}

// Deploys an ERC1967Proxy via CREATE2 with EMPTY init data, so the address depends only on (factory,
// salt, implementation) and never on the chain-specific arguments initialize() carries. That's what
// lets one salt produce the same proxy address across chains with different infrastructure, as long
// as `implementation` is itself deployed deterministically (see DeployDuckProtocol.s.sol).
//
// Both entry points bundle the CREATE2 deploy and initialize() into one atomic call so there's no
// window for someone to front-run with their own initialize() and take ownership -- Initializable's
// `initializer` modifier only blocks a SECOND call, not a first one by the wrong caller.
contract DeterministicProxyFactory {
    error DeployFailed();
    error InitFailed();
    error TransferOwnershipFailed();
    error Unauthorized();

    // Salts are public constants and implementations become public once deployed, so without this
    // guard anyone could front-run a pending deploy with the same salt and their own implementation,
    // claiming the address the real deployment was headed for. (CREATE2 to an occupied address
    // returns address(0), so the legitimate call reverts rather than wiring in the attacker's
    // version -- still a griefing vector worth closing.) Passed explicitly rather than read from
    // msg.sender at construction, since new{salt:...}() routes through the canonical CREATE2 proxy,
    // making msg.sender that proxy rather than the deployer EOA.
    address private immutable _deployer;

    constructor(address deployer_) {
        _deployer = deployer_;
    }

    modifier onlyDeployer() {
        if (msg.sender != _deployer) revert Unauthorized();
        _;
    }

    // For an initialize() that already takes an explicit owner parameter (DuckVaultConfig,
    // DuckVaultFactory, DuckTokenGovernorFactory all do) -- ownership lands correctly on whoever
    // initData names, regardless of who calls this function, so nothing further is needed.
    function deploy(bytes32 salt, address implementation, bytes calldata initData)
        external onlyDeployer returns (address proxy)
    {
        proxy = _deploy(salt, implementation, initData);
    }

    // For an initialize() that reads msg.sender for ownership (the launch contracts all do
    // `__Ownable_init(msg.sender)`), msg.sender is THIS factory -- CREATE2 doesn't propagate the
    // caller further up the chain -- so without this step the factory would own the proxy. Handing
    // ownership over right after, still in the same transaction, fixes that. Ownable2Step-style:
    // owner_ still calls acceptOwnership() to complete the handoff.
    function deployAndTransferOwnership(bytes32 salt, address implementation, bytes calldata initData, address owner_)
        external onlyDeployer returns (address proxy)
    {
        proxy = _deploy(salt, implementation, initData);
        (bool ok, ) = proxy.call(abi.encodeWithSignature("transferOwnership(address)", owner_));
        if (!ok) revert TransferOwnershipFailed();
    }

    function _deploy(bytes32 salt, address implementation, bytes calldata initData)
        private returns (address proxy)
    {
        bytes memory initCode = abi.encodePacked(
            type(UninitializedERC1967Proxy).creationCode, abi.encode(implementation)
        );
        assembly {
            proxy := create2(0, add(initCode, 0x20), mload(initCode), salt)
        }
        if (proxy == address(0)) revert DeployFailed();
        (bool ok, ) = proxy.call(initData);
        if (!ok) revert InitFailed();
    }

    function predict(bytes32 salt, address implementation) external view returns (address predicted) {
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(UninitializedERC1967Proxy).creationCode, abi.encode(implementation)
        ));
        predicted = address(uint160(uint256(keccak256(abi.encodePacked(
            bytes1(0xff), address(this), salt, initCodeHash
        )))));
    }
}
