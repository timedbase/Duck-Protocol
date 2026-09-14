// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckOpenToken (Arc)
//
// Shared implementation for every launch family's token: DuckCurveToken (bonding curve),
// DuckLauncherToken (instant pool) and DuckCrowdfundToken (crowdfund), all freely transferable from the
// moment they exist. Identical to DuckToken -- holder rewards, voting checkpoints, permit, vault link --
// minus the launch-phase transfer lock, which token scanners flag. That lock kept bonding-curve tokens
// out of any pool before migration; DuckGenesisHook now makes it unnecessary, since it won't initialize
// a pool its launchers haven't registered or take liquidity from anyone but them.
//
// initToken keeps DuckToken's signature so the launch contracts call it unchanged. They pass `false` for
// the lock; `true` is refused rather than silently ignored.
//
// Arc build: holder rewards are always the pool's quote ERC-20 (USDC by default); there is no native path.

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {VotesUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/utils/VotesUpgradeable.sol";
import {Checkpoints} from "@openzeppelin/contracts/utils/structs/Checkpoints.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {requireArcChain} from "./ArcChain.sol";

abstract contract DuckOpenToken is Initializable, VotesUpgradeable {
    using Checkpoints for Checkpoints.Trace208;

    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error InsufficientBalance();
    error ExceedsAllowance();
    error TokenRescueFailed();
    error PermitExpired();
    error InvalidSignature();
    error TransferLockUnsupported();
    error NotVaultFactory();
    error VaultAlreadySet();
    error DelegationDisabled();
    error FutureLookup(uint256 timepoint, uint256 clockNow);
    error RewardConfigAlreadySet();
    error NotRewardHook();
    error Reentrant();

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address private _owner;

    address public  mintManager;

    address public immutable vaultFactory;

    address public vault;

    string  private _name;
    string  private _symbol;
    string  private _metaURI;
    uint256 private _totalSupply;

    mapping(address => uint256)                     private _balances;
    mapping(address => mapping(address => uint256)) private _allowances;

    Checkpoints.Trace208 private _holderCountCheckpoints;

    // ---- holder reward: 5% of hook fees (see the hook's claimFees), pro-rata and time-weighted over
    // 12h rounds, pushed out in batches. Config is set once at real-pool-creation time (see
    // setRewardConfig); a crowdfund token has no pool until the raise succeeds, so everything here
    // treats rewardHook == address(0) as "not wired up yet, do nothing". ----
    address public rewardCurrency;     // pool's quote ERC-20
    address public rewardHook;         // only address allowed to deposit into the round pool
    address public poolManagerAddr;    // chain's V4 singleton -- the real "liquidity" exclusion,
                                        // since every pool's reserves live there

    // Protocol-wide and not creator-configurable: 0.25% of total supply to be reward-eligible. Based on
    // total supply, which initToken sets once and nothing ever changes, so the floor is fixed for the
    // token's lifetime. DEAD and PoolManager are separately excluded (see _isExcludedFromRewards).
    uint256 public constant MIN_HOLDING_BPS = 25;

    // Enumerable holder set -- separate from _holderCountCheckpoints above, which backs governance's
    // getPastHolderCount.
    address[] private _holders;
    mapping(address => uint256) private _holderIndex; // 1-based; 0 means "not in the list"

    // Time-weighted holding: round-indexed so a round being paid out in batches never gets
    // contaminated by the next round's accrual for holders not yet processed (each round gets its
    // own namespace under _roundId, never reused).
    uint256 private _roundId;
    mapping(uint256 => mapping(address => uint256)) private _balanceSecondsByRound;
    mapping(uint256 => uint256) private _totalBalanceSecondsByRound;
    mapping(address => uint256) private _lastAccrued;

    // O(1) running total of non-excluded balances, kept in lockstep with every transfer. This -- not
    // the sum of per-account entries -- backs _totalBalanceSecondsByRound at close time. Per-account
    // entries settle lazily (see _settleForPayout), so summing them would undercount every holder who
    // never transacted during the round.
    uint256 private _totalEligibleBalance;
    uint256 private _lastTotalAccrued;

    // processBatch is purely externally triggered -- anyone can call it, and DuckKeeper does on a
    // schedule. Kept off the _transfer path so an ordinary wallet-to-wallet transfer never absorbs the
    // gas of advancing someone else's payout round.
    uint256 public constant DISTRIBUTION_INTERVAL = 12 hours;
    uint256 public constant BATCH_SIZE = 500;

    uint256 public roundStart;   // when the CURRENTLY-ACCRUING round began
    uint256 public roundPool;    // reward currency deposited so far into the currently-accruing round

    // Snapshot of the round currently being paid out (frozen the moment it closed) -- double-buffered
    // against the currently-accruing round above so a still-batching payout never blocks new accrual.
    bool    public distributing;
    bool    private _inProcessBatch; // reentrancy guard for processBatch's payout loop -- see there
    uint256 private _payoutRoundId;
    uint256 private _payoutRoundStart;
    uint256 private _payoutRoundEnd;
    uint256 private _payoutPool;
    uint256 private _payoutTotalWeight;
    uint256 private _payoutCursor;

    bytes32 private constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event MetaURISet(string uri);
    event VaultSet(address indexed vault);
    event RewardConfigSet(address indexed hook, address indexed currency, address indexed poolManager);
    event HolderRewardDeposited(uint256 amount);
    event DistributionRoundClosed(uint256 indexed roundStart, uint256 pool, uint256 eligibleCount, uint256 totalWeight);
    event HolderRewardPaid(address indexed account, uint256 amount);
    event DistributionRoundFinished(uint256 indexed roundStart);

    modifier onlyOwner() { if (msg.sender != _owner) revert NotOwner(); _; }

    // Guards processBatch's payout loop, which makes external calls to addresses from a mutable
    // swap-and-pop array before its own bookkeeping is committed. A blocked reentrant attempt just
    // makes the outer .call return false, skipping that one holder rather than reverting the batch.
    modifier nonReentrant() {
        if (_inProcessBatch) revert Reentrant();
        _inProcessBatch = true;
        _;
        _inProcessBatch = false;
    }

    constructor(address vaultFactory_) {
        requireArcChain();
        _disableInitializers();
        vaultFactory = vaultFactory_;
    }

    function setVault(address vault_) external {
        if (msg.sender != vaultFactory) revert NotVaultFactory();
        if (vault != address(0)) revert VaultAlreadySet();
        if (vault_ == address(0)) revert ZeroAddress();
        vault = vault_;
        emit VaultSet(vault_);
    }

    function initToken(
        string calldata name_,
        string calldata symbol_,
        uint256          totalSupply_,
        bool             lockUntilUnlock_,
        string calldata metaURI_
    ) external initializer {
        if (lockUntilUnlock_) revert TransferLockUnsupported();
        __EIP712_init(name_, "1");

        mintManager  = msg.sender;
        _owner       = msg.sender;
        _name        = name_;
        _symbol      = symbol_;
        _totalSupply = totalSupply_;
        _metaURI     = metaURI_;

        _balances[msg.sender] = totalSupply_;
        emit Transfer(address(0), msg.sender, totalSupply_);
        emit OwnershipTransferred(address(0), msg.sender);
        emit MetaURISet(metaURI_);

        if (msg.sender != DEAD && totalSupply_ > 0) _updateHolderCount(1);
        if (totalSupply_ > 0) _addHolder(msg.sender);
        if (totalSupply_ > 0 && !_isExcludedFromRewards(msg.sender)) _totalEligibleBalance = totalSupply_;

        _transferVotingUnits(address(0), msg.sender, totalSupply_);
    }

    function metaURI() external view returns (string memory) { return _metaURI; }

    function setMetaURI(string calldata uri_) external onlyOwner {
        _metaURI = uri_;
        emit MetaURISet(uri_);
    }

    function owner() external view returns (address) { return _owner; }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(_owner, newOwner);
        _owner = newOwner;
    }

    function renounceOwnership() external onlyOwner {
        emit OwnershipTransferred(_owner, address(0));
        _owner = address(0);
    }

    function name()        external view returns (string memory) { return _name;   }
    function symbol()      external view returns (string memory) { return _symbol; }
    function decimals()    external pure returns (uint8)         { return 18;      }
    function totalSupply() external view returns (uint256)       { return _totalSupply; }

    function balanceOf(address account) external view returns (uint256) {
        return _balances[account];
    }

    function allowance(address owner_, address spender) external view returns (uint256) {
        return _allowances[owner_][spender];
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        _approve(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = _allowances[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < amount) revert ExceedsAllowance();
            unchecked { _allowances[from][msg.sender] = allowed - amount; }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 bal = _balances[from];
        if (bal < amount) revert InsufficientBalance();

        // Must run on the OLD balances, before anything below changes them -- same reasoning as any
        // checkpoint-style update (this rolls each account's balance-seconds forward to now using
        // whatever they held up to this instant, then a fresh multiplier applies from here).
        _accrue(from);
        _accrue(to);
        _accrueTotal();

        if (from != to && amount > 0) {
            // Kept unconditional (not gated behind rewardHook) so _totalEligibleBalance is already
            // exactly correct -- no backfill loop needed -- the moment setRewardConfig is eventually
            // called, whatever pre-launch transfers already happened.
            if (!_isExcludedFromRewards(from)) _totalEligibleBalance -= amount;
            if (!_isExcludedFromRewards(to))   _totalEligibleBalance += amount;

            // Same exclusion set as the reward system, not just DEAD: governance's
            // getPastHolderCount feeds DuckTokenGovernor's participation quorum, and counting
            // PoolManager as a "holder" that can never vote would permanently inflate the
            // denominator -- making quorum harder, or unreachable for a small real holder set.
            int256 holderDelta;
            if (!_isExcludedFromRewards(from) && bal - amount == 0) holderDelta -= 1;
            if (!_isExcludedFromRewards(to) && _balances[to] == 0) holderDelta += 1;
            if (holderDelta != 0) _updateHolderCount(holderDelta);
        }

        unchecked {
            _balances[from] = bal - amount;
            _balances[to]   += amount;
        }
        emit Transfer(from, to, amount);
        _transferVotingUnits(from, to, amount);

        if (from != to && amount > 0) {
            if (_balances[from] == 0) _removeHolder(from); else _addHolder(from);
            _addHolder(to); // to's balance is guaranteed > 0 here since amount > 0
        }
    }

    function _updateHolderCount(int256 delta) private {
        uint256 current = _holderCountCheckpoints.latest();
        uint256 updated = delta > 0 ? current + uint256(delta) : current - uint256(-delta);
        _holderCountCheckpoints.push(clock(), SafeCast.toUint208(updated));
    }

    function holderCount() external view returns (uint256) {
        return _holderCountCheckpoints.latest();
    }

    function getPastHolderCount(uint256 timepoint) external view returns (uint256) {
        uint48 currentClock = clock();
        if (timepoint >= currentClock) revert FutureLookup(timepoint, currentClock);
        return _holderCountCheckpoints.upperLookupRecent(SafeCast.toUint48(timepoint));
    }

    // ---- holder reward ----

    // Called once by mintManager (the launch contract) the moment a real pool exists. A crowdfund
    // token has no hook/pool at initToken time, so this can't be set earlier.
    function setRewardConfig(address hook_, address currency_, address poolManager_) external {
        if (msg.sender != mintManager) revert NotOwner();
        if (rewardHook != address(0)) revert RewardConfigAlreadySet();
        if (hook_ == address(0) || currency_ == address(0) || poolManager_ == address(0)) revert ZeroAddress();
        rewardHook = hook_;
        rewardCurrency = currency_;
        poolManagerAddr = poolManager_;
        roundStart = block.timestamp;
        emit RewardConfigSet(hook_, currency_, poolManager_);
    }

    // Excludes DEAD and the pool's own reserves (PoolManager) -- the only two addresses that can never
    // be a genuine holder. Contract addresses are NOT excluded: any address, EOA or contract, that
    // actually holds balance is reward-eligible.
    function _isExcludedFromRewards(address account) private view returns (bool) {
        return account == DEAD || account == poolManagerAddr;
    }

    function _addHolder(address account) private {
        if (_holderIndex[account] != 0 || _isExcludedFromRewards(account)) return;
        _holders.push(account);
        _holderIndex[account] = _holders.length; // 1-based
    }

    function _removeHolder(address account) private {
        uint256 idx = _holderIndex[account];
        if (idx == 0) return;
        // Defer compaction whenever removing now could cost someone an already-earned reward:
        //  1. Unsettled weight in the still-open round -- processBatch will iterate it once that
        //     round closes, and removing now means they'd never be visited.
        //  2. Unconsumed weight in a round that's mid-payout -- removing drops it before it's paid.
        //  3. Even owing nothing, compacting during an active payout must not relocate the
        //     swap-and-pop replacement (always the tail) from the not-yet-visited region into one
        //     the cursor already swept, which would orphan whoever lands there.
        // A deferred entry is a harmless zero-balance placeholder: skipped by weight when visited,
        // and removable normally on this account's next transfer once distribution moves past it.
        if (_balanceSecondsByRound[_roundId][account] > 0) return;
        if (distributing) {
            if (_balanceSecondsByRound[_payoutRoundId][account] > 0) return;
            if ((idx - 1) < _payoutCursor) return;
        }
        uint256 lastIdx = _holders.length;
        address lastHolder = _holders[lastIdx - 1];
        _holders[idx - 1] = lastHolder;
        _holderIndex[lastHolder] = idx;
        _holders.pop();
        delete _holderIndex[account];
    }

    // Rolls this account's balance-seconds forward into the currently-open round. A no-op before a
    // reward config exists, or for an excluded address. Settles the still-distributing round first:
    // _lastAccrued is a single scalar, so advancing it into the current round would lose where the
    // closed round left off. See _settleForPayout.
    function _accrue(address account) private {
        if (rewardHook == address(0) || _isExcludedFromRewards(account)) return;
        if (distributing) _settleForPayout(account);
        uint256 last = _lastAccrued[account];
        uint256 from = last < roundStart ? roundStart : last; // don't count time from before this round began
        if (block.timestamp > from) {
            uint256 delta = _balances[account] * (block.timestamp - from);
            _balanceSecondsByRound[_roundId][account] += delta;
        }
        _lastAccrued[account] = block.timestamp;
    }

    // Same shape as _accrue but for the aggregate _totalEligibleBalance, which backs a round's total
    // weight at close time regardless of who transacted.
    function _accrueTotal() private {
        if (rewardHook == address(0)) return;
        uint256 last = _lastTotalAccrued;
        uint256 from = last < roundStart ? roundStart : last;
        if (block.timestamp > from) {
            _totalBalanceSecondsByRound[_roundId] += _totalEligibleBalance * (block.timestamp - from);
        }
        _lastTotalAccrued = block.timestamp;
    }

    // Catches this account up through _payoutRoundEnd, crediting what it's owed into that round's
    // bucket rather than the current one. Idempotent.
    function _settleForPayout(address account) private {
        uint256 last = _lastAccrued[account];
        if (last >= _payoutRoundEnd) return;
        uint256 from = last < _payoutRoundStart ? _payoutRoundStart : last;
        if (_payoutRoundEnd > from) {
            uint256 delta = _balances[account] * (_payoutRoundEnd - from);
            _balanceSecondsByRound[_payoutRoundId][account] += delta;
        }
        _lastAccrued[account] = _payoutRoundEnd;
    }

    // The hook calls this at claimFees time with its 5% carve-out, approve()ing it first; this pulls it via
    // transferFrom.
    function depositHolderReward(uint256 amount) external {
        if (msg.sender != rewardHook) revert NotRewardHook();
        if (amount == 0) return;
        if (!IDuckOpenTokenERC20(rewardCurrency).transferFrom(msg.sender, address(this), amount)) revert TokenRescueFailed();
        roundPool += amount;
        emit HolderRewardDeposited(amount);
    }

    // Closes the accruing round into the payout snapshot and opens a fresh one under a new _roundId.
    // Runs at the top of processBatch; a no-op if a previous round's batches are unfinished or the
    // interval hasn't elapsed.
    function _closeRoundIfDue() private {
        if (rewardHook == address(0) || distributing) return;
        if (block.timestamp < roundStart + DISTRIBUTION_INTERVAL) return;

        _accrueTotal(); // bring the total up to the exact close instant, independent of who transacted

        _payoutRoundId = _roundId;
        _payoutRoundStart = roundStart;
        _payoutRoundEnd = block.timestamp;
        _payoutPool = roundPool;
        _payoutTotalWeight = _totalBalanceSecondsByRound[_roundId];
        _payoutCursor = 0;
        distributing = _payoutPool > 0 && _payoutTotalWeight > 0;

        emit DistributionRoundClosed(roundStart, _payoutPool, _holders.length, _payoutTotalWeight);

        _roundId += 1;
        roundStart = block.timestamp;
        roundPool = 0;
        if (!distributing) _payoutPool = 0; // nothing to pay out -- skip straight to done
    }

    // Advances up to BATCH_SIZE holders through the frozen payout snapshot. Eligibility
    // (MIN_HOLDING_BPS) is checked against CURRENT balance; weight comes from the frozen
    // balance-seconds recorded at round close. Permissionless and never wired into _transfer.
    function processBatch() public nonReentrant {
        _closeRoundIfDue();
        if (!distributing) return;

        uint256 n = _holders.length;
        uint256 end = _payoutCursor + BATCH_SIZE;
        if (end > n) end = n;

        uint256 minBalance = _totalSupply * MIN_HOLDING_BPS / 10_000;
        uint256 roundId = _payoutRoundId;
        address currency = rewardCurrency;

        for (uint256 i = _payoutCursor; i < end; ++i) {
            address account = _holders[i];
            _settleForPayout(account); // catch up anyone who never transacted during this round at all
            uint256 weight = _balanceSecondsByRound[roundId][account];
            delete _balanceSecondsByRound[roundId][account]; // consumed strictly before any external call below
            if (weight == 0 || _balances[account] < minBalance) continue;

            uint256 amount = (weight * _payoutPool) / _payoutTotalWeight;
            if (amount == 0) continue;
            // Gas-capped so one holder's transfer can't eat the batch's gas; a failed payout just skips them.
            (bool ok, bytes memory ret) = currency.call{gas: 100_000}(
                abi.encodeWithSelector(IDuckOpenTokenERC20.transfer.selector, account, amount)
            );
            if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) continue;
            emit HolderRewardPaid(account, amount);
        }

        _payoutCursor = end;
        if (end >= n) {
            distributing = false;
            emit DistributionRoundFinished(roundStart);
        }
    }

    function _approve(address owner_, address spender, uint256 amount) private {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[owner_][spender] = amount;
        emit Approval(owner_, spender, amount);
    }

    function _getVotingUnits(address account) internal view override returns (uint256) {
        return _balances[account];
    }

    function delegates(address account) public pure override returns (address) {
        return account;
    }

    function delegate(address) public pure override {
        revert DelegationDisabled();
    }

    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) public pure override {
        revert DelegationDisabled();
    }

    function DOMAIN_SEPARATOR() public view returns (bytes32) {
        return _domainSeparatorV4();
    }

    function permit(
        address owner_,
        address spender,
        uint256 value,
        uint256 deadline,
        uint8   v,
        bytes32 r,
        bytes32 s
    ) external {
        if (block.timestamp > deadline) revert PermitExpired();
        bytes32 structHash = keccak256(abi.encode(
            PERMIT_TYPEHASH, owner_, spender, value, _useNonce(owner_), deadline
        ));
        address signer = ecrecover(_hashTypedDataV4(structHash), v, r, s);
        if (signer == address(0) || signer != owner_) revert InvalidSignature();
        _approve(owner_, spender, value);
    }

}

interface IDuckOpenTokenERC20 {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
}
