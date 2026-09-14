// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckTokenGovernorFactory

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {DuckClones} from "duck-lib/DuckClones.sol";
import {DuckTokenGovernor} from "./DuckTokenGovernor.sol";
import {TimelockControllerUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

interface IDuckVaultGovFactory {
    function creator() external view returns (address);
    function governor() external view returns (address);
    function setGovernor(address governor_) external;
}

contract DuckTokenGovernorFactory is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    error ZeroAddress();
    error NotCreator();
    error GovernorAlreadyExists();

    uint256 public constant TIMELOCK_DELAY = 5 days;

    address public governorImpl;
    address public timelockImpl;

    uint48  public defaultVotingDelay;
    uint32  public defaultVotingPeriod;

    mapping(address => address) public governorOf;
    mapping(address => address) public timelockOf;

    event GovernorImplSet(address indexed impl);
    event TimelockImplSet(address indexed impl);
    event DefaultVotingParamsSet(uint48 votingDelay, uint32 votingPeriod);
    event GovernorCreated(address indexed vault, address indexed governor, address indexed creator);
    event TimelockCreated(address indexed vault, address indexed timelock);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address owner_, address governorImpl_, address timelockImpl_, uint48 votingDelay_, uint32 votingPeriod_
    ) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();
        if (governorImpl_ == address(0) || timelockImpl_ == address(0)) revert ZeroAddress();
        governorImpl = governorImpl_;
        timelockImpl = timelockImpl_;
        defaultVotingDelay = votingDelay_;
        defaultVotingPeriod = votingPeriod_;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setGovernorImpl(address impl_) external onlyOwner {
        if (impl_ == address(0)) revert ZeroAddress();
        governorImpl = impl_;
        emit GovernorImplSet(impl_);
    }

    function setTimelockImpl(address impl_) external onlyOwner {
        if (impl_ == address(0)) revert ZeroAddress();
        timelockImpl = impl_;
        emit TimelockImplSet(impl_);
    }

    function setDefaultVotingParams(uint48 votingDelay_, uint32 votingPeriod_) external onlyOwner {
        defaultVotingDelay = votingDelay_;
        defaultVotingPeriod = votingPeriod_;
        emit DefaultVotingParamsSet(votingDelay_, votingPeriod_);
    }

    function createGovernor(address vault, address token) external returns (address governor) {
        if (msg.sender != IDuckVaultGovFactory(vault).creator()) revert NotCreator();
        if (IDuckVaultGovFactory(vault).governor() != address(0) || governorOf[vault] != address(0)) {
            revert GovernorAlreadyExists();
        }

        governor = DuckClones.clone(governorImpl, address(this), keccak256(abi.encode(vault)));
        address timelockAddr = DuckClones.clone(timelockImpl, address(this), keccak256(abi.encode(vault, "timelock")));

        address[] memory proposers = new address[](1);
        proposers[0] = governor;
        address[] memory executors = new address[](1);

        executors[0] = address(0);
        TimelockControllerUpgradeable(payable(timelockAddr)).initialize(TIMELOCK_DELAY, proposers, executors, address(0));

        DuckTokenGovernor(payable(governor)).initialize(
            vault, IVotes(token), defaultVotingDelay, defaultVotingPeriod, TimelockControllerUpgradeable(payable(timelockAddr))
        );

        governorOf[vault] = governor;
        timelockOf[vault] = timelockAddr;
        IDuckVaultGovFactory(vault).setGovernor(timelockAddr);

        emit GovernorCreated(vault, governor, msg.sender);
        emit TimelockCreated(vault, timelockAddr);
    }
}
