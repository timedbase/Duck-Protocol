// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckGenesisHook (Arc)
//
// Successor to DuckHookV4, which stays deployed and unchanged for the pools already bound to it (a
// pool's hook is part of its PoolKey forever). What changes here:
//
//  - Pools can only exist if a launcher registered them first. beforeInitialize refuses any key that
//    isn't registered, and beforeAddLiquidity refuses anyone but a launcher. Initialization is still
//    relayed through the PositionManager, so the gate is the registration, not the caller -- which
//    means launchers must call registerPool BEFORE initializing the pool (V4Minting today does it
//    after, and has to be reordered to use this hook).
//  - The trading fee is any rate up to 10%, fixed for the pool's life, instead of a 2/4/6/8/10 menu.
//  - Fees are taken on the quote side of every buy and sell, including exact-output swaps, which are
//    grossed up so they pay the same share as the equivalent exact-input trade. A swap whose fee was
//    taken before it ran must fill completely; a swap that moves nothing is refused.
//  - No per-block swap limit.
//  - Creator takeovers are an owner action (transferPoolCreator), no longer a paid public application.
//
// Fee payout (claimFees: platform, claimer, holders, vault, buy-and-burn, creator splits), the oracle
// and the launcher/owner administration are carried over from DuckHookV4 as-is.
//
// Arc build: every pool is quoted in an ERC-20 (USDC by default) -- a native-quoted key is refused at
// registration -- so fees, holder rewards, vault cuts and buybacks all move that ERC-20, and there's no WETH.

import {PoolKey, SwapParams, ModifyLiquidityParams} from "duck-lib/LaunchRouting.sol";
import {requireArcChain} from "duck-lib/ArcChain.sol";

