// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckReliquify
//
// Migrates an OLD token (any token -- a rescue after a ghosted dev or a compromised third-party
// platform, not necessarily anything duckpad ever touched) to a brand-new one with the same fixed
// total supply. A "leader" proposes a migration (old token, a snapshot of eligible holder balances as
// of a block, an excluded-wallet list) and the platform reviews it off-chain before approving it
// on-chain -- nothing is live until then. Holders then deposit old tokens (capped at their own
// snapshotted balance) for the new token 1:1. Once cumulative deposits reach 50% of the snapshotted
// eligible supply, the accumulated old tokens are sold and used (with a portion of the pre-minted new
// supply) to seed a real V4 pool, registered with the same DuckGenesisHook every other launch family
// uses, so the new token gets normal holder-reward/fee treatment. After that, every further
// depositor's old token is sold immediately and the proceeds buy back and burn the new token instead
// of feeding the (already-seeded) pool.
//
// The migrated token is ALWAYS paired with ETH -- deliberately, regardless of whatever quote asset the
// old token happened to be paired with on its original platform. Every old token just gets sold for
// native ETH via LaunchRouting's existing routes[] + universalRouter machinery (unmodified, not a new
// "arbitrary admin-approved router" primitive -- see setRoutes below), and that ETH (wrapped to WETH)
// is what seeds the new pool and backs every post-seed buyback. One canonical currency for every
// migration keeps this simple: no per-migration quote-asset field, no allowlist for it, no two-hop
// routing to reach some other asset.

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchRouting, Route, RouteShape, PoolKey} from "duck-lib/LaunchRouting.sol";
import {V4Minting} from "duck-lib/V4Minting.sol";

