// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckMetaOverride

import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

contract DuckMetaOverride is Ownable2Step {
    error ZeroAddress();
    error NotRegistered();

    mapping(address => bool)   public isRegistered;
    mapping(address => string) public metaURI;

    event TokenRegistered(address indexed token, string metaURI);
    event MetaURIUpdated(address indexed token, string metaURI);
    event TokenUnregistered(address indexed token);

    constructor(address owner_) Ownable(owner_) {}

    function registerToken(address token, string calldata metaURI_) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        isRegistered[token] = true;
        metaURI[token] = metaURI_;
        emit TokenRegistered(token, metaURI_);
    }

    function updateMetaURI(address token, string calldata metaURI_) external onlyOwner {
        if (!isRegistered[token]) revert NotRegistered();
        metaURI[token] = metaURI_;
        emit MetaURIUpdated(token, metaURI_);
    }

    function unregisterToken(address token) external onlyOwner {
        if (!isRegistered[token]) revert NotRegistered();
        isRegistered[token] = false;
        delete metaURI[token];
        emit TokenUnregistered(token);
    }

    function getMetaURI(address token) external view returns (bool overridden, string memory uri) {
        return (isRegistered[token], metaURI[token]);
    }
}