interface IGenesisPoolManagerSwap {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

interface IGenesisPoolManagerTake {
    function take(address currency, address to, uint256 amount) external;
}

interface IGenesisERC20 {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IGenesisTokenVaultLookup {
    function vault() external view returns (address);
}

interface IGenesisVault {
    function depositFees(uint256 amount) external;
    function setCreator(address newCreator) external;
}

interface IGenesisTokenReward {
    function depositHolderReward(uint256 amount) external;
}

interface IGenesisStateView {
    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

contract DuckGenesisHook {

    error ZeroAddress();
    error NotOwner();
    error NotLauncher();
    error NotPoolManager();
    error AlreadyRegistered();
    error NotRegistered();
    error TransferFailed();
    error NotCreator();
    error TooManyFeeSplits();
    error InvalidFeeSplitBps();
    error InvalidHookFeeBps();
    error InvalidVaultBps();
    error InvalidPoolKey();
    error InvalidHookAddress();
    error Unauthorized();
    error NoVault();
    error LiquidityRemovalDisabled();
    error PartialFillRejected();
    error EmptyFillRejected();
    error FeeOverflow();

    struct OracleMeta {
        int56  cumulative;
        uint32 lastTs;
        int24  lastTick;
        uint16 index;
        uint16 count;
    }
    struct Observation { uint32 ts; int56 cumulative; }

    uint16 public constant ORACLE_CARDINALITY = 96;
    uint32 public constant ORACLE_PERIOD      = 300;

    mapping(bytes32 => OracleMeta) public oracleMeta;
    mapping(bytes32 => Observation[96]) private _observations;
    address public stateView;
    mapping(bytes32 => bool) public oracleDisabled;
    bool public oraclePaused;

    event StateViewSet(address indexed stateView);
    event OracleDisabledSet(bytes32 indexed poolId, bool disabled);
    event OraclePausedSet(bool paused);

    // Mined into the hook's own address and checked in the constructor:
    //   BEFORE_INITIALIZE (bit 13)          -- only registered pools can be created
    //   BEFORE_ADD_LIQUIDITY (bit 11)       -- only launchers can add liquidity
    //   BEFORE_REMOVE_LIQUIDITY (bit 9)     -- nobody can remove it
    //   BEFORE_SWAP | AFTER_SWAP (bits 7, 6)
    //   BEFORE_SWAP_RETURNS_DELTA (bit 3)   -- fee on a specified quote amount
    //   AFTER_SWAP_RETURNS_DELTA (bit 2)    -- fee on an unspecified quote amount
    uint160 public constant REQUIRED_PERMISSIONS = 0x2ACC;
    uint160 public constant PERMISSION_MASK      = 0x3FFF;

    uint256 public constant HOOK_FEE_DEFAULT_BPS = 200;
    // Hard ceiling on a pool's fee, 10%. Enforced here, not only in the launchers: those are
    // upgradeable and this contract isn't, so this is the number that actually binds.
    uint256 public constant MAX_HOOK_FEE_BPS     = 1000;
    uint256 private constant BPS                 = 10_000;
    uint256 public constant MAX_FEE_SPLITS       = 5;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // Protocol-wide, not per-pool: every pool this protocol mints uses a 0% native fee tier and the
    // same tick spacing, which the buyback path below relies on to rebuild a pool's key.
    uint24  private constant POOL_FEE_TIER      = 0;
    int24   private constant POOL_TICK_SPACING  = 200;
    uint160 private constant MIN_SQRT_PRICE_LIMIT = 4295128739;
    uint160 private constant MAX_SQRT_PRICE_LIMIT = 1461446703485210103287273052203988822378723970342;

    address public immutable poolManager;
    address public owner;
    address public platformWallet;
    mapping(address => bool) public isLauncher;

    // Set right before poolManager.unlock() and cleared after, so unlockCallback can confirm it's
    // mid-flight of a swap this contract itself initiated.
    address private _cbExpected;

    struct FeeSplit {
        address wallet;
        uint16  bps;
    }
    mapping(bytes32 => FeeSplit[]) private _feeSplits;

    struct PoolInfo {
        address token;
        address quoteCurrency;
        bool    tokenIsCurrency0;
        address creator;
        uint256 launchTimestamp;
        bool    registered;
        uint256 hookFeeBps;

        // Three-way split of the 70% remainder (see claimFees); must sum to exactly BPS (see
        // registerPool). Each is independently zeroable -- vaultBps == 0 deploys no vault at all,
        // burnBps == 0 never buys back and burns.
        uint16  creatorBps;
        uint16  vaultBps;
        uint16  burnBps;
    }

    mapping(bytes32 => PoolInfo) public pools;
    mapping(bytes32 => uint256)  public accruedFees;

    // Fixed protocol-wide, computed off the ORIGINAL total (not a shrinking remainder) so the shares
    // sum to exactly 100% regardless of order: 25% platform, 5% holders, 70% vault/creator.
    uint256 public constant PLATFORM_FEE_BPS  = 2500;
    uint256 public constant HOLDER_REWARD_BPS = 500;

    // Keeper incentive carved out of the PLATFORM's share (25% -> 24%), never the holder/vault/
    // creator shares. Paid to whoever calls claimFees unless that's the pool's own creator, who
    // already gets a cut regardless -- this is what makes permissionless claiming worth triggering.
    uint256 public constant CLAIMER_REWARD_BPS = 100;

    event PoolRegistered(bytes32 indexed poolId, address indexed token, address indexed creator, uint256 hookFeeBps);
    event FeesClaimed(bytes32 indexed poolId, uint256 amount);
    event BuybackBurned(bytes32 indexed poolId, uint256 quoteSpent, uint256 tokensBurned);
    event HolderRewardSkipped(bytes32 indexed poolId, uint256 amount);
    event PlatformWalletSet(address indexed wallet);
    event VaultCutSkipped(bytes32 indexed poolId, uint256 amount);
    event FeeSplitsUpdated(bytes32 indexed poolId, FeeSplit[] splits);
    event CreatorTransferred(bytes32 indexed poolId, address indexed previousCreator, address indexed newCreator);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event LauncherAdded(address indexed launcher);
    event LauncherRemoved(address indexed launcher);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }
    modifier onlyPoolManager() { if (msg.sender != poolManager) revert NotPoolManager(); _; }

    constructor(address poolManager_) {
        requireArcChain();
        if (poolManager_ == address(0)) revert ZeroAddress();
        // The PoolManager only calls the hooks whose bits are set in the hook's address. Deployed at an
        // address missing one of them, the launcher gates or the liquidity lock would silently never
        // run, so a wrongly mined salt fails here instead.
        if (uint160(address(this)) & PERMISSION_MASK != REQUIRED_PERMISSIONS) revert InvalidHookAddress();
        poolManager = poolManager_;
        owner       = msg.sender;
    }

    // ---------------------------------------------------------------- administration

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    function addLauncher(address launcher_) external onlyOwner {
        if (launcher_ == address(0)) revert ZeroAddress();
        isLauncher[launcher_] = true;
        emit LauncherAdded(launcher_);
    }