interface IDuckReliquifyTokenLocal {
    function initToken(
        string calldata name_, string calldata symbol_, uint256 totalSupply_, bool lockUntilUnlock_, string calldata metaURI_,
        address hook_, address currency_, address poolManager_
    ) external;
    function renounceOwnership() external;
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDuckVaultFactoryLocal {
    function createVault(address token, uint8 tokenDecimals, address creator_) external returns (address vault);
}

interface IDuckVaultLinkLocal {
    function linkPool(address currency, bytes32 poolId, bool tokenIsCurrency0, uint8 currencyDecimals, bool poolQuoteIsNative) external;
}

interface ITokenVaultPointerLocal {
    function vault() external view returns (address);
}

interface IERC20DecimalsLocal {
    function decimals() external view returns (uint8);
}

interface IERC20SupplyLocal {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IERC20BalanceLocal {
    function balanceOf(address account) external view returns (uint256);
}

interface IHookLauncherCheckLocal {
    function isLauncher(address account) external view returns (bool);
}

contract DuckReliquify is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuard, LaunchRouting {

    error ZeroAddress();
    error ZeroAmount();
    error CloneFailed();
    error MigrationNotFound();
    error NotLeader();
    error WrongStatus();
    error AlreadyExcluded();
    error AlreadyFinalized_();
    error NotFinalized_();
    error ThresholdNotReached();
    error ThresholdAlreadyReached();
    error CapExceeded();
    error NothingToClaim();
    error NothingToRefund();
    error InvalidVaultBps();
    error InvalidHookFeeBps();
    error HookNotAdded();
    error SellRouteNotConfigured();
    error Paused();
    error WrongFee();
    error SnapshotExceedsSupply();
    error RescueExceedsSurplus();
    error CannotRescueMigrationToken();

    enum MigrationStatus { Proposed, Approved, Live, Seeded, Rejected, Cancelled, Aborted }

    // No native pool fee -- matches every other launch family (see DuckCrowdfund's identical
    // comment): the creator-chosen hook fee is the sole trading fee, liquidity goes straight into the
    // PoolManager singleton and is never withdrawn.
    uint24  private constant FEE_TIER     = 0;
    int24   private constant TICK_SPACING = 200;
    address private constant DEAD         = 0x000000000000000000000000000000000000dEaD;

    struct Migration {
        address leader;
        address oldToken;
        address newToken;        // deployed at approveMigration, minted to the OLD token's own
                                  // totalSupply() (read live on-chain then, not leader-asserted)
        uint256 eligibleSupply;  // sum of real depositor snapshot entries -- ALWAYS fully backs
                                  // pendingClaim/depositPostSeed 1:1, independent of LP sizing (see
                                  // approveMigration: `reserved` is set to exactly this, never touched
                                  // by the LP allocation, so a depositor's redemption can never be
                                  // starved no matter how much of the old token was never captured by
                                  // the snapshot -- unlike an earlier draft that carved the LP out of
                                  // this same guaranteed pool)
        uint256 totalDeposited;  // pre-seed cumulative old-token deposits (post balance-diffing)
        uint256 reserved;        // = eligibleSupply at approval, decremented as pendingClaim/
                                  // depositPostSeed pay out -- never anything else
        uint256 lpSupply;        // = oldToken.totalSupply() - eligibleSupply - oldToken.balanceOf(DEAD)
                                  // at approval time -- whatever of the old supply was never a real,
                                  // snapshotted depositor and never sat at the dead address becomes the
                                  // new pool's liquidity instead of being orphaned
        uint256 hookFeeBps;
        uint16  creatorBps;
        uint16  vaultBps;
        uint16  burnBps;
        bool    snapshotFinalized;
        bool    thresholdReached;
        MigrationStatus status;
    }

    Migration[] private migrations;

    mapping(uint256 => mapping(address => uint256)) public eligibleBalance; // snapshot, pre-approval only
    mapping(uint256 => mapping(address => bool))    public excluded;        // one-way once set
    mapping(uint256 => mapping(address => uint256)) public deposited;       // capped at eligibleBalance
    mapping(uint256 => mapping(address => uint256)) public pendingClaim;    // pre-seed entitlement
    mapping(uint256 => bool) public paused;                                 // per-migration kill switch

    address public tokenImpl;
    address public vaultFactory;
    address public weth;
    address public v4Singleton;
    address public v4PositionManager;
    address public v4Hook;
    address public platformWallet;
    uint256 public reliquifyFee;

    event MigrationProposed(uint256 indexed id, address indexed leader, address indexed oldToken);
    event SnapshotBatchSubmitted(uint256 indexed id, uint256 count, uint256 eligibleSupply);
    event AddressExcluded(uint256 indexed id, address indexed account);
    event SnapshotFinalized(uint256 indexed id, uint256 eligibleSupply);
    event MigrationApproved(uint256 indexed id, address indexed newToken, uint256 eligibleSupply);
    event MigrationRejected(uint256 indexed id);
    event MigrationAborted(uint256 indexed id);
    event Deposited(uint256 indexed id, address indexed account, uint256 oldAmount, bool postSeed);
    event Claimed(uint256 indexed id, address indexed account, uint256 amount);
    event Refunded(uint256 indexed id, address indexed account, uint256 amount);
    event PoolSeeded(uint256 indexed id, bytes32 poolId, uint256 quoteRaised);
    event BuybackBurned(uint256 indexed id, uint256 quoteIn, uint256 burned);
    event PausedSet(uint256 indexed id, bool paused);
    event TokenImplSet(address indexed tokenImpl);
    event VaultFactorySet(address indexed vaultFactory);
    event WethSet(address indexed weth);
    event DexConfigSet(address positionManager, address singleton, address hook);
    event PlatformWalletSet(address indexed wallet);
    event ReliquifyFeeSet(uint256 fee);
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address weth_,
        address tokenImpl_,
        address v4Singleton_,
        address v4PositionManager_,
        address v4Hook_,
        address platformWallet_
    ) external initializer {
        if (weth_               == address(0)) revert ZeroAddress();
        if (tokenImpl_          == address(0)) revert ZeroAddress();
        if (v4Singleton_        == address(0)) revert ZeroAddress();
        if (v4PositionManager_  == address(0)) revert ZeroAddress();
        if (platformWallet_     == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);
        __Ownable2Step_init();

        weth              = weth_;
        tokenImpl         = tokenImpl_;
        v4Singleton       = v4Singleton_;
        v4PositionManager = v4PositionManager_;
        v4Hook            = v4Hook_;
        platformWallet    = platformWallet_;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ---------- admin config (all onlyOwner, same instant-toggle shape every other launch family
    // already uses -- no separate backend admin-auth layer, matching how every admin control in this
    // protocol has always worked) ----------

    function setTokenImpl(address tokenImpl_) external onlyOwner {
        if (tokenImpl_ == address(0)) revert ZeroAddress();
        tokenImpl = tokenImpl_;
        emit TokenImplSet(tokenImpl_);
    }

    function setVaultFactory(address vaultFactory_) external onlyOwner {
        if (vaultFactory_ == address(0)) revert ZeroAddress();
        vaultFactory = vaultFactory_;
        emit VaultFactorySet(vaultFactory_);
    }

    function setWeth(address weth_) external onlyOwner {
        if (weth_ == address(0)) revert ZeroAddress();
        weth = weth_;
        emit WethSet(weth_);
    }

    function setDexConfig(address positionManager_, address singleton_, address hook_) external onlyOwner {
        if (positionManager_ == address(0)) revert ZeroAddress();
        if (singleton_        == address(0)) revert ZeroAddress();
        v4PositionManager = positionManager_;
        v4Singleton       = singleton_;
        v4Hook            = hook_;
        emit DexConfigSet(positionManager_, singleton_, hook_);
    }

    function setPlatformWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        platformWallet = wallet;
        emit PlatformWalletSet(wallet);
    }

    function setReliquifyFee(uint256 fee_) external onlyOwner {
        reliquifyFee = fee_;
        emit ReliquifyFeeSet(fee_);
    }

    function setUniversalRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        _setUniversalRouter(router_);
    }

