// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckTokenGovernor

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {GovernorUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/GovernorUpgradeable.sol";
import {GovernorVotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorVotesUpgradeable.sol";
import {GovernorCountingSimpleUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorCountingSimpleUpgradeable.sol";
import {GovernorSettingsUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorSettingsUpgradeable.sol";
import {GovernorTimelockControlUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/extensions/GovernorTimelockControlUpgradeable.sol";
import {TimelockControllerUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

interface IDuckVaultGov {
    function creator() external view returns (address);
}

interface IVotesSupply {
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256);
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256);
    function getPastHolderCount(uint256 timepoint) external view returns (uint256);
}

contract DuckTokenGovernor is
    Initializable,
    GovernorUpgradeable,
    GovernorVotesUpgradeable,
    GovernorCountingSimpleUpgradeable,
    GovernorSettingsUpgradeable,
    GovernorTimelockControlUpgradeable
{
    error NotCreator();
    error BelowMinVotingThreshold();

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    uint256 private constant QUORUM_BPS = 4000;

    uint256 private constant PARTICIPATION_BPS = 4000;
    uint256 private constant BPS_DENOM  = 10_000;

    // Protocol-wide, not creator-configurable: a wallet must hold more than 0.2% of supply to vote
    // at all. This gates PARTICIPATION, not just vote weight. Checked against _proposalCreatedAt
    // below (anti-sniping), not the later vote snapshot.
    uint256 private constant MIN_VOTE_BPS = 20;

    address public vault;

    // Per-proposal headcounts: _totalVoterCount counts every wallet that voted (For/Against/
    // Abstain), _forCount only For. _quorumReached requires For to clear 40% of who actually showed
    // up, rather than 40% of all eligible holders -- which would be unreachable for tokens with many
    // inactive holders. So For=38%/Against=37%/Abstain=25% is Defeated despite being the largest bucket.
    mapping(uint256 => uint256) private _forCount;
    mapping(uint256 => uint256) private _totalVoterCount;

    // Anti-sniping: the timepoint (block.number - 1 at propose() time) voter ELIGIBILITY is checked
    // against. proposalSnapshot is a future block and only stops same-transaction/flash-loan
    // manipulation, not a wallet that genuinely buys in over following blocks to swing a proposal it
    // just saw. Anchoring to the last block that couldn't have been influenced by the proposal closes
    // that window: only wallets already over the floor beforehand can vote. Vote WEIGHT still comes
    // from the standard later proposalSnapshot -- the two are deliberately measured at different points.
    mapping(uint256 => uint256) private _proposalCreatedAt;

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address vault_, IVotes token_, uint48 votingDelay_, uint32 votingPeriod_, TimelockControllerUpgradeable timelock_
    ) external initializer {
        __Governor_init("DuckTokenGovernor");
        __GovernorVotes_init(token_);
        __GovernorCountingSimple_init();

        __GovernorSettings_init(votingDelay_, votingPeriod_, 0);
        __GovernorTimelockControl_init(timelock_);
        vault = vault_;
    }

    function propose(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) public override(GovernorUpgradeable) returns (uint256) {
        if (msg.sender != IDuckVaultGov(vault).creator()) revert NotCreator();
        uint256 proposalId = super.propose(targets, values, calldatas, description);
        _proposalCreatedAt[proposalId] = clock() - 1;
        return proposalId;
    }

    function quorum(uint256 timepoint) public view override returns (uint256) {
        IVotesSupply t = IVotesSupply(address(token()));
        uint256 circulating = t.getPastTotalSupply(timepoint) - t.getPastVotes(DEAD, timepoint);
        return (circulating * QUORUM_BPS) / BPS_DENOM;
    }

    function _quorumReached(uint256 proposalId) internal view override(GovernorUpgradeable, GovernorCountingSimpleUpgradeable) returns (bool) {
        uint256 snapshot = proposalSnapshot(proposalId);
        (, uint256 forVotes, ) = proposalVotes(proposalId);
        // For must win the supply-weighted voting power outright: at least 40% of circulating supply.
        if (forVotes < quorum(snapshot)) return false;

        // For must ALSO be more than 40% of the headcount of wallets that actually voted (any of
        // For/Against/Abstain) -- winning on weight alone isn't enough if For was only the largest
        // of three closely-split buckets rather than a genuine plurality of actual participants.
        uint256 totalVoters = _totalVoterCount[proposalId];
        if (totalVoters == 0) return false;
        return _forCount[proposalId] * BPS_DENOM >= totalVoters * PARTICIPATION_BPS;
    }

    function _countVote(
        uint256 proposalId,
        address account,
        uint8 support,
        uint256 totalWeight,
        bytes memory params
    ) internal override(GovernorUpgradeable, GovernorCountingSimpleUpgradeable) returns (uint256) {
        // Anti-sniping eligibility check -- see _proposalCreatedAt above. Independent of totalWeight
        // (which OZ computes from the later proposalSnapshot): a wallet must have held over 0.2% of
        // supply BEFORE this proposal existed, whatever its snapshot-time weight turns out to be.
        uint256 eligibilityTimepoint = _proposalCreatedAt[proposalId];
        uint256 supplyAtEligibility = IVotesSupply(address(token())).getPastTotalSupply(eligibilityTimepoint);
        uint256 weightAtEligibility = IVotesSupply(address(token())).getPastVotes(account, eligibilityTimepoint);
        if (weightAtEligibility * BPS_DENOM <= supplyAtEligibility * MIN_VOTE_BPS) revert BelowMinVotingThreshold();

        uint256 weight = super._countVote(proposalId, account, support, totalWeight, params);
        if (totalWeight > 0) {
            _totalVoterCount[proposalId] += 1;
            if (support == uint8(VoteType.For)) _forCount[proposalId] += 1;
        }
        return weight;
    }

    function votingDelay() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(GovernorUpgradeable, GovernorSettingsUpgradeable) returns (uint256) {
        return super.proposalThreshold();
    }

    function state(uint256 proposalId) public view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId) public view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (bool) {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(GovernorUpgradeable, GovernorTimelockControlUpgradeable) returns (address) {
        return super._executor();
    }
}