    function removeLauncher(address launcher_) external onlyOwner {
        isLauncher[launcher_] = false;
        emit LauncherRemoved(launcher_);
    }

    function setPlatformWallet(address wallet_) external onlyOwner {
        if (wallet_ == address(0)) revert ZeroAddress();
        platformWallet = wallet_;
        emit PlatformWalletSet(wallet_);
    }

    // Creator takeovers are decided by the platform, not bought: there is no public application. The
    // new creator starts with no fee splits -- the previous creator's splits pay wallets they chose,
    // and a takeover shouldn't keep routing the creator share there. The token's vault follows the
    // new creator when one exists; a vault that can't be updated doesn't block the transfer.
    function transferPoolCreator(bytes32 poolId, address newCreator) external onlyOwner {
        PoolInfo storage info = pools[poolId];
        if (!info.registered) revert NotRegistered();
        if (newCreator == address(0)) revert ZeroAddress();

        address previousCreator = info.creator;
        info.creator = newCreator;

        if (_feeSplits[poolId].length > 0) {
            delete _feeSplits[poolId];
            emit FeeSplitsUpdated(poolId, new FeeSplit[](0));
        }

        try this._setVaultCreator(info.token, newCreator) {} catch {}

        emit CreatorTransferred(poolId, previousCreator, newCreator);
    }

    function _setVaultCreator(address token, address newCreator) external {
        if (msg.sender != address(this)) revert Unauthorized();
        address vault = IGenesisTokenVaultLookup(token).vault();
        if (vault == address(0)) revert NoVault();
        IGenesisVault(vault).setCreator(newCreator);
    }

    function setFeeSplits(bytes32 poolId, FeeSplit[] calldata splits_) external {
        if (pools[poolId].creator != msg.sender) revert NotCreator();
        if (splits_.length > MAX_FEE_SPLITS) revert TooManyFeeSplits();

        uint256 totalBps;
        for (uint256 i; i < splits_.length; ++i) {
            if (splits_[i].wallet == address(0)) revert ZeroAddress();
            totalBps += splits_[i].bps;
        }
        if (splits_.length > 0 && totalBps != BPS) revert InvalidFeeSplitBps();

        delete _feeSplits[poolId];
        for (uint256 i; i < splits_.length; ++i) {
            _feeSplits[poolId].push(splits_[i]);
        }
        emit FeeSplitsUpdated(poolId, splits_);
    }

    function getFeeSplits(bytes32 poolId) external view returns (FeeSplit[] memory) {
        return _feeSplits[poolId];
    }

    // ---------------------------------------------------------------- pool registration

    // Must be called by a launcher BEFORE the pool is initialized: beforeInitialize refuses any key
    // that isn't registered. Same signature as DuckHookV4.registerPool, so launchers call it the same
    // way; hookFeeBps_ is any rate up to MAX_HOOK_FEE_BPS, with 0 still meaning the 2% default.
    function registerPool(
        PoolKey calldata key, address token, address creator, uint256 hookFeeBps_,
        uint16 creatorBps_, uint16 vaultBps_, uint16 burnBps_
    ) external {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        if (hookFeeBps_ > MAX_HOOK_FEE_BPS) revert InvalidHookFeeBps();
        // Fully flexible: any three shares of the 70% vault/creator/burn remainder are allowed, as
        // long as they add up to exactly the whole thing. This single check also bounds each
        // individual share to [0, BPS], since all three are unsigned and must sum to exactly BPS.
        if (uint256(creatorBps_) + vaultBps_ + burnBps_ != BPS) revert InvalidVaultBps();
        if (creator == address(0)) revert ZeroAddress();
        // Pinned to this hook and the protocol's fee tier and tick spacing: the buyback in claimFees
        // rebuilds the key from those constants, and a pool registered under anything else would take
        // fees it could never spend on a buyback.
        if (key.hooks != address(this) || key.fee != POOL_FEE_TIER || key.tickSpacing != POOL_TICK_SPACING) {
            revert InvalidPoolKey();
        }
        if (token != key.currency0 && token != key.currency1) revert InvalidPoolKey();

        uint256 feeBps = hookFeeBps_ == 0 ? HOOK_FEE_DEFAULT_BPS : hookFeeBps_;
        bytes32 poolId = keccak256(abi.encode(key));
        if (pools[poolId].registered) revert AlreadyRegistered();
        bool tokenIsCurrency0 = key.currency0 == token;
        // Field-by-field, not a struct literal: with this many mixed-size fields the compiler's
        // synthesized clear-then-write routine can hit stack-too-deep even under via-IR.
        PoolInfo storage info = pools[poolId];
        info.token = token;
        info.quoteCurrency = tokenIsCurrency0 ? key.currency1 : key.currency0;
        // Read back rather than held in another local: this function sits at the via-IR stack limit.
        if (info.quoteCurrency == address(0)) revert InvalidPoolKey();
        info.tokenIsCurrency0 = tokenIsCurrency0;
        info.creator = creator;
        info.launchTimestamp = block.timestamp;
        info.registered = true;
        info.hookFeeBps = feeBps;
        info.creatorBps = creatorBps_;
        info.vaultBps = vaultBps_;
        info.burnBps = burnBps_;
        emit PoolRegistered(poolId, token, creator, feeBps);
    }