    // Configures how a SPECIFIC old token gets sold for native ETH -- reused unmodified from
    // LaunchRouting, the same mechanism DuckCrowdfund/DuckLauncher/DuckBondingCurve already expose.
    // For a migration this is how the admin approves ITS specific sell path: call this for oldToken_
    // (a path ending at native) as part of reviewing a proposal. Deliberately NOT a per-migration
    // field -- routes are global per-token on this contract, admin-managed, exactly like every other
    // launch family's routing config.
    function setRoutes(address token_, Route[] calldata routes_) external onlyOwner {
        _setRoutes(token_, routes_);
    }

    // Recovery for stray funds only (accidental sends, dust). ETH never rests here in normal operation --
    // every sale's proceeds are wrapped/spent within the same transaction -- so all of it is rescuable.
    function rescueETH(address to_, uint256 amount_) external onlyOwner nonReentrant {
        if (to_     == address(0)) revert ZeroAddress();
        if (amount_ == 0)         revert ZeroAmount();
        (bool ok,) = to_.call{value: amount_}("");
        if (!ok) revert TransferFailed();
        emit ETHRescued(to_, amount_);
    }

    // Unlike the other launch families' rescue functions, this contract holds depositors' old tokens in
    // custody, so the owner may only take the SURPLUS of a token over what is still owed: old tokens
    // held for a Live (awaiting seed) or Aborted (awaiting refund) migration are off-limits, and any
    // migration's new token is refused outright (unclaimed totals aren't tracked on-chain, so surplus
    // can't be told apart from what depositors are owed).
    function rescueERC20(address token_, address to_, uint256 amount_) external onlyOwner nonReentrant {
        if (token_  == address(0)) revert ZeroAddress();
        if (to_     == address(0)) revert ZeroAddress();
        if (amount_ == 0)         revert ZeroAmount();

        uint256 committed;
        for (uint256 i; i < migrations.length; ++i) {
            Migration storage m = migrations[i];
            if (m.newToken == token_) revert CannotRescueMigrationToken();
            if (m.oldToken == token_ && (m.status == MigrationStatus.Live || m.status == MigrationStatus.Aborted)) {
                committed += m.totalDeposited;
            }
        }
        uint256 balance = IERC20BalanceLocal(token_).balanceOf(address(this));
        if (balance < committed + amount_) revert RescueExceedsSurplus();

        _safeTransfer(token_, to_, amount_);
        emit ERC20Rescued(token_, to_, amount_);
    }

    function setPaused(uint256 id, bool paused_) external onlyOwner {
        if (id >= migrations.length) revert MigrationNotFound();
        paused[id] = paused_;
        emit PausedSet(id, paused_);
    }

    function migrationCount() external view returns (uint256) {
        return migrations.length;
    }

    function getMigration(uint256 id) external view returns (
        address leader, address oldToken, address newToken, uint256 eligibleSupply,
        uint256 totalDeposited, uint256 reserved, MigrationStatus status
    ) {
        Migration storage m = migrations[id];
        return (m.leader, m.oldToken, m.newToken, m.eligibleSupply, m.totalDeposited, m.reserved, m.status);
    }

