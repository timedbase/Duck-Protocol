// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckVaultFactory

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DuckVault} from "./DuckVault.sol";

interface ITokenVaultPointer {
    function vault() external view returns (address);
    function setVault(address vault_) external;
}

contract DuckVaultFactory is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    error ZeroAddress();
    error UnknownFamily();
    error MarketAlreadyOpen();

    address public vaultImpl;
    address public config;
    address public hook;

    address public governorFactory;
    mapping(address => bool) public isFamily;
    mapping(address => address) public vaultOf;

    mapping(address => bool) public approvedVaultImpl;

    event VaultImplSet(address indexed impl);
    event VaultImplApproved(address indexed impl);
    event VaultImplRevoked(address indexed impl);
    event ConfigSet(address indexed config);
    event HookSet(address indexed hook);
    event GovernorFactorySet(address indexed governorFactory);
    event FamilySet(address indexed family, bool allowed);
    event VaultCreated(address indexed token, address indexed vault, address indexed family, address creator);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address vaultImpl_, address config_, address hook_) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        if (vaultImpl_ == address(0) || config_ == address(0) || hook_ == address(0)) revert ZeroAddress();
        vaultImpl = vaultImpl_;
        config = config_;
        hook = hook_;
        approvedVaultImpl[vaultImpl_] = true;
        emit VaultImplApproved(vaultImpl_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setVaultImpl(address impl_) external onlyOwner {
        if (impl_ == address(0)) revert ZeroAddress();
        vaultImpl = impl_;
        approvedVaultImpl[impl_] = true;
        emit VaultImplSet(impl_);
        emit VaultImplApproved(impl_);
    }

    function approveVaultImpl(address impl_) external onlyOwner {
        if (impl_ == address(0)) revert ZeroAddress();
        approvedVaultImpl[impl_] = true;
        emit VaultImplApproved(impl_);
    }

    function revokeVaultImpl(address impl_) external onlyOwner {
        approvedVaultImpl[impl_] = false;
        emit VaultImplRevoked(impl_);
    }

    function setConfig(address config_) external onlyOwner {
        if (config_ == address(0)) revert ZeroAddress();
        config = config_;
        emit ConfigSet(config_);
    }

    function setHook(address hook_) external onlyOwner {
        if (hook_ == address(0)) revert ZeroAddress();
        hook = hook_;
        emit HookSet(hook_);
    }

    function setGovernorFactory(address governorFactory_) external onlyOwner {
        governorFactory = governorFactory_;
        emit GovernorFactorySet(governorFactory_);
    }

    function setFamily(address family_, bool allowed_) external onlyOwner {
        if (family_ == address(0)) revert ZeroAddress();
        isFamily[family_] = allowed_;
        emit FamilySet(family_, allowed_);
    }

    function createVault(address token, uint8 tokenDecimals, address creator_) external returns (address vault) {
        if (!isFamily[msg.sender]) revert UnknownFamily();
        if (vaultOf[token] != address(0) || ITokenVaultPointer(token).vault() != address(0)) revert MarketAlreadyOpen();

        vault = address(new ERC1967Proxy(
            vaultImpl,
            abi.encodeCall(DuckVault.initialize, (token, tokenDecimals, creator_, config, hook, msg.sender))
        ));

        vaultOf[token] = vault;
        ITokenVaultPointer(token).setVault(vault);

        emit VaultCreated(token, vault, msg.sender, creator_);
    }

    function getVault(address token) external view returns (address) {
        return vaultOf[token];
    }
}