    // ---------------------------------------------------------------- oracle

    function setStateView(address stateView_) external onlyOwner {
        stateView = stateView_;
        emit StateViewSet(stateView_);
    }

    function setOracleDisabled(bytes32 poolId, bool disabled_) external onlyOwner {
        oracleDisabled[poolId] = disabled_;
        emit OracleDisabledSet(poolId, disabled_);
    }

    function setOraclePaused(bool paused_) external onlyOwner {
        oraclePaused = paused_;
        emit OraclePausedSet(paused_);
    }

    function _safeGetTick(bytes32 poolId) private view returns (bool ok, int24 tick) {
        address sv = stateView;
        if (sv == address(0)) return (false, 0);
        (bool success, bytes memory data) = sv.staticcall(abi.encodeWithSelector(IGenesisStateView.getSlot0.selector, poolId));
        if (!success || data.length < 128) return (false, 0);
        (, int24 t, , ) = abi.decode(data, (uint160, int24, uint24, uint24));
        return (true, t);
    }

    function poolLiquidity(bytes32 poolId) external view returns (uint128 liquidity, bool ok) {
        address sv = stateView;
        if (sv == address(0)) return (0, false);
        (bool success, bytes memory data) = sv.staticcall(abi.encodeWithSelector(IGenesisStateView.getLiquidity.selector, poolId));
        if (!success || data.length < 32) return (0, false);
        return (abi.decode(data, (uint128)), true);
    }

    function _updateOracle(bytes32 poolId) private {
        if (oraclePaused || oracleDisabled[poolId]) return;
        OracleMeta storage meta = oracleMeta[poolId];
        uint32 nowTs = uint32(block.timestamp);

        if (meta.lastTs == 0) {
            (bool ok, int24 tick) = _safeGetTick(poolId);
            if (!ok) return;
            meta.lastTick = tick;
            meta.lastTs = nowTs;
            _observations[poolId][0] = Observation({ts: nowTs, cumulative: 0});
            meta.index = 0;
            meta.count = 1;
            return;
        }

        uint32 elapsed = nowTs - meta.lastTs;
        if (elapsed == 0) return;

        (bool ok2, int24 tick2) = _safeGetTick(poolId);

        unchecked {
            meta.cumulative += int56(meta.lastTick) * int56(uint56(elapsed));
        }

        if (!ok2) {
            meta.lastTs = nowTs;
            return;
        }

        Observation storage last = _observations[poolId][meta.index];
        if (nowTs - last.ts >= ORACLE_PERIOD) {
            uint16 nextIndex = uint16((meta.index + 1) % ORACLE_CARDINALITY);
            _observations[poolId][nextIndex] = Observation({ts: nowTs, cumulative: meta.cumulative});
            meta.index = nextIndex;
            if (meta.count < ORACLE_CARDINALITY) meta.count++;
        }

        meta.lastTick = tick2;
        meta.lastTs = nowTs;
    }

    function observe(bytes32 poolId, uint32 secondsAgo) external view returns (int24 avgTick, bool valid) {
        OracleMeta memory meta = oracleMeta[poolId];
        if (meta.count == 0) return (0, false);
        uint32 nowTs = uint32(block.timestamp);

        int56 currentCumulative;
        unchecked {
            currentCumulative = meta.cumulative + int56(meta.lastTick) * int56(uint56(nowTs - meta.lastTs));
        }

        uint32 targetTs = nowTs - secondsAgo;
        Observation memory obs = _findObservationAtOrBefore(poolId, meta, targetTs);

        // _findObservationAtOrBefore clamps to the oldest observation on hand rather than signalling
        // "not enough history", which would hand a caller (DuckVault's borrow/liquidation pricing) a
        // much shorter, far more manipulable average still marked valid. Detect the clamp: a newer
        // observation than requested means the pool isn't tracked long enough yet.
        if (obs.ts > targetTs) return (0, false);

        uint32 elapsed = nowTs - obs.ts;
        if (elapsed == 0) return (0, false);
        int56 delta = currentCumulative - obs.cumulative;
        avgTick = int24(delta / int56(uint56(elapsed)));
        valid = true;
    }