    function canDeposit(uint256 id, address account, uint256 amount) external view returns (bool) {
        if (id >= migrations.length) return false;
        Migration storage m = migrations[id];
        if (paused[id] || excluded[id][account]) return false;
        return deposited[id][account] + amount <= eligibleBalance[id][account];
    }

    // ---------- proposal + snapshot (leader-driven, Proposed status only) ----------

    function proposeMigration(
        address oldToken_, uint256 hookFeeBps_,
        uint16 creatorBps_, uint16 vaultBps_, uint16 burnBps_
    ) external payable nonReentrant returns (uint256 id) {
        if (oldToken_ == address(0)) revert ZeroAddress();
        if (msg.value != reliquifyFee) revert WrongFee();
        if (!_isValidHookFeeBps(hookFeeBps_)) revert InvalidHookFeeBps();
        if (uint256(creatorBps_) + vaultBps_ + burnBps_ != 10_000) revert InvalidVaultBps();

        if (reliquifyFee > 0) {
            (bool ok,) = platformWallet.call{value: reliquifyFee}("");
            if (!ok) revert TransferFailed();
        }

        id = migrations.length;
        Migration storage m = migrations.push();
        m.leader        = msg.sender;
        m.oldToken      = oldToken_;
        m.hookFeeBps    = hookFeeBps_;
        m.creatorBps    = creatorBps_;
        m.vaultBps      = vaultBps_;
        m.burnBps       = burnBps_;
        m.status        = MigrationStatus.Proposed;
        emit MigrationProposed(id, msg.sender, oldToken_);
    }

    // Delta-based and idempotent, not additive: a later batch correcting an already-submitted address
    // (routine -- wrong block, typo, a duplicate wallet found) must not double-count it, since
    // eligibleSupply becomes the new token's fixed total supply at approval. Reverts (never silently
    // skips) on any address already excluded, so a correction batch can't accidentally re-back an
    // excluded wallet's balance into the fixed supply -- exclusion is terminal once set.
    function submitSnapshotBatch(uint256 id, address[] calldata accounts, uint256[] calldata balances) external nonReentrant {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (msg.sender != m.leader) revert NotLeader();
        if (m.status != MigrationStatus.Proposed) revert WrongStatus();
        uint256 supply = m.eligibleSupply;
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (excluded[id][account]) revert AlreadyExcluded();
            uint256 previous = eligibleBalance[id][account];
            uint256 balance = balances[i];
            eligibleBalance[id][account] = balance;
            supply = supply - previous + balance;
        }
        m.eligibleSupply = supply;
        emit SnapshotBatchSubmitted(id, accounts.length, supply);
    }

    function submitExclusions(uint256 id, address[] calldata accounts) external nonReentrant {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (msg.sender != m.leader) revert NotLeader();
        if (m.status != MigrationStatus.Proposed) revert WrongStatus();
        uint256 supply = m.eligibleSupply;
        for (uint256 i; i < accounts.length; ++i) {
            address account = accounts[i];
            if (excluded[id][account]) continue;
            excluded[id][account] = true;
            supply -= eligibleBalance[id][account];
            emit AddressExcluded(id, account);
        }
        m.eligibleSupply = supply;
    }

    // Unambiguous "the leader says this data is complete, please review it" signal -- required before
    // approveMigration will accept the migration.
    function finalizeSnapshot(uint256 id) external nonReentrant {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (msg.sender != m.leader) revert NotLeader();
        if (m.status != MigrationStatus.Proposed) revert WrongStatus();
        if (m.eligibleSupply == 0) revert ZeroAmount();
        m.snapshotFinalized = true;
        emit SnapshotFinalized(id, m.eligibleSupply);
    }

    // ---------- admin review ----------

