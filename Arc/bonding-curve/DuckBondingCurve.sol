// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckBondingCurve (Arc)
//
// Curves on Arc are quoted in an allowlisted ERC-20, USDC by default, never raw native. Native USDC and the
// USDC ERC-20 are one balance there: buyWithNative and sellForNative convert between them without a swap.

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";
import {LaunchRouting, Route} from "duck-lib/LaunchRouting.sol";
import {ARC_USDC, requireArcChain} from "duck-lib/ArcChain.sol";
import {V4Math} from "duck-lib/V4Math.sol";
import {V4Minting} from "duck-lib/V4Minting.sol";
import {BondingCurveMigration} from "duck-lib/BondingCurveMigration.sol";
import {BondingCurveMath} from "duck-lib/BondingCurveMath.sol";
import {TokenConfig, FeeSplit} from "duck-lib/DuckTypes.sol";
import {SupplyTiers} from "duck-lib/SupplyTiers.sol";

interface IERC20Min {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
}

interface IDuckVaultFactoryLocal {
    function createVault(address token, uint8 tokenDecimals, address creator_) external returns (address vault);
}

interface ITokenInit {
    function initToken(
        string memory name_, string memory symbol_, uint256 totalSupply_,
        bool lockUntilUnlock_, string memory metaURI_,
        address hook_, address currency_, address poolManager_
    ) external;
}