    function _findObservationAtOrBefore(bytes32 poolId, OracleMeta memory meta, uint32 targetTs)
        private view returns (Observation memory)
    {
        uint16 count = meta.count;
        uint16 oldestActual = uint16((uint256(meta.index) + ORACLE_CARDINALITY - count + 1) % ORACLE_CARDINALITY);
        Observation memory oldest = _observations[poolId][oldestActual];
        if (targetTs <= oldest.ts) return oldest;

        uint256 lo = 0;
        uint256 hi = count - 1;
        while (lo < hi) {
            uint256 mid = (lo + hi + 1) / 2;
            uint16 actualIdx = uint16((uint256(oldestActual) + mid) % ORACLE_CARDINALITY);
            if (_observations[poolId][actualIdx].ts <= targetTs) {
                lo = mid;
            } else {
                hi = mid - 1;
            }
        }
        uint16 actualLo = uint16((uint256(oldestActual) + lo) % ORACLE_CARDINALITY);
        return _observations[poolId][actualLo];
    }

    // ---------------------------------------------------------------- pool lifecycle hooks

    // `sender` is deliberately not checked: launchers initialize through the PositionManager, so the
    // caller seen here is the PositionManager, which anyone can use. Registration is the gate -- only
    // a launcher can register a key, and only a registered key can be initialized.
    function beforeInitialize(address, PoolKey calldata key, uint160) external view onlyPoolManager returns (bytes4) {
        if (!pools[keccak256(abi.encode(key))].registered) revert NotRegistered();
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return this.afterInitialize.selector;
    }

    // Launchers add liquidity by calling modifyLiquidity themselves (LaunchRouting._mintFullRangeDirect),
    // so `sender` here is the launcher contract. Third argument is the real ModifyLiquidityParams
    // struct, not raw bytes -- the selector has to match exactly for the PoolManager's call to land.
    function beforeAddLiquidity(address sender, PoolKey calldata key, ModifyLiquidityParams calldata, bytes calldata)
        external view onlyPoolManager returns (bytes4)
    {
        if (!isLauncher[sender]) revert NotLauncher();
        if (!pools[keccak256(abi.encode(key))].registered) revert NotRegistered();
        return this.beforeAddLiquidity.selector;
    }

    // Liquidity is added once by the launching contract and meant to stay locked forever. Blocking
    // removal here means that guarantee doesn't rest on our own contracts merely never exposing a way
    // to do it -- it holds for every pool on this hook, whoever calls modifyLiquidity.
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) {
        revert LiquidityRemovalDisabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.afterDonate.selector;
    }

    // ---------------------------------------------------------------- swap fees

    // v4-core's BeforeSwapDelta encoding: specified delta in the upper 128 bits, unspecified in the
    // lower. Reimplemented rather than imported, same convention as PoolKey/SwapParams here.
    function _packBeforeSwapDelta(int128 specified, int128 unspecified) private pure returns (int256 packed) {
        assembly ("memory-safe") {
            packed := or(shl(128, specified), and(0xffffffffffffffffffffffffffffffff, unspecified))
        }
    }

    // The fee owed on a quote amount at `bps`. An exact-input amount is the whole quote leg (a buy's
    // spend, a sell's payout before fee), so the fee is a share of it. An exact-output amount is only
    // what the trader ends up with, and the fee is settled on top, so it's grossed up to the leg it
    // implies -- charging the named amount directly would let exact-output trades pay (1 - rate) of
    // the fee on the same trade. bps never reaches BPS (capped at MAX_HOOK_FEE_BPS), so the divisor
    // stays positive.
    function _feeFor(uint256 quoteAmount, uint256 bps, bool exactOutput) private pure returns (uint256) {
        return exactOutput
            ? (quoteAmount * bps) / (BPS - bps)
            : (quoteAmount * bps) / BPS;
    }