    // New token's total supply matches the OLD token's real, live totalSupply() exactly -- not just
    // the snapshotted eligible portion -- read on-chain here, never leader-asserted. Of that supply:
    // eligibleSupply is set aside whole, unconditionally, for real depositor 1:1 redemption (this can
    // NEVER run short no matter how many people eventually deposit, since it's never touched by LP
    // sizing); the old token's dead-address balance is mirrored 1:1 straight to the same address on
    // the new token; everything else that's neither a real snapshotted depositor nor already-burned
    // becomes the new pool's liquidity, rather than being orphaned. Reverts if the snapshot claims
    // more than the old token's real supply can back -- a red flag review should already have caught.
    function approveMigration(
        uint256 id, string calldata name_, string calldata symbol_, string calldata metaURI_
    ) external onlyOwner nonReentrant returns (address token) {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (m.status != MigrationStatus.Proposed) revert WrongStatus();
        if (!m.snapshotFinalized) revert WrongStatus();
        if (!IHookLauncherCheckLocal(v4Hook).isLauncher(address(this))) revert HookNotAdded();

        uint256 oldSupply = IERC20SupplyLocal(m.oldToken).totalSupply();
        uint256 deadBalance = IERC20SupplyLocal(m.oldToken).balanceOf(DEAD);
        if (m.eligibleSupply + deadBalance > oldSupply) revert SnapshotExceedsSupply();

        // Reward currency is always weth -- every migration's pool is ETH-paired, unconditionally.
        token = _clone(tokenImpl, keccak256(abi.encode(id, m.oldToken, block.timestamp)));
        IDuckReliquifyTokenLocal(token).initToken(name_, symbol_, oldSupply, false, metaURI_, v4Hook, weth, v4Singleton);
        IDuckReliquifyTokenLocal(token).renounceOwnership();

        if (vaultFactory != address(0) && m.vaultBps > 0) {
            IDuckVaultFactoryLocal(vaultFactory).createVault(token, IERC20DecimalsLocal(token).decimals(), platformWallet);
        }

        m.newToken = token;
        m.reserved = m.eligibleSupply;
        m.lpSupply = oldSupply - m.eligibleSupply - deadBalance;
        if (deadBalance > 0) IDuckReliquifyTokenLocal(token).transfer(DEAD, deadBalance);

        m.status = MigrationStatus.Live;
        emit MigrationApproved(id, token, oldSupply);
    }

    function rejectMigration(uint256 id) external onlyOwner {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (m.status != MigrationStatus.Proposed) revert WrongStatus();
        m.status = MigrationStatus.Rejected;
        emit MigrationRejected(id);
    }

    // Leader- or admin-triggered, only before the pool exists -- without this, deposits stuck below
    // the 50% threshold forever have no exit, unlike every other launch family's refund path.
    function abortMigration(uint256 id) external {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (msg.sender != m.leader && msg.sender != owner()) revert NotLeader();
        if (m.status != MigrationStatus.Live) revert WrongStatus();
        m.status = MigrationStatus.Aborted;
        emit MigrationAborted(id);
    }

    // ---------- deposits ----------

    // Pre-seed: custody only, no router touched. Never trusts the nominal `amount` -- oldToken can be
    // fee-on-transfer, since it's any third-party token -- so every downstream number (the per-account
    // cap, totalDeposited, the eventual seedPool sell size) reflects what was actually received.
    function depositPreSeed(uint256 id, uint256 amount) external nonReentrant {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (paused[id]) revert Paused();
        if (m.status != MigrationStatus.Live) revert WrongStatus();
        if (excluded[id][msg.sender]) revert CapExceeded();
        if (amount == 0) revert ZeroAmount();
        if (deposited[id][msg.sender] + amount > eligibleBalance[id][msg.sender]) revert CapExceeded();

        uint256 received = _pullBalanceDiffed(m.oldToken, msg.sender, amount);
        deposited[id][msg.sender] += received;
        pendingClaim[id][msg.sender] += received;
        // Reserved the moment the obligation exists (this deposit), not deferred to whenever the
        // depositor actually calls claim() -- otherwise a depositPostSeed in between could spend
        // tokens already promised here, and this depositor's later claim() could come up short even
        // though their entitlement was always supposed to be guaranteed.
        m.reserved -= received;
        m.totalDeposited += received;
        if (!m.thresholdReached && m.totalDeposited >= m.eligibleSupply / 2) {
            m.thresholdReached = true;
        }
        emit Deposited(id, msg.sender, received, false);
    }