contract DuckBondingCurve is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, LaunchRouting {

    struct Alloc {
        uint256 supply;
        uint256 liqTokens;
        uint256 bcTokens;
    }

    struct BaseParams {
        string       name;
        string       symbol;
        uint8        supplyTier;
        uint256      curveBps;
        uint256      liquidityBps;
        address      quoteToken;
        uint256      startVirtualQuote;
        uint256      migrationTargetQuote;
        uint256      earlyBuyAmount;
        uint256      hookFeeBps;
        // Fully flexible three-way split of the 70% vault/creator/burn remainder (see
        // DuckHookV4.claimFees) -- must sum to exactly BPS_DENOM.
        uint16       creatorBps;
        uint16       vaultBps;
        uint16       burnBps;
        string       metaURI;
        bytes32      salt;
    }

    uint256 private constant BPS_DENOM          = 10_000;
    uint256 public constant MAX_FEE_SPLITS      =      5;
    uint16  public constant VANITY_SUFFIX       = 0x8888;
    address private constant DEAD               = 0x000000000000000000000000000000000000dEaD;

    // No native pool fee -- the creator-chosen 2-10% hook fee is the sole post-migration trading
    // fee (see DuckHookV4.claimFees). Migrated LP positions go to DEAD rather than a locker, since a
    // 0% pool fee leaves a locker nothing to claim.
    uint24 private constant V4_FEE_TIER  = 0;
    int24  private constant V4_TICK_SPACING = 200;

    uint256 private constant _NOT_ENTERED = 1;
    uint256 private constant _ENTERED     = 2;

    address public tokenImpl;
    address public vaultFactory;

    address public v4PositionManager;
    address public v4Singleton;
    address public v4Hook;

    mapping(address => bool) public quoteTokenAllowed;

    uint256 public minCurveBps;
    uint256 public minLiquidityBps;

    address public platformWallet;
    uint256 public creationFee;

    address public platformToken;

    mapping(address => TokenConfig) private tokens;

    function getTokenConfig(address token) external view returns (TokenConfig memory) {
        return tokens[token];
    }
    address[] public allTokens;
    mapping(address => address[]) private _tokensByCreator;
    mapping(address => FeeSplit[]) private _feeSplits;

    // Per quote token: the reserves and unclaimed curve fees all curves hold, which rescueToken leaves alone.
    mapping(address => uint256) private _totalRaised;
    mapping(address => uint256) private _totalAccruedFee;
    uint256 private _status;

    error Reentrancy();
    error NotSelf();
    error ZeroAddress();
    error ZeroAmount();
    error InsufficientCreationFee();
    error CloneFailed();
    error VanityAddressRequired();
    error NativeTransferFailed();
    error NativeNotAccepted();
    error DeadlineExpired();
    error UnknownToken();
    error AlreadyMigrated();
    error ExceedsSoldSupply();
    error LiquidityReserveViolation();
    error InsufficientPoolQuote();
    error SlippageTooLittleQuote();
    error SlippageTooFewTokens();
    error MigrationTargetNotReached();
    error ActivePool();
    error InvalidAllocation();
    error InvalidMarketCaps();
    error MigrationPending();
    error InsufficientContractBalance();
    error QuoteTokenNotAllowed();
    error InvalidHookFeeBps();
    error InvalidVaultBps();
    error NotMigrated();
    error NotCreator();
    error TooManyFeeSplits();
    error InvalidFeeSplitBps();
    error RouteUnavailable();

    event TokenCreated(
        address indexed token,
        address indexed creator,
        address         quoteToken,
        uint256         totalSupply,
        uint256         virtualQuote,
        uint256         migrationTarget
    );
    event TokenRegistered(
        address indexed token,
        address indexed creator,
        address         quoteToken,
        uint256         totalSupply,
        uint256         virtualQuote,
        uint256         migrationTarget
    );
    event TokenBought(
        address indexed token, address indexed buyer,
        uint256 quoteIn, uint256 tokensOut, uint256 raisedQuote
    );
    event TokenSold(
        address indexed token, address indexed seller,
        uint256 tokensIn, uint256 quoteOut, uint256 raisedQuote
    );
    event TokenMigrated(
        address indexed token, bytes32 poolId, uint256 liquidityQuote, uint256 liquidityTokens
    );
    event EmergencyMigrated(
        address indexed token, address indexed to, uint256 quoteAmount, uint256 tokenAmount
    );
    event MigrationFailed(address indexed token);
    event CreationFeeUpdated(uint256 oldFee, uint256 newFee);
    event DexConfigUpdated(address positionManager, address singleton, address hook);
    event QuoteTokenUpdated(address indexed token, bool allowed);
    event AllocationBoundsUpdated(uint256 minCurveBps, uint256 minLiquidityBps);
    event PlatformWalletUpdated(address recipient);
    event PlatformTokenUpdated(address token);
    event CurveFeeClaimed(address indexed token, address indexed creator, uint256 creatorAmount, uint256 platformAmount);
    event FeeSplitsUpdated(address indexed token, FeeSplit[] splits);
    event TokenRescued(address indexed token, address indexed to, uint256 amount);
    event ImplUpdated(string implType, address indexed prev, address indexed next);

    modifier nonReentrant() {
        if (_status == _ENTERED) revert Reentrancy();
        _status = _ENTERED;
        _;
        _status = _NOT_ENTERED;
    }

    constructor() {
        requireArcChain();
        _disableInitializers();
    }

    function initialize(
        address v4PositionManager_,
        address v4Singleton_,
        address v4Hook_,
        address platformWallet_,
        address tokenImpl_
    ) external initializer {
        _requireNonZero(v4PositionManager_);
        _requireNonZero(v4Singleton_);
        _requireNonZero(platformWallet_);
        _requireNonZero(tokenImpl_);

        __Ownable_init(msg.sender);
        __Ownable2Step_init();

        v4PositionManager = v4PositionManager_;
        v4Singleton       = v4Singleton_;
        v4Hook            = v4Hook_;
        platformWallet      = platformWallet_;
        tokenImpl         = tokenImpl_;
        creationFee       = 0.0005 ether;
        _status           = _NOT_ENTERED;

        minCurveBps     = 3000;
        minLiquidityBps = 1000;

    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function createToken(BaseParams memory p) external payable nonReentrant returns (address token) {
        _requireQuoteSupported(p.quoteToken);
        if (!quoteTokenAllowed[p.quoteToken]) revert QuoteTokenNotAllowed();
        if (!_isValidHookFeeBps(p.hookFeeBps)) revert InvalidHookFeeBps();
        // Any three shares of the 70% remainder are allowed as long as they sum to the whole.
        // Checked at creation, not only at the hook's registerPool (which fires at migration), so a
        // bad combination can't pass silently and surface as a migration failure weeks later.
        if (uint256(p.creatorBps) + p.vaultBps + p.burnBps != BPS_DENOM) revert InvalidVaultBps();
        uint256 nativeEarlyBuy = _collectCreationFee(p.quoteToken);
        token = BondingCurveMath.cloneCreate2(tokenImpl, msg.sender, p.salt);

        Alloc memory a = _computeAlloc(p.supplyTier, p.curveBps, p.liquidityBps);
        (uint256 vQuote, uint256 migTarget) = _computeQuoteTargets(p.startVirtualQuote, p.migrationTargetQuote);

        // No launch-phase lock: DuckGenesisHook only initializes pools this contract registers, at migration,
        // so a freely transferable token can't be used to seed or front-run its pool.
        //
        // Reward config is set here too, at creation, using this contract's CURRENT dex config and the
        // launch's own quote ERC-20 -- Arc has no native quote (NATIVE_QUOTE_ALLOWED is false) and no
        // WETH-wrap step, so p.quoteToken is already the real pool currency, unlike the shared-tree
        // build. Accepted tradeoff: a token that migrates after a later setDexConfig call keeps the
        // hook/poolManager that were current at its creation, not whatever it actually migrates onto.
        ITokenInit(token).initToken(p.name, p.symbol, a.supply, false, p.metaURI, v4Hook, p.quoteToken, v4Singleton);
        _registerToken(token, msg.sender, p.quoteToken, a, vQuote, migTarget, p.hookFeeBps, p.creatorBps, p.vaultBps, p.burnBps);
        emit TokenCreated(token, msg.sender, p.quoteToken, a.supply, vQuote, migTarget);

        // The creator's early buy is paid as the ERC-20 (earlyBuyAmount, pulled here), as native USDC on a
        // USDC curve (the value sent above the fee), or both.
        uint256 earlyBuy = p.earlyBuyAmount;
        if (earlyBuy > 0) _safeTransferFrom(p.quoteToken, msg.sender, address(this), earlyBuy);
        if (nativeEarlyBuy > 0) {
            (uint256 fromNative, bool ok) = _acquireQuoteToken(p.quoteToken, nativeEarlyBuy, 1, address(this));
            if (!ok) revert RouteUnavailable();
            earlyBuy += fromNative;
        }
        if (earlyBuy > 0) _executeBuy(token, msg.sender, earlyBuy, 0);
    }

    // Pays with the quote ERC-20 (approved to this contract). buyWithNative pays with native USDC.
    function buy(address token_, uint256 amountIn, uint256 minOut, uint256 deadline)
        external nonReentrant
    {
        _requireNotExpired(deadline);
        TokenConfig storage tc = _loadKnownToken(token_);
        if (amountIn == 0) revert ZeroAmount();
        _safeTransferFrom(tc.quoteToken, msg.sender, address(this), amountIn);
        _executeBuy(token_, msg.sender, amountIn, minOut);
    }

    function buyWithNative(address token_, uint256 minQuoteOut, uint256 minOut, uint256 deadline)
        external payable nonReentrant
    {
        _requireNotExpired(deadline);
        TokenConfig storage tc = _loadKnownToken(token_);
        if (msg.value == 0) revert ZeroAmount();

        (uint256 quoteIn, bool ok) = _acquireQuoteToken(tc.quoteToken, msg.value, minQuoteOut, address(this));
        if (!ok) revert RouteUnavailable();

        _executeBuy(token_, msg.sender, quoteIn, minOut);
    }

    function sell(address token_, uint256 amountIn, uint256 minQuoteOut, uint256 deadline)
        external nonReentrant
    {
        _requireNotExpired(deadline);
        _pullSellTokens(token_, amountIn);
        (, uint256 netQuote, uint256 raisedAfter) = _executeSell(token_, amountIn, minQuoteOut, msg.sender);
        emit TokenSold(token_, msg.sender, amountIn, netQuote, raisedAfter);
    }

    // buyWithNative in reverse: sells on the curve into this contract's own balance, then pays the seller
    // native USDC (a plain transfer on a USDC curve, a USDC route otherwise). minQuoteOut guards the curve;
    // minNativeOut the conversion.
    function sellForNative(address token_, uint256 amountIn, uint256 minQuoteOut, uint256 minNativeOut, uint256 deadline)
        external nonReentrant
    {
        _requireNotExpired(deadline);
        _pullSellTokens(token_, amountIn);
        (TokenConfig storage tc, uint256 netQuote, uint256 raisedAfter) = _executeSell(token_, amountIn, minQuoteOut, address(this));
        (, bool ok) = _disposeQuoteToken(tc.quoteToken, netQuote, minNativeOut, msg.sender);
        if (!ok) revert RouteUnavailable();

        emit TokenSold(token_, msg.sender, amountIn, netQuote, raisedAfter);
    }

    function _requireNotExpired(uint256 deadline) private view {
        if (block.timestamp > deadline) revert DeadlineExpired();
    }

    function _pullSellTokens(address token_, uint256 amountIn) private {
        if (amountIn == 0) revert ZeroAmount();
        IERC20Min(token_).transferFrom(msg.sender, address(this), amountIn);
    }

    function _executeSell(address token_, uint256 amountIn, uint256 minQuoteOut, address payoutRecipient)
        private returns (TokenConfig storage tc, uint256 netQuote, uint256 raisedAfter)
    {
        tc = _loadActiveToken(token_);
        if (amountIn > tc.bcTokensSold) revert ExceedsSoldSupply();
        (netQuote, raisedAfter) = BondingCurveMath.executeSell(
            tc, payoutRecipient, amountIn, minQuoteOut, _totalRaised, _totalAccruedFee
        );
    }

    function migrate(address token_) external nonReentrant {
        TokenConfig storage tc = _loadMigratableToken(token_);
        _doMigrate(tc, token_);
    }

    function claimCurveFee(address token_) external nonReentrant {
        TokenConfig storage tc = _loadKnownToken(token_);
        if (!tc.migrated) revert NotMigrated();

        uint256 amount = tc.accruedFee;
        if (amount == 0) revert ZeroAmount();
        tc.accruedFee = 0;

        // Memory snapshot before settle, which pays each split with its own external call -- a live
        // storage reference would let a reentrant setFeeSplits redirect not-yet-paid splits
        // mid-payout. See BondingCurveMath._distributeFeeSplits.
        FeeSplit[] memory splitsSnapshot = _feeSplits[token_];

        uint256 creatorCut;
        uint256 platformCut;
        bool needsBuyAndBurn;
        (creatorCut, platformCut, needsBuyAndBurn) = BondingCurveMath.settleCurveFee(
            tc, tc.creator, amount, _totalAccruedFee, splitsSnapshot, platformToken, platformWallet
        );

        if (needsBuyAndBurn) _buyAndBurn(tc, token_, platformCut);

        emit CurveFeeClaimed(token_, tc.creator, creatorCut, platformCut);
    }

    function _buyAndBurn(TokenConfig storage tc, address token_, uint256 amountIn) private {
        if (amountIn == 0) return;
        uint256 boughtBack = _executeV4Swap(
            tc.pair, v4Hook, V4_FEE_TIER, V4_TICK_SPACING, tc.quoteToken, token_, amountIn, 0, address(this)
        );
        if (boughtBack > 0) IERC20Min(token_).transfer(DEAD, boughtBack);
    }

    function setFeeSplits(address token_, FeeSplit[] calldata splits_) external {
        BondingCurveMath.setFeeSplits(_feeSplits[token_], msg.sender, tokens[token_].creator, splits_, MAX_FEE_SPLITS);
        emit FeeSplitsUpdated(token_, splits_);
    }

    function getFeeSplits(address token_) external view returns (FeeSplit[] memory) {
        return _feeSplits[token_];
    }

    function _tryMigrateExternal(address token_) external {
        if (msg.sender != address(this)) revert NotSelf();
        TokenConfig storage tc = tokens[token_];
        _doMigrate(tc, token_);
    }

    function emergencyMigrate(address token_) external onlyOwner nonReentrant {
        TokenConfig storage tc = _loadMigratableToken(token_);

        address to = owner();
        uint256 migrationAmount;
        uint256 liqTokens;
        (migrationAmount, liqTokens) = BondingCurveMigration.emergencyMigrate(tc, token_, to, _totalRaised);

        emit EmergencyMigrated(token_, to, migrationAmount, liqTokens);
    }

    function setCreationFee(uint256 fee_) external onlyOwner {
        emit CreationFeeUpdated(creationFee, fee_);
        creationFee = fee_;
    }

    function setRoutes(address quoteToken_, Route[] calldata routes_) external onlyOwner {
        _setRoutes(quoteToken_, routes_);
    }

    function setQuoteTokenAllowed(address token_, bool allowed_) external onlyOwner {
        _requireNonZero(token_);
        quoteTokenAllowed[token_] = allowed_;
        emit QuoteTokenUpdated(token_, allowed_);
    }

    function setAllocationBounds(uint256 minCurveBps_, uint256 minLiquidityBps_) external onlyOwner {
        if (minCurveBps_ + minLiquidityBps_ > BPS_DENOM) revert InvalidAllocation();
        minCurveBps     = minCurveBps_;
        minLiquidityBps = minLiquidityBps_;
        emit AllocationBoundsUpdated(minCurveBps_, minLiquidityBps_);
    }

    function setTokenImpl(address impl_) external onlyOwner {
        _requireNonZero(impl_);
        emit ImplUpdated("token", tokenImpl, impl_);
        tokenImpl = impl_;
    }

    function setVaultFactory(address vaultFactory_) external onlyOwner {
        _requireNonZero(vaultFactory_);
        emit ImplUpdated("vaultFactory", vaultFactory, vaultFactory_);
        vaultFactory = vaultFactory_;
    }


    function setDexConfig(address positionManager_, address singleton_, address hook_) external onlyOwner {
        _requireNonZero(positionManager_);
        _requireNonZero(singleton_);
        v4PositionManager = positionManager_;
        v4Singleton       = singleton_;
        v4Hook            = hook_;
        emit DexConfigUpdated(positionManager_, singleton_, hook_);
    }

    function setPlatformWallet(address wallet_) external onlyOwner {
        _requireNonZero(wallet_);
        platformWallet = wallet_;
        emit PlatformWalletUpdated(wallet_);
    }

    function setPlatformToken(address token_) external onlyOwner {
        platformToken = token_;
        emit PlatformTokenUpdated(token_);
    }

    function setUniversalRouter(address router_) external onlyOwner {
        _requireNonZero(router_);
        _setUniversalRouter(router_);
    }

    // No native rescue: on Arc the native balance is the USDC balance, curve reserves included.
    // rescueToken(ARC_USDC, to) returns only the USDC no curve is holding.
    function rescueToken(address token_, address to) external onlyOwner nonReentrant {
        _requireNonZero(token_);
        _requireNonZero(to);
        TokenConfig storage tc = tokens[token_];
        uint256 rescuable = BondingCurveMath.rescueToken(
            tc, token_, to, _totalRaised[token_], _totalAccruedFee[token_]
        );
        emit TokenRescued(token_, to, rescuable);
    }

    function _registerToken(
        address token_,
        address creator_,
        address quoteToken_,
        Alloc memory a,
        uint256 virtualQuote_,
        uint256 migrationTarget_,
        uint256 hookFeeBps_,
        uint16  creatorBps_,
        uint16  vaultBps_,
        uint16  burnBps_
    ) private {
        TokenConfig storage tc = tokens[token_];
        BondingCurveMigration.registerToken(
            tc, allTokens, _tokensByCreator,
            token_, creator_, quoteToken_, a.supply, a.liqTokens, a.bcTokens,
            virtualQuote_, migrationTarget_, hookFeeBps_, creatorBps_, vaultBps_, burnBps_
        );

        // Vault/lending is opt-in: vaultBps_ == 0 means the creator chose no vault cut at all, so
        // skip deploying one entirely -- see DuckLauncher._setupAndRegister for the identical rule.
        if (vaultFactory != address(0) && vaultBps_ > 0) {
            IDuckVaultFactoryLocal(vaultFactory).createVault(token_, 18, creator_);
        }

        emit TokenRegistered(token_, creator_, quoteToken_, a.supply, virtualQuote_, migrationTarget_);
    }

    function _computeAlloc(
        uint8 supplyTier, uint256 curveBps, uint256 liquidityBps
    ) private view returns (Alloc memory a) {
        uint256 supply = SupplyTiers.resolve(supplyTier);
        if (curveBps + liquidityBps != BPS_DENOM) revert InvalidAllocation();
        if (curveBps     < minCurveBps)     revert InvalidAllocation();
        if (liquidityBps < minLiquidityBps) revert InvalidAllocation();

        a.supply    = supply;
        a.liqTokens = (supply * liquidityBps) / BPS_DENOM;
        a.bcTokens  = supply - a.liqTokens;
    }

    function _computeQuoteTargets(uint256 startVirtualQuote_, uint256 migrationTargetQuote_)
        private pure returns (uint256 virtualQuote, uint256 migrationTarget)
    {
        if (startVirtualQuote_ == 0 || migrationTargetQuote_ <= startVirtualQuote_) revert InvalidMarketCaps();
        virtualQuote    = startVirtualQuote_;
        migrationTarget = migrationTargetQuote_;
    }

    function _isValidHookFeeBps(uint256 bps) private pure returns (bool) {
        // Any rate up to 10% (DuckGenesisHook's MAX_HOOK_FEE_BPS); 0 still means the hook's 2% default.
        return bps <= 1000;
    }

    // Shared validation helpers -- each of these was previously inlined at every call site
    // separately; factoring them out here trims real bytes off the deployed contract (relevant
    // since this contract sits close to the EIP-170 24,576-byte limit), with no behavior change.
    function _requireNonZero(address x) private pure {
        if (x == address(0)) revert ZeroAddress();
    }

    function _requireKnownToken(TokenConfig storage tc) private view {
        if (tc.token == address(0)) revert UnknownToken();
    }

    function _requireActiveToken(TokenConfig storage tc) private view {
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        if (tc.migrationPending)    revert MigrationPending();
    }

    function _requireMigratable(TokenConfig storage tc) private view {
        if (tc.token == address(0)) revert UnknownToken();
        if (tc.migrated)            revert AlreadyMigrated();
        if (!tc.migrationPending)   revert MigrationTargetNotReached();
    }

    function _loadKnownToken(address token_) private view returns (TokenConfig storage tc) {
        tc = tokens[token_];
        _requireKnownToken(tc);
    }


    function _loadActiveToken(address token_) private view returns (TokenConfig storage tc) {
        tc = tokens[token_];
        _requireActiveToken(tc);
    }

    function _loadMigratableToken(address token_) private view returns (TokenConfig storage tc) {
        tc = tokens[token_];
        _requireMigratable(tc);
    }

    // The creation fee is paid in native USDC. Value sent above it is an early buy, accepted on USDC curves
    // only, where it already is the curve's USDC (no swap, no slippage to guard).
    function _collectCreationFee(address quoteToken_) private returns (uint256 nativeEarlyBuy) {
        bool waived = platformToken != address(0) && quoteToken_ == platformToken;
        uint256 cf = waived ? 0 : creationFee;
        if (msg.value < cf) revert InsufficientCreationFee();
        nativeEarlyBuy = msg.value - cf;
        if (nativeEarlyBuy > 0 && quoteToken_ != ARC_USDC) revert NativeNotAccepted();
        if (cf > 0) _safeSendNative(platformWallet, cf);
    }

    function _executeBuy(
        address token_, address buyer, uint256 quoteIn, uint256 minOut
    ) private {
        TokenConfig storage tc = _loadActiveToken(token_);

        uint256 tokensOut;
        uint256 netQuoteIn;
        bool migrationAttemptFailed;
        (tokensOut, netQuoteIn, migrationAttemptFailed) =
            BondingCurveMath.executeBuy(tc, token_, buyer, quoteIn, minOut, _totalRaised, _totalAccruedFee);

        emit TokenBought(token_, buyer, netQuoteIn, tokensOut, tc.raisedQuote);
        if (migrationAttemptFailed) emit MigrationFailed(token_);
    }

    function _doMigrate(TokenConfig storage tc, address token_) private {
        uint256 migrationAmount = tc.raisedQuote;
        uint256 liqTokens       = tc.liquidityTokens;

        bytes32 poolId;
        poolId = BondingCurveMigration.migrate(
            tc, token_, _totalRaised,
            BondingCurveMigration.MigrationConfig({
                hook:            v4Hook,
                positionManager: v4PositionManager,
                singleton:       v4Singleton,
                fee:             V4_FEE_TIER,
                tickSpacing:     V4_TICK_SPACING
            })
        );

        emit TokenMigrated(token_, poolId, migrationAmount, liqTokens);
    }

    function _safeSendNative(address to, uint256 amount) private {
        if (amount == 0) return;
        (bool ok,) = payable(to).call{value: amount}("");
        if (!ok) revert NativeTransferFailed();
    }

    function totalTokensLaunched() external view returns (uint256) { return allTokens.length; }

    function getTokensByCreator(address creator_) external view returns (address[] memory) {
        return _tokensByCreator[creator_];
    }

    function tokenCountByCreator(address creator_) external view returns (uint256) {
        return _tokensByCreator[creator_].length;
    }

}