    // Whether the quote currency is the swap's specified side (its amount fixed by the trader): the
    // input of an exact-input swap, the output of an exact-output one. That is exact-input buys and
    // exact-output sells; the other two cases have the quote as the unspecified side.
    function _quoteIsSpecified(bool tokenIsCurrency0, SwapParams calldata params) private pure returns (bool) {
        bool specifiedIsCurrency0 = (params.amountSpecified < 0) == params.zeroForOne;
        return specifiedIsCurrency0 != tokenIsCurrency0;
    }

    function _abs(int256 x) private pure returns (uint256) {
        return x < 0 ? uint256(-x) : uint256(x);
    }

    function _toInt128(uint256 x) private pure returns (int128) {
        if (x > uint256(uint128(type(int128).max))) revert FeeOverflow();
        return int128(int256(x));
    }

    // Quote is the specified side: the fee is known before the swap, so it's taken now and the swap's
    // specified amount is adjusted by the same via the returned delta. Exact input shrinks the quote
    // that actually trades; exact output makes the pool pay out the fee on top of what the trader
    // receives.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external onlyPoolManager returns (bytes4, int256, uint24)
    {
        bytes32 poolId = keccak256(abi.encode(key));
        PoolInfo storage info = pools[poolId];
        if (!info.registered || !_quoteIsSpecified(info.tokenIsCurrency0, params)) {
            return (this.beforeSwap.selector, int256(0), 0);
        }

        uint256 fee = _feeFor(_abs(params.amountSpecified), info.hookFeeBps, params.amountSpecified > 0);
        if (fee == 0) return (this.beforeSwap.selector, int256(0), 0);

        accruedFees[poolId] += fee;
        IGenesisPoolManagerTake(msg.sender).take(info.quoteCurrency, address(this), fee);
        return (this.beforeSwap.selector, _packBeforeSwapDelta(_toInt128(fee), 0), 0);
    }

    // `delta` is the pool's own movement for the swap (after beforeSwap's adjustment, before this
    // hook's return value is applied).
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, int256 delta, bytes calldata)
        external onlyPoolManager returns (bytes4, int128)
    {
        bytes32 poolId = keccak256(abi.encode(key));
        PoolInfo storage info = pools[poolId];
        if (!info.registered) return (this.afterSwap.selector, int128(0));

        _updateOracle(poolId);

        int128 amount0Delta = int128(delta >> 128);
        int128 amount1Delta = int128(delta);
        (int128 tokenDelta, int128 quoteDelta) = info.tokenIsCurrency0
            ? (amount0Delta, amount1Delta)
            : (amount1Delta, amount0Delta);
        uint256 quoteMoved = _abs(quoteDelta);
        bool exactOutput = params.amountSpecified > 0;

        if (_quoteIsSpecified(info.tokenIsCurrency0, params)) {
            // beforeSwap charged the fee on the full specified quote amount. A price limit that stops
            // the swap short would leave the trader paying fee on quote that never traded, so only a
            // complete fill is accepted: the pool moving exactly the post-fee (exact input) or
            // fee-inclusive (exact output) amount.
            uint256 specified = _abs(params.amountSpecified);
            uint256 charged = _feeFor(specified, info.hookFeeBps, exactOutput);
            uint256 fullFill = exactOutput ? specified + charged : specified - charged;
            if (quoteMoved != fullFill) revert PartialFillRejected();
            return (this.afterSwap.selector, int128(0));
        }

        // Quote is the unspecified side: charged on what actually moved, so a partial fill simply pays
        // proportionally. A swap that moved neither side traded against no liquidity and would only
        // write a price nobody paid for, so it's refused.
        if (quoteMoved == 0 && tokenDelta == 0) revert EmptyFillRejected();

        uint256 fee = _feeFor(quoteMoved, info.hookFeeBps, exactOutput);
        if (fee == 0) return (this.afterSwap.selector, int128(0));

        accruedFees[poolId] += fee;
        IGenesisPoolManagerTake(msg.sender).take(info.quoteCurrency, address(this), fee);
        return (this.afterSwap.selector, _toInt128(fee));
    }

    // ---------------------------------------------------------------- fee payout