    // Separate, explicit transaction -- never fired automatically inside a depositor's own call, so a
    // human (or a keeper voluntarily accepting the timing/MEV risk) always chooses the moment, can
    // verify the configured route hasn't gone stale, and gets a real slippage floor. Owner-only for
    // now, same "simplest to ship, open up once battle-tested" tradeoff DuckGenesisHook.claimFees
    // already makes for its own permissionless-vs-manual choice.
    function seedPool(uint256 id, uint256 minQuoteOut) external onlyOwner nonReentrant {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (paused[id]) revert Paused();
        if (m.status != MigrationStatus.Live) revert WrongStatus();
        if (!m.thresholdReached) revert ThresholdNotReached();

        uint256 quoteRaised = _sellOldTokenForNative(m.oldToken, m.totalDeposited, minQuoteOut);
        uint256 lpSupply = m.lpSupply;

        bytes32 poolId = _seedInitialLiquidity(id, m, lpSupply, quoteRaised);
        m.status = MigrationStatus.Seeded;
        emit PoolSeeded(id, poolId, quoteRaised);
    }

    function _seedInitialLiquidity(uint256 id, Migration storage m, uint256 lpSupply, uint256 quoteRaised) private returns (bytes32 poolId) {
        address quoteToken = weth;
        // The pool's own currency is always the WRAPPED asset (same reason DuckCrowdfund/
        // BondingCurveMigration wrap before seeding: DuckGenesisHook's PoolKey never uses address(0)),
        // so wrap what was just raised before settling liquidity, or _mintFullRangeDirect's WETH
        // transfer at settlement has nothing backing it.
        IWETHDeposit(weth).deposit{value: quoteRaised}();
        (address token0, address token1) = m.newToken < quoteToken ? (m.newToken, quoteToken) : (quoteToken, m.newToken);
        (uint256 amount0, uint256 amount1) = m.newToken == token0 ? (lpSupply, quoteRaised) : (quoteRaised, lpSupply);

        V4Minting.MintFullRangeSetupParams memory p;
        p.positionManager = v4PositionManager;
        p.hook            = v4Hook;
        p.token           = m.newToken;
        p.token0          = token0;
        p.token1          = token1;
        p.amount0         = amount0;
        p.amount1         = amount1;
        // Hardcoded to platformWallet, never the migration leader: registerPool's `creator` gets
        // permanent hook-fee-claim rights and setFeeSplits control over the pool -- a leader who
        // merely proposed a migration is a different, weaker trust class than someone who launched a
        // token themselves, and shouldn't inherit that indefinite privilege.
        p.creator         = platformWallet;
        p.hookFeeBps      = m.hookFeeBps;
        p.creatorBps      = m.creatorBps;
        p.vaultBps        = m.vaultBps;
        p.burnBps         = m.burnBps;
        p.fee             = FEE_TIER;
        p.tickSpacing     = TICK_SPACING;

        PoolKey memory key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        (poolId, key, tickLower, tickUpper, liquidity) = V4Minting.setupFullRangePool(p);
        _mintFullRangeDirect(v4Singleton, key, tickLower, tickUpper, liquidity);

        address vault = ITokenVaultPointerLocal(m.newToken).vault();
        if (vault != address(0)) {
            try IDuckVaultLinkLocal(vault).linkPool(quoteToken, poolId, m.newToken == token0, IERC20DecimalsLocal(quoteToken).decimals(), false) {} catch {}
        }
    }

    // Post-seed: the pool already exists, so every deposit is atomic -- sell, mint 1:1 to the
    // depositor from the reserved (non-LP) supply, buy back and burn with the ACTUAL proceeds.
    function depositPostSeed(uint256 id, uint256 amount, uint256 minQuoteOut, uint256 minBurnOut) external nonReentrant {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (paused[id]) revert Paused();
        if (m.status != MigrationStatus.Seeded) revert WrongStatus();
        if (excluded[id][msg.sender]) revert CapExceeded();
        if (amount == 0) revert ZeroAmount();
        if (deposited[id][msg.sender] + amount > eligibleBalance[id][msg.sender]) revert CapExceeded();

        uint256 received = _pullBalanceDiffed(m.oldToken, msg.sender, amount);
        deposited[id][msg.sender] += received;
        m.totalDeposited += received;
        if (received > m.reserved) revert CapExceeded();
        m.reserved -= received;

        IDuckReliquifyTokenLocal(m.newToken).transfer(msg.sender, received);

        uint256 quoteOut = _sellOldTokenForNative(m.oldToken, received, minQuoteOut);
        uint256 burned = _buybackAndBurn(m, quoteOut, minBurnOut);
        emit Deposited(id, msg.sender, received, true);
        emit BuybackBurned(id, quoteOut, burned);
    }

