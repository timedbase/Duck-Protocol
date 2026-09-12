// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckHookV4

import {PoolKey, SwapParams, ModifyLiquidityParams} from "duck-lib/LaunchRouting.sol";

interface IPoolManagerSwapMinimal {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

interface IPoolManagerMinimal {
    function take(address currency, address to, uint256 amount) external;
}

interface IERC20Minimal {
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IWETH9Hook {
    function deposit() external payable;
}

interface ITokenVaultLookup {
    function vault() external view returns (address);
}

interface IDuckVaultDeposit {
    function depositFees(uint256 amount) external;
    function setCreator(address newCreator) external;
}

interface IDuckTokenReward {
    function depositHolderReward(uint256 amount) external payable;
}

interface IStateView {
    function getSlot0(bytes32 poolId)
        external view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

contract DuckHookV4 {

    error ZeroAddress();
    error NotOwner();
    error NotLauncher();
    error NotPoolManager();
    error AlreadyRegistered();
    error NotRegistered();
    error SameBlockSwap();
    error TransferFailed();
    error InsufficientCTOFee();
    error NoCTOApplication();
    error CTOApplicationPending();
    error NotCreator();
    error TooManyFeeSplits();
    error InvalidFeeSplitBps();
    error InvalidHookFeeBps();
    error InvalidVaultBps();
    error Unauthorized();
    error NoVault();
    error ExactOutputNotSupported();
    error InsufficientBuybackOutput();
    error LiquidityRemovalDisabled();

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

    // Mined into the hook's own address. 0xC4 (BEFORE_SWAP | AFTER_SWAP | AFTER_SWAP_RETURNS_DELTA)
    // + BEFORE_SWAP_RETURNS_DELTA (bit 3) so the PoolManager honors beforeSwap's returned delta at
    // all, + BEFORE_REMOVE_LIQUIDITY (bit 9) -- that bit is what makes beforeRemoveLiquidity's
    // revert enforceable; without it PoolManager never calls the hook and liquidity could be pulled.
    uint160 public constant REQUIRED_PERMISSIONS = 0x2CC;
    uint160 public constant PERMISSION_MASK      = 0x3FFF;

    uint256 public constant HOOK_FEE_DEFAULT_BPS = 200;
    uint256 private constant BPS                = 10_000;
    uint256 public constant MAX_FEE_SPLITS      = 5;

    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // Protocol-wide, not per-pool: every pool this protocol mints uses a 0% native fee tier.
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

    address public weth;

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

    mapping(bytes32 => PoolInfo)                   public pools;
    mapping(bytes32 => mapping(address => uint256)) private _lastSwapBlock;
    mapping(bytes32 => uint256)                     public accruedFees;

    // Fixed protocol-wide, computed off the ORIGINAL total (not a shrinking remainder) so the shares
    // sum to exactly 100% regardless of order: 25% platform, 5% holders, 70% vault/creator.
    uint256 public constant PLATFORM_FEE_BPS  = 2500;
    uint256 public constant HOLDER_REWARD_BPS = 500;

    // Keeper incentive carved out of the PLATFORM's share (25% -> 24%), never the holder/vault/
    // creator shares. Paid to whoever calls claimFees unless that's the pool's own creator, who
    // already gets a cut regardless -- this is what makes permissionless claiming worth triggering.
    uint256 public constant CLAIMER_REWARD_BPS = 100;

    struct CTOApplication {
        address applicant;
        address newCreator;
        uint256 paid;
    }

    uint256 public ctoFee = 0.1 ether;
    mapping(bytes32 => CTOApplication) public ctoApplications;

    event PoolRegistered(bytes32 indexed poolId, address indexed token, address indexed creator, uint256 hookFeeBps);
    event FeesClaimed(bytes32 indexed poolId, uint256 amount);
    event BuybackBurned(bytes32 indexed poolId, uint256 quoteSpent, uint256 tokensBurned);
    event HolderRewardSkipped(bytes32 indexed poolId, uint256 amount);
    event CTOFeeSet(uint256 fee);
    event PlatformWalletSet(address indexed wallet);
    event WethSet(address indexed weth);
    event VaultCutSkipped(bytes32 indexed poolId, uint256 amount);
    event FeeSplitsUpdated(bytes32 indexed poolId, FeeSplit[] splits);
    event CTOApplied(bytes32 indexed poolId, address indexed applicant, address newCreator, uint256 paid);
    event CTOApproved(bytes32 indexed poolId, address newCreator);
    event CTORejected(bytes32 indexed poolId, address indexed applicant);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event LauncherAdded(address indexed launcher);
    event LauncherRemoved(address indexed launcher);

    modifier onlyOwner() { if (msg.sender != owner) revert NotOwner(); _; }

    constructor(address poolManager_) {
        if (poolManager_ == address(0)) revert ZeroAddress();
        poolManager = poolManager_;
        owner       = msg.sender;
    }

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

    function setCTOFee(uint256 fee_) external onlyOwner {
        ctoFee = fee_;
        emit CTOFeeSet(fee_);
    }

    function setPlatformWallet(address wallet_) external onlyOwner {
        if (wallet_ == address(0)) revert ZeroAddress();
        platformWallet = wallet_;
        emit PlatformWalletSet(wallet_);
    }

    function setWeth(address weth_) external onlyOwner {
        if (weth_ == address(0)) revert ZeroAddress();
        weth = weth_;
        emit WethSet(weth_);
    }

    function applyForCTO(bytes32 poolId, address newCreator) external payable {
        if (!pools[poolId].registered) revert NotRegistered();
        if (newCreator == address(0)) revert ZeroAddress();
        if (platformWallet == address(0)) revert ZeroAddress();
        if (msg.value < ctoFee) revert InsufficientCTOFee();
        if (ctoApplications[poolId].newCreator != address(0)) revert CTOApplicationPending();
        ctoApplications[poolId] = CTOApplication({applicant: msg.sender, newCreator: newCreator, paid: msg.value});
        (bool ok,) = platformWallet.call{value: msg.value}("");
        if (!ok) revert TransferFailed();
        emit CTOApplied(poolId, msg.sender, newCreator, msg.value);
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

    function approveCTO(bytes32 poolId) external onlyOwner {
        CTOApplication memory app = ctoApplications[poolId];
        if (app.newCreator == address(0)) revert NoCTOApplication();
        pools[poolId].creator = app.newCreator;
        delete ctoApplications[poolId];

        try this._setVaultCreator(pools[poolId].token, app.newCreator) {} catch {}

        emit CTOApproved(poolId, app.newCreator);
    }

    function _setVaultCreator(address token, address newCreator) external {
        if (msg.sender != address(this)) revert Unauthorized();
        address vault = ITokenVaultLookup(token).vault();
        if (vault == address(0)) revert NoVault();
        IDuckVaultDeposit(vault).setCreator(newCreator);
    }

    function rejectCTO(bytes32 poolId) external onlyOwner {
        CTOApplication memory app = ctoApplications[poolId];
        if (app.newCreator == address(0)) revert NoCTOApplication();
        delete ctoApplications[poolId];
        emit CTORejected(poolId, app.applicant);
    }

    function registerPool(
        PoolKey calldata key, address token, address creator, uint256 hookFeeBps_,
        uint16 creatorBps_, uint16 vaultBps_, uint16 burnBps_
    ) external {
        if (!isLauncher[msg.sender]) revert NotLauncher();
        if (!_isValidHookFeeBps(hookFeeBps_)) revert InvalidHookFeeBps();
        // Fully flexible: any three shares of the 70% vault/creator/burn remainder are allowed, as
        // long as they add up to exactly the whole thing. This single check also bounds each
        // individual share to [0, BPS], since all three are unsigned and must sum to exactly BPS.
        if (uint256(creatorBps_) + vaultBps_ + burnBps_ != BPS) revert InvalidVaultBps();
        uint256 feeBps = hookFeeBps_ == 0 ? HOOK_FEE_DEFAULT_BPS : hookFeeBps_;
        bytes32 poolId = keccak256(abi.encode(key));
        if (pools[poolId].registered) revert AlreadyRegistered();
        bool tokenIsCurrency0 = key.currency0 == token;
        // Field-by-field, not a struct literal: with this many mixed-size fields the compiler's
        // synthesized clear-then-write routine can hit stack-too-deep even under via-IR.
        PoolInfo storage info = pools[poolId];
        info.token = token;
        info.quoteCurrency = tokenIsCurrency0 ? key.currency1 : key.currency0;
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

    // 0 is a "use the 2% default" sentinel (see registerPool below), not a genuine zero-fee option --
    // an explicit choice must land in the real 2%-10% creator-configurable range.
    function _isValidHookFeeBps(uint256 bps) private pure returns (bool) {
        return bps == 0 || bps == 200 || bps == 400 || bps == 600 || bps == 800 || bps == 1000;
    }

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
        (bool success, bytes memory data) = sv.staticcall(abi.encodeWithSelector(IStateView.getSlot0.selector, poolId));
        if (!success || data.length < 128) return (false, 0);
        (, int24 t, , ) = abi.decode(data, (uint160, int24, uint24, uint24));
        return (true, t);
    }

    function poolLiquidity(bytes32 poolId) external view returns (uint128 liquidity, bool ok) {
        address sv = stateView;
        if (sv == address(0)) return (0, false);
        (bool success, bytes memory data) = sv.staticcall(abi.encodeWithSelector(IStateView.getLiquidity.selector, poolId));
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

    function beforeInitialize(address, PoolKey calldata, uint160) external pure returns (bytes4) {
        return this.beforeInitialize.selector;
    }

    function afterInitialize(address, PoolKey calldata, uint160, int24) external pure returns (bytes4) {
        return this.afterInitialize.selector;
    }

    // Third argument is the real ModifyLiquidityParams struct, not raw bytes -- the signature has to
    // match exactly now that BEFORE_REMOVE_LIQUIDITY is enabled, or PoolManager's call lands on an
    // unrecognized selector instead of the function body.
    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) {
        return this.beforeAddLiquidity.selector;
    }

    // Liquidity is added once by the launching contract and meant to stay locked forever (see
    // LaunchRouting._mintFullRangeDirect). Blocking removal here means that guarantee doesn't rest
    // on our own contracts merely never exposing a way to do it -- it holds for every pool on this
    // hook, whoever calls modifyLiquidity. Requires BEFORE_REMOVE_LIQUIDITY in REQUIRED_PERMISSIONS.
    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata) external pure returns (bytes4) {
        revert LiquidityRemovalDisabled();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.beforeDonate.selector;
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.afterDonate.selector;
    }

    // v4-core's BeforeSwapDelta encoding: specified delta in the upper 128 bits, unspecified in the
    // lower. Reimplemented rather than imported, same convention as PoolKey/SwapParams here.
    function _packBeforeSwapDelta(int128 specified, int128 unspecified) private pure returns (int256 packed) {
        assembly ("memory-safe") {
            packed := or(shl(128, specified), and(0xffffffffffffffffffffffffffffffff, unspecified))
        }
    }

    // Sell-side fee stays in afterSwap (skims the quote OUTPUT once known). Buy-side has to live
    // here: the quote is the swap's INPUT, already settled by the time afterSwap runs, so taxing it
    // means take()ing the fee now and shrinking the swapped amount by the same via the returned
    // delta -- accounting nets out exactly as if a smaller trade happened.
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external returns (bytes4, int256, uint24)
    {
        if (msg.sender != poolManager) revert NotPoolManager();
        bytes32 poolId = keccak256(abi.encode(key));
        PoolInfo storage info = pools[poolId];
        if (!info.registered) return (this.beforeSwap.selector, int256(0), 0);

        // tx.origin, not `sender`: swaps route through a shared Universal Router, so `sender` is the
        // same address for every user -- keying on it would rate-limit the whole platform to one
        // swap per pool per block instead of one per actual trader.
        if (_lastSwapBlock[poolId][tx.origin] == block.number) revert SameBlockSwap();
        _lastSwapBlock[poolId][tx.origin] = block.number;

        bool isBuy = info.tokenIsCurrency0 ? !params.zeroForOne : params.zeroForOne;
        if (!isBuy) return (this.beforeSwap.selector, int256(0), 0);

        // Every swap this platform's router builds is exact-input. Exact-output's required input
        // isn't known pre-trade, so reject it on a registered pool rather than tax it wrongly. Sells
        // are unaffected either way (afterSwap taxes realized output regardless).
        if (params.amountSpecified > 0) revert ExactOutputNotSupported();

        uint256 feeCut = uint256(-params.amountSpecified) * info.hookFeeBps / BPS;
        if (feeCut == 0) return (this.beforeSwap.selector, int256(0), 0);

        accruedFees[poolId] += feeCut;
        IPoolManagerMinimal(msg.sender).take(info.quoteCurrency, address(this), feeCut);
        return (this.beforeSwap.selector, _packBeforeSwapDelta(int128(int256(feeCut)), 0), 0);
    }

    function afterSwap(address, PoolKey calldata key, SwapParams calldata, int256 delta, bytes calldata)
        external returns (bytes4, int128)
    {
        if (msg.sender != poolManager) revert NotPoolManager();
        bytes32 poolId = keccak256(abi.encode(key));
        PoolInfo storage info = pools[poolId];
        if (!info.registered) return (this.afterSwap.selector, int128(0));

        _updateOracle(poolId);

        int128 amount0Delta = int128(delta >> 128);
        int128 amount1Delta = int128(delta);
        (int128 tokenDelta, int128 quoteDelta) = info.tokenIsCurrency0
            ? (amount0Delta, amount1Delta)
            : (amount1Delta, amount0Delta);

        bool isSell = tokenDelta < 0 && quoteDelta > 0;
        if (!isSell) return (this.afterSwap.selector, int128(0));

        uint256 feeCut = uint256(uint128(quoteDelta)) * info.hookFeeBps / BPS;
        if (feeCut == 0) return (this.afterSwap.selector, int128(0));

        accruedFees[poolId] += feeCut;
        IPoolManagerMinimal(msg.sender).take(info.quoteCurrency, address(this), feeCut);
        return (this.afterSwap.selector, int128(int256(feeCut)));
    }

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

    receive() external payable {}

    // Spends burnBps of the remainder buying the token back from its own pool and burning it.
    // Deliberately not try/catch'd like the holder/vault cuts: those fall back to the creator, but a
    // failed buyback has no fallback once carved out, and swallowing it would strand the currency
    // here unrecoverably. Reverting the whole claim leaves accruedFees intact so anyone can retry.
    function _buyAndBurn(bytes32 poolId, address quoteCurrency, address token, uint256 amount) private {
        if (amount == 0) return;
        uint256 burned = _swapForBurn(quoteCurrency, token, amount);
        // Reuses _pay (below) rather than a typed transfer() call, same as every other payout in this
        // file -- token here is always this protocol's own DuckToken, but consistency costs nothing.
        if (burned > 0) _pay(token, DEAD, burned);
        emit BuybackBurned(poolId, amount, burned);
    }

    // Minimal hook-specific V4 swap for the buyback -- always against THIS pool (hook = itself, fee
    // and tickSpacing fixed protocol-wide), so none of LaunchRouting's multi-route machinery applies.
    // Inheriting that abstract contract was tried and dropped: it made DuckHookV4 big enough to hit
    // stack-too-deep wherever it's embedded via a typed `new DuckHookV4(...)` expression.
    function _swapForBurn(address currencyIn, address currencyOut, uint256 amountIn) private returns (uint256 amountOut) {
        _cbExpected = poolManager;
        bytes memory result = IPoolManagerSwapMinimal(poolManager).unlock(abi.encode(currencyIn, currencyOut, amountIn));
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
        int256 delta = IPoolManagerSwapMinimal(msg.sender).swap(
            key,
            SwapParams({
                zeroForOne:        zeroForOne,
                amountSpecified:   -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? MIN_SQRT_PRICE_LIMIT + 1 : MAX_SQRT_PRICE_LIMIT - 1
            }),
            ""
        );
        uint256 outAmount = zeroForOne ? uint256(uint128(int128(delta))) : uint256(uint128(int128(delta >> 128)));

        if (currencyIn == address(0)) {
            IPoolManagerSwapMinimal(msg.sender).settle{value: amountIn}();
        } else {
            IPoolManagerSwapMinimal(msg.sender).sync(currencyIn);
            // currencyIn here is the pool's quote currency -- an arbitrary, permissionlessly chosen
            // token, not necessarily a strict-bool-returning ERC20 -- so this reuses _pay (below)
            // rather than a typed transfer() call that could revert on a non-conforming token.
            _pay(currencyIn, msg.sender, amountIn);
            IPoolManagerSwapMinimal(msg.sender).settle();
        }
        IPoolManagerSwapMinimal(msg.sender).take(currencyOut, address(this), outAmount);
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

        if (currency == address(0)) {
            try IDuckTokenReward(token).depositHolderReward{value: cut}(cut) {
                remaining = currentRemaining - cut;
            } catch {
                emit HolderRewardSkipped(poolId, cut);
            }
        } else {
            // approve() and depositHolderReward() share one external self-call (same shape as
            // _depositVaultCut) so a revert from either step is caught rather than bricking the
            // claim -- and since nothing committed, there's no dangling allowance to clear.
            try this._depositHolderRewardErc20(token, currency, cut) {
                remaining = currentRemaining - cut;
            } catch {
                emit HolderRewardSkipped(poolId, cut);
            }
        }
    }

    function _depositHolderRewardErc20(address token, address currency, uint256 cut) external {
        if (msg.sender != address(this)) revert Unauthorized();
        if (!IERC20Minimal(currency).approve(token, cut)) revert TransferFailed();
        IDuckTokenReward(token).depositHolderReward(cut);
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
        address vault = ITokenVaultLookup(token).vault();
        if (vault == address(0)) revert NoVault();

        address depositCurrency = currency;
        if (currency == address(0)) {
            if (weth == address(0)) revert ZeroAddress();
            IWETH9Hook(weth).deposit{value: vaultCut}();
            depositCurrency = weth;
        }
        if (!IERC20Minimal(depositCurrency).approve(vault, vaultCut)) revert TransferFailed();
        IDuckVaultDeposit(vault).depositFees(vaultCut);
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
        if (currency == address(0)) {
            // Gas-capped: `to` is the creator or a wallet they configured, not something this
            // contract controls, and claimFees is permissionless -- an expensive non-reverting
            // fallback would otherwise inflate the caller's gas without bound. 30k covers a plain
            // receive()/simple bookkeeping. Failure still reverts; only the gas is bounded.
            (bool ok,) = to.call{value: amount, gas: 30_000}("");
            if (!ok) revert TransferFailed();
        } else {
            // Same reasoning as the native path -- currency could be ERC777-style with a recipient
            // hook; capped via a low-level call since a typed call takes no gas option. 100k covers
            // a normal transfer (cold balance slot included) plus a legitimate simple hook.
            (bool ok, bytes memory ret) = currency.call{gas: 100_000}(
                abi.encodeWithSelector(IERC20Minimal.transfer.selector, to, amount)
            );
            if (!ok || ret.length < 32 || !abi.decode(ret, (bool))) revert TransferFailed();
        }
    }
}