    // Permissionless and purely manual -- nothing triggers it automatically. DuckKeeper calls it on
    // a schedule in practice but holds no special role. Platform and holder carve-outs come off the
    // ORIGINAL total (not chained remainders) so the cuts sum to exactly 100%: 25/5/70.
    function claimFees(bytes32 poolId) external {
        PoolInfo storage info = pools[poolId];
        if (!info.registered) revert NotRegistered();

        uint256 amount = accruedFees[poolId];
        if (amount > 0) {
            accruedFees[poolId] = 0;
            uint256 afterPlatformCut = _payPlatformCut(info.quoteCurrency, amount, info.creator);
            uint256 afterHolderCut = _carveHolderReward(poolId, info.token, info.quoteCurrency, amount, afterPlatformCut);

            // creatorBps + vaultBps + burnBps sum to 100% of the remainder (enforced at
            // registerPool), so what's left after the vault and burn shares IS the creator's.
            // Computed as a remainder so division dust lands with the creator instead of vanishing,
            // and a failed vault deposit rolls into their payout via _carveVaultCut's fallback.
            uint256 creatorAmount = _carveVaultCut(poolId, info.token, info.quoteCurrency, info.vaultBps, afterHolderCut);
            uint256 burnCut = (afterHolderCut * info.burnBps) / BPS;
            if (burnCut > 0) {
                creatorAmount -= burnCut;
                _buyAndBurn(poolId, info.quoteCurrency, info.token, burnCut);
            }
            _payCreator(poolId, info.creator, info.quoteCurrency, creatorAmount);
        }
        emit FeesClaimed(poolId, amount);
    }

    // Spends burnBps of the remainder buying the token back from its own pool and burning it.
    // Deliberately not try/catch'd like the holder/vault cuts: those fall back to the creator, but a
    // failed buyback has no fallback once carved out, and swallowing it would strand the currency
    // here unrecoverably. Reverting the whole claim leaves accruedFees intact so anyone can retry.
    function _buyAndBurn(bytes32 poolId, address quoteCurrency, address token, uint256 amount) private {
        if (amount == 0) return;
        uint256 burned = _swapForBurn(quoteCurrency, token, amount);
        if (burned > 0) _pay(token, DEAD, burned);
        emit BuybackBurned(poolId, amount, burned);
    }

    // Minimal hook-specific V4 swap for the buyback -- always against THIS pool (hook = itself, fee
    // and tickSpacing fixed protocol-wide, enforced at registration). Exact input with an open price
    // limit against a full-range position, so it fills completely and passes afterSwap's fill check.
    function _swapForBurn(address currencyIn, address currencyOut, uint256 amountIn) private returns (uint256 amountOut) {
        _cbExpected = poolManager;
        bytes memory result = IGenesisPoolManagerSwap(poolManager).unlock(abi.encode(currencyIn, currencyOut, amountIn));
        _cbExpected = address(0);
        amountOut = abi.decode(result, (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        if (_cbExpected == address(0) || msg.sender != _cbExpected) revert Unauthorized();
        (address currencyIn, address currencyOut, uint256 amountIn) = abi.decode(data, (address, address, uint256));

        bool zeroForOne = currencyIn < currencyOut;
        PoolKey memory key = PoolKey({
            currency0:   zeroForOne ? currencyIn  : currencyOut,
            currency1:   zeroForOne ? currencyOut : currencyIn,
            fee:         POOL_FEE_TIER,
            tickSpacing: POOL_TICK_SPACING,
            hooks:       address(this)
        });
        int256 delta = IGenesisPoolManagerSwap(msg.sender).swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT + 1 : MAX_SQRT_PRICE_LIMIT - 1
            }),
            ""
        );
        uint256 outAmount = zeroForOne ? uint256(uint128(int128(delta))) : uint256(uint128(int128(delta >> 128)));