    function claim(uint256 id) external nonReentrant {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (m.status != MigrationStatus.Seeded) revert NotFinalized_();
        uint256 amount = pendingClaim[id][msg.sender];
        if (amount == 0) revert NothingToClaim();
        pendingClaim[id][msg.sender] = 0;
        IDuckReliquifyTokenLocal(m.newToken).transfer(msg.sender, amount);
        emit Claimed(id, msg.sender, amount);
    }

    function refundOldToken(uint256 id) external nonReentrant {
        if (id >= migrations.length) revert MigrationNotFound();
        Migration storage m = migrations[id];
        if (m.status != MigrationStatus.Aborted) revert NotFinalized_();
        uint256 amount = deposited[id][msg.sender];
        if (amount == 0) revert NothingToRefund();
        deposited[id][msg.sender] = 0;
        // Keeps totalDeposited meaning "currently held for this migration," matching deposited[]'s own
        // per-account semantics, rather than "cumulative ever deposited" -- caught by an invariant fuzz
        // test comparing sum(deposited[account]) against totalDeposited across random deposit/abort/
        // refund sequences. Harmless today (a migration can never return to Live once Aborted, so
        // nothing re-reads totalDeposited afterward), but leaving it stale was a real, if currently
        // unexploited, accounting drift.
        m.totalDeposited -= amount;
        _safeTransfer(m.oldToken, msg.sender, amount);
        emit Refunded(id, msg.sender, amount);
    }

    // ---------- internal: balance-diffed sell/buy, never trust nominal amounts or router return values ----------

    function _pullBalanceDiffed(address token_, address from, uint256 amount) private returns (uint256 received) {
        uint256 before = IERC20BalanceLocal(token_).balanceOf(address(this));
        _safeTransferFrom(token_, from, address(this), amount);
        received = IERC20BalanceLocal(token_).balanceOf(address(this)) - before;
    }

    // oldToken -> native. Every migration sells for plain native ETH, unconditionally -- the pool is
    // always ETH-paired regardless of what the old token was ever quoted against, so there's no second
    // hop to anything else.
    function _sellOldTokenForNative(address oldToken_, uint256 amount, uint256 minNativeOut) private returns (uint256 nativeOut) {
        if (routes[oldToken_].length == 0) revert SellRouteNotConfigured();
        (uint256 out, bool ok) = _disposeQuoteToken(oldToken_, amount, minNativeOut, address(this));
        if (!ok) revert SellRouteNotConfigured();
        nativeOut = out;
    }

    // Buys the new token with quoteAmount via the pool seedPool just created (internal buy-and-burn,
    // same primitive DuckBondingCurve/DuckHookV4 use for their own buy-and-burn against a pool this
    // contract already controls) and burns whatever it receives.
    function _buybackAndBurn(Migration storage m, uint256 quoteAmount, uint256 minBurnOut) private returns (uint256 burned) {
        if (quoteAmount == 0) return 0;
        IWETHDeposit(weth).deposit{value: quoteAmount}();
        burned = _executeV4Swap(v4Singleton, v4Hook, FEE_TIER, TICK_SPACING, weth, m.newToken, quoteAmount, minBurnOut, address(this));
        _safeTransfer(m.newToken, address(0x000000000000000000000000000000000000dEaD), burned);
    }

    function _clone(address implementation, bytes32 salt) private returns (address instance) {
        assembly ("memory-safe") {
            let ptr := mload(0x40)
            mstore(ptr,         0x3d602d80600a3d3981f3363d3d373d3d3d363d73000000000000000000000000)
            mstore(add(ptr, 0x14), shl(0x60, implementation))
            mstore(add(ptr, 0x28), 0x5af43d82803e903d91602b57fd5bf30000000000000000000000000000000000)
            instance := create2(0, ptr, 0x37, salt)
        }
        if (instance == address(0)) revert CloneFailed();
    }

    function _isValidHookFeeBps(uint256 bps) private pure returns (bool) {
        return bps <= 1000;
    }

    receive() external payable {}
}

interface IWETHDeposit {
    function deposit() external payable;
}