        IGenesisPoolManagerSwap(msg.sender).sync(currencyIn);
        // currencyIn here is the pool's quote currency -- an arbitrary token, not necessarily a
        // strict-bool-returning ERC20 -- so this reuses _pay rather than a typed transfer() call.
        _pay(currencyIn, msg.sender, amountIn);
        IGenesisPoolManagerSwap(msg.sender).settle();
        IGenesisPoolManagerSwap(msg.sender).take(currencyOut, address(this), outAmount);
        return abi.encode(outAmount);
    }

    // Pays a fixed, owner-configured wallet rather than a looked-up contract that could fail for
    // operational reasons, so it reverts via _pay instead of failing forward to the creator -- a
    // misconfigured platformWallet should block claims until fixed, not hand the creator its cut.
    function _payPlatformCut(address currency, uint256 amount, address creator) private returns (uint256 remaining) {
        if (platformWallet == address(0)) revert ZeroAddress();

        // msg.sender, not tx.origin: the contract doing the work of triggering the claim earns the
        // reward. The creator gets no bonus -- they receive their own cut regardless of who calls.
        bool rewardClaimer = msg.sender != creator;
        uint256 platformBps = rewardClaimer ? PLATFORM_FEE_BPS - CLAIMER_REWARD_BPS : PLATFORM_FEE_BPS;
        uint256 platformCut = (amount * platformBps) / BPS;
        _pay(currency, platformWallet, platformCut);
        remaining = amount - platformCut;

        if (rewardClaimer) {
            uint256 claimerCut = (amount * CLAIMER_REWARD_BPS) / BPS;
            _pay(currency, msg.sender, claimerCut);
            remaining -= claimerCut;
        }
    }

    // Fails safe to the creator like _carveVaultCut, so a bad token implementation can never brick
    // fee claiming. `totalAmount` is the ORIGINAL total (the flat 5% is computed off it);
    // `currentRemaining` is what's left after the platform cut, and what's paid out from/returned.
    function _carveHolderReward(bytes32 poolId, address token, address currency, uint256 totalAmount, uint256 currentRemaining)
        private returns (uint256 remaining)
    {
        remaining = currentRemaining;
        uint256 cut = (totalAmount * HOLDER_REWARD_BPS) / BPS;
        if (cut == 0) return remaining;

        // approve() and depositHolderReward() share one external self-call so a revert from either step
        // is caught rather than bricking the claim -- and since nothing committed, there's no dangling
        // allowance to clear.
        try this._depositHolderRewardErc20(token, currency, cut) {
            remaining = currentRemaining - cut;
        } catch {
            emit HolderRewardSkipped(poolId, cut);
        }
    }

    function _depositHolderRewardErc20(address token, address currency, uint256 cut) external {
        if (msg.sender != address(this)) revert Unauthorized();
        if (!IGenesisERC20(currency).approve(token, cut)) revert TransferFailed();
        IGenesisTokenReward(token).depositHolderReward(cut);
    }

    function _carveVaultCut(bytes32 poolId, address token, address currency, uint16 vaultBps, uint256 amount)
        private returns (uint256 creatorAmount)
    {
        creatorAmount = amount;
        if (vaultBps == 0) return creatorAmount;

        uint256 vaultCut = (amount * vaultBps) / BPS;
        if (vaultCut == 0) return creatorAmount;

        try this._depositVaultCut(token, currency, vaultCut) {
            creatorAmount = amount - vaultCut;
        } catch {
            emit VaultCutSkipped(poolId, vaultCut);
        }
    }

    function _depositVaultCut(address token, address currency, uint256 vaultCut) external {
        if (msg.sender != address(this)) revert Unauthorized();
        address vault = IGenesisTokenVaultLookup(token).vault();
        if (vault == address(0)) revert NoVault();

        if (!IGenesisERC20(currency).approve(vault, vaultCut)) revert TransferFailed();
        IGenesisVault(vault).depositFees(vaultCut);
    }

    function _payCreator(bytes32 poolId, address creator, address currency, uint256 amount) private {
        // Memory snapshot, not a live storage pointer: _pay makes an external call per split, and
        // the creator can reenter via setFeeSplits (gated only on being the creator -- exactly who's
        // mid-payout here). A storage reference would let a reentrant delete+repopulate leave this
        // loop's cached `len` stale and panic on an out-of-bounds read. A memory copy can't.
        FeeSplit[] memory splits = _feeSplits[poolId];
        if (splits.length == 0) {
            _pay(currency, creator, amount);
            return;
        }
        uint256 len = splits.length;
        uint256 remaining = amount;
        for (uint256 i; i < len; ++i) {
            uint256 cut = i == len - 1 ? remaining : (amount * splits[i].bps) / BPS;
            remaining -= cut;
            _pay(currency, splits[i].wallet, cut);
        }
    }

    function _pay(address currency, address to, uint256 amount) private {
        if (amount == 0) return;
        // Gas-capped through a low-level call (a typed call takes no gas option): claimFees is
        // permissionless, and 100k covers a normal transfer with a cold balance slot -- Arc's USDC
        // transfer to a fresh account measured about 54k.
        (bool ok, bytes memory ret) = currency.call{gas: 100_000}(
            abi.encodeWithSelector(IGenesisERC20.transfer.selector, to, amount)
        );
        if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) revert TransferFailed();
    }
}
