// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckCrowdfund (Arc)
//
// Crowdfunded launches on Arc, raised in an allowlisted ERC-20 (USDC by default), never raw native. A USDC
// raise also takes contributions as native USDC, which is the same money.

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchRouting, Route, PoolKey} from "duck-lib/LaunchRouting.sol";
import {ARC_USDC, NATIVE_PER_USDC, requireArcChain} from "duck-lib/ArcChain.sol";
import {V4Minting} from "duck-lib/V4Minting.sol";
import {SupplyTiers} from "duck-lib/SupplyTiers.sol";

interface IDuckCrowdfundTokenLocal {
    function initToken(
        string calldata name_, string calldata symbol_, uint256 totalSupply_, bool lockUntilUnlock_, string calldata metaURI_,
        address hook_, address currency_, address poolManager_
    ) external;
    function renounceOwnership() external;
    function approve(address spender, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

interface IDuckVaultFactoryLocal {
    function createVault(address token, uint8 tokenDecimals, address creator_) external returns (address vault);
}

interface IDuckVaultLinkLocal {
    function linkPool(address currency, bytes32 poolId, bool tokenIsCurrency0, uint8 currencyDecimals) external;
}

interface ITokenVaultPointerLocal {
    function vault() external view returns (address);
}

interface IERC20DecimalsLocal {
    function decimals() external view returns (uint8);
}

contract DuckCrowdfund is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuard, LaunchRouting {

    error ZeroAddress();
    error ZeroAmount();
    error CloneFailed();
    error VanityAddressRequired();
    error NotLiveYet();
    error DeadlinePassed();
    error DeadlineNotPassed();
    error WrongFee();
    error CampaignNotFound();
    error AlreadyFinalized();
    error NotFinalized();
    error CampaignFailed_();
    error CampaignSucceeded_();
    error NothingToClaim();
    error PoolAlreadyExists();
    error InvalidBps();
    error HookNotSet();
    error NativeNotAccepted();
    error InvalidHookFeeBps();
    error QuoteAssetNotAllowed();
    error InvalidVaultBps();
    error InexactNativeAmount();

    uint16  public constant VANITY_SUFFIX = 0x8888;

    // No native pool fee -- the creator-chosen 2-10% hook fee is the sole trading fee (see
    // DuckHookV4.claimFees). No position NFT or locker either: liquidity goes straight into the
    // PoolManager singleton, owned by this contract and never withdrawn -- with a 0% pool fee
    // there's nothing to claim back anyway.
    uint24  private constant FEE_TIER     = 0;
    int24   private constant TICK_SPACING =  200;

    struct Campaign {
        address creator;
        string  name;
        string  symbol;
        string  metaURI;
        address dexQuoteAsset;

        uint256 goal;

        uint256 startTime;
        uint256 deadline;
        uint256 totalRaised;
        bytes32 vanitySalt;
        uint256 contributorBps;
        uint256 lpBps;
        bool    finalized;
        bool    succeeded;
        address token;
        uint256 hookFeeBps;
        // Fully flexible three-way split of the 70% vault/creator/burn remainder (see
        // DuckHookV4.claimFees) -- must sum to exactly 10_000.
        uint16  creatorBps;
        uint16  vaultBps;
        uint16  burnBps;
        uint256 totalSupply;
    }

    Campaign[] private campaigns;

    function getCampaignCore(uint256 campaignId) external view returns (
        address creator, address dexQuoteAsset, uint256 goal, uint256 startTime, uint256 deadline,
        uint256 totalRaised, bool finalized, bool succeeded, address token
    ) {
        Campaign storage c = campaigns[campaignId];
        return (c.creator, c.dexQuoteAsset, c.goal, c.startTime, c.deadline, c.totalRaised, c.finalized, c.succeeded, c.token);
    }

    function getCampaignMeta(uint256 campaignId) external view returns (
        string memory name, string memory symbol, string memory metaURI, bytes32 vanitySalt,
        uint256 contributorBps, uint256 lpBps, uint256 hookFeeBps, uint16 vaultBps, uint256 totalSupply
    ) {
        Campaign storage c = campaigns[campaignId];
        return (c.name, c.symbol, c.metaURI, c.vanitySalt, c.contributorBps, c.lpBps, c.hookFeeBps, c.vaultBps, c.totalSupply);
    }
    mapping(uint256 => mapping(address => uint256)) public contributed;

    address      public tokenImpl;
    address      public vaultFactory;
    address      public v4Singleton;
    address      public v4PositionManager;
    address      public v4Hook;
    uint256      public contributorBps;
    uint256      public lpBps;
    uint256      public campaignFee;
    address      public platformWallet;

    address      public platformToken;

    mapping(address => bool) public quoteAssetAllowed;

    uint256 public campaignDuration;

    event CampaignCreated(uint256 indexed campaignId, address indexed creator, address indexed token, string name, string symbol, address dexQuoteAsset, uint256 goal, uint256 startTime, uint256 deadline);
    event Contributed(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event CampaignSucceeded(uint256 indexed campaignId, address indexed token, uint256 totalRaised);
    event CampaignFailed(uint256 indexed campaignId, uint256 totalRaised, uint256 goal);
    event Claimed(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event Refunded(uint256 indexed campaignId, address indexed contributor, uint256 amount);
    event TokenImplSet(address indexed tokenImpl);
    event VaultFactorySet(address indexed vaultFactory);
    event DexConfigSet(address positionManager, address singleton, address hook);
    event PlatformWalletSet(address indexed wallet);
    event PlatformTokenSet(address indexed token);
    event QuoteAssetUpdated(address indexed token, bool allowed);
    event CampaignFeeSet(uint256 fee);
    event SupplySplitSet(uint256 contributorBps, uint256 lpBps);
    event CampaignDurationSet(uint256 duration);

    constructor() {
        requireArcChain();
        _disableInitializers();
    }

    function initialize(
        address tokenImpl_,
        address v4Singleton_,
        address v4PositionManager_,
        address v4Hook_,
        address platformWallet_
    ) external initializer {
        if (tokenImpl_          == address(0)) revert ZeroAddress();
        if (v4Singleton_        == address(0)) revert ZeroAddress();
        if (v4PositionManager_  == address(0)) revert ZeroAddress();
        if (platformWallet_     == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);
        __Ownable2Step_init();

        tokenImpl         = tokenImpl_;
        v4Singleton       = v4Singleton_;
        v4PositionManager = v4PositionManager_;
        v4Hook            = v4Hook_;
        platformWallet         = platformWallet_;
        campaignFee       = 0.0005 ether;

        contributorBps   = 4_500;
        lpBps            = 5_500;
        campaignDuration = 2 hours;

    }

    function setQuoteAssetAllowed(address token_, bool allowed_) external onlyOwner {
        if (token_ == address(0)) revert ZeroAddress();
        quoteAssetAllowed[token_] = allowed_;
        emit QuoteAssetUpdated(token_, allowed_);
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setUniversalRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        _setUniversalRouter(router_);
    }

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

    function setDexConfig(address positionManager_, address singleton_, address hook_) external onlyOwner {
        if (positionManager_ == address(0)) revert ZeroAddress();
        if (singleton_        == address(0)) revert ZeroAddress();
        v4PositionManager = positionManager_;
        v4Singleton       = singleton_;
        v4Hook            = hook_;
        emit DexConfigSet(positionManager_, singleton_, hook_);
    }

    function setRoutes(address quoteToken_, Route[] calldata routes_) external onlyOwner {
        _setRoutes(quoteToken_, routes_);
    }

    function setPlatformWallet(address wallet) external onlyOwner {
        if (wallet == address(0)) revert ZeroAddress();
        platformWallet = wallet;
        emit PlatformWalletSet(wallet);
    }

    function setPlatformToken(address token) external onlyOwner {
        platformToken = token;
        emit PlatformTokenSet(token);
    }

    function setCampaignFee(uint256 fee_) external onlyOwner {
        campaignFee = fee_;
        emit CampaignFeeSet(fee_);
    }

    function setSupplySplit(uint256 contributorBps_, uint256 lpBps_) external onlyOwner {
        if (contributorBps_ + lpBps_ != 10_000) revert InvalidBps();
        contributorBps = contributorBps_;
        lpBps          = lpBps_;
        emit SupplySplitSet(contributorBps_, lpBps_);
    }

    function setCampaignDuration(uint256 duration_) external onlyOwner {
        if (duration_ == 0) revert ZeroAmount();
        campaignDuration = duration_;
        emit CampaignDurationSet(duration_);
    }

    function campaignCount() external view returns (uint256) {
        return campaigns.length;
    }

    function previewClaimable(uint256 campaignId_, address account) external view returns (uint256) {
        if (campaignId_ >= campaigns.length) revert CampaignNotFound();
        Campaign storage c = campaigns[campaignId_];
        if (!c.finalized || !c.succeeded) return 0;
        uint256 amount = contributed[campaignId_][account];
        if (amount == 0) return 0;
        uint256 contributorSupply = c.totalSupply * c.contributorBps / 10_000;
        return contributorSupply * amount / c.totalRaised;
    }

    // The strings are taken as memory, not calldata: a calldata string is two stack slots, and with twelve
    // parameters the calldata version doesn't fit via-IR's stack. The external ABI is the same either way.
    function launch(
        string memory name_,
        string memory symbol_,
        string memory metaURI_,
        address dexQuoteAsset_,
        uint256 goalNativeWei_,
        uint256 startTime_,
        bytes32 vanitySalt_,
        uint256 hookFeeBps_,
        uint16  creatorBps_,
        uint16  vaultBps_,
        uint16  burnBps_,
        uint8   supplyTier_
    ) external payable nonReentrant returns (uint256 campaignId, address token) {
        bool feeWaived = platformToken != address(0) && dexQuoteAsset_ == platformToken;
        uint256 fee = feeWaived ? 0 : campaignFee;
        if (msg.value != fee) revert WrongFee();
        if (goalNativeWei_ == 0) revert ZeroAmount();
        if (!_isValidHookFeeBps(hookFeeBps_)) revert InvalidHookFeeBps();
        // Any three shares of the 70% remainder are allowed as long as they sum to the whole.
        // Checked at launch, not only at the hook's registerPool (which fires at finalize), so a bad
        // combination can't surface as a failure after the raise has already succeeded.
        if (uint256(creatorBps_) + vaultBps_ + burnBps_ != 10_000) revert InvalidVaultBps();
        _requireQuoteSupported(dexQuoteAsset_);
        if (!quoteAssetAllowed[dexQuoteAsset_]) revert QuoteAssetNotAllowed();

        if (fee > 0) {
            (bool ok,) = platformWallet.call{value: fee}("");
            if (!ok) revert TransferFailed();
        }

        token = _deployToken(name_, symbol_, metaURI_, vanitySalt_, supplyTier_, vaultBps_, dexQuoteAsset_);

        campaignId = _recordCampaign(
            name_, symbol_, metaURI_, dexQuoteAsset_, goalNativeWei_, startTime_, vanitySalt_, hookFeeBps_, creatorBps_, vaultBps_, burnBps_, supplyTier_, token
        );
    }

    function _deployToken(
        string memory name_, string memory symbol_, string memory metaURI_, bytes32 vanitySalt_, uint8 supplyTier_,
        uint16 vaultBps_, address dexQuoteAsset_
    ) private returns (address token) {
        bytes32 salt = keccak256(abi.encode(msg.sender, vanitySalt_));
        token = _clone(tokenImpl, salt);
        if (uint16(uint160(token)) != VANITY_SUFFIX) revert VanityAddressRequired();
        // Reward config is set here, at mint, using this contract's CURRENT dex config and the
        // campaign's own quote ERC-20 -- Arc has no native quote/WETH-wrap step, so dexQuoteAsset_ is
        // already the real pool currency, unlike the shared-tree build. No privileged address is left
        // able to call anything into this token after this point -- renounceOwnership below is real,
        // not just a display value, since there's no second role like the old separate mintManager
        // waiting to be used later.
        IDuckCrowdfundTokenLocal(token).initToken(name_, symbol_, SupplyTiers.resolve(supplyTier_), false, metaURI_, v4Hook, dexQuoteAsset_, v4Singleton);
        IDuckCrowdfundTokenLocal(token).renounceOwnership();

        // Vault/lending is opt-in: vaultBps_ == 0 means the creator chose no vault cut at all, so
        // skip deploying one entirely -- see DuckLauncher._setupAndRegister for the identical rule.
        if (vaultFactory != address(0) && vaultBps_ > 0) {
            IDuckVaultFactoryLocal(vaultFactory).createVault(token, IERC20DecimalsLocal(token).decimals(), msg.sender);
        }
    }

    function _recordCampaign(
        string memory name_, string memory symbol_, string memory metaURI_, address dexQuoteAsset_,
        uint256 goalNativeWei_, uint256 startTime_, bytes32 vanitySalt_, uint256 hookFeeBps_, uint16 creatorBps_,
        uint16 vaultBps_, uint16 burnBps_, uint8 supplyTier_, address token
    ) private returns (uint256 campaignId) {
        uint256 startTime = startTime_ <= block.timestamp ? block.timestamp : startTime_;
        uint256 deadline = startTime + campaignDuration;

        campaignId = campaigns.length;
        Campaign storage c = campaigns.push();
        c.creator        = msg.sender;
        c.name           = name_;
        c.symbol         = symbol_;
        c.metaURI        = metaURI_;
        c.dexQuoteAsset  = dexQuoteAsset_;
        c.goal           = goalNativeWei_;
        c.startTime      = startTime;
        c.deadline       = deadline;
        c.vanitySalt     = vanitySalt_;
        c.contributorBps = contributorBps;
        c.lpBps          = lpBps;
        c.token          = token;
        c.hookFeeBps     = hookFeeBps_;
        c.creatorBps     = creatorBps_;
        c.vaultBps       = vaultBps_;
        c.burnBps        = burnBps_;
        c.totalSupply    = SupplyTiers.resolve(supplyTier_);
        emit CampaignCreated(campaignId, msg.sender, token, name_, symbol_, dexQuoteAsset_, goalNativeWei_, startTime, deadline);
    }

    function contribute(uint256 campaignId_, uint256 amount_) external payable nonReentrant {
        if (campaignId_ >= campaigns.length) revert CampaignNotFound();
        Campaign storage c = campaigns[campaignId_];
        if (block.timestamp < c.startTime) revert NotLiveYet();
        if (block.timestamp >= c.deadline) revert DeadlinePassed();

        // A USDC raise takes native USDC (msg.value, in whole ERC-20 units) or the ERC-20 (amount_, approved to
        // this contract); any other quote asset takes only its ERC-20.
        uint256 amount;
        if (msg.value != 0) {
            if (c.dexQuoteAsset != ARC_USDC || amount_ != 0) revert NativeNotAccepted();
            if (msg.value % NATIVE_PER_USDC != 0) revert InexactNativeAmount();
            amount = msg.value / NATIVE_PER_USDC;
        } else {
            if (amount_ == 0) revert ZeroAmount();
            _safeTransferFrom(c.dexQuoteAsset, msg.sender, address(this), amount_);
            amount = amount_;
        }

        contributed[campaignId_][msg.sender] += amount;
        c.totalRaised += amount;
        emit Contributed(campaignId_, msg.sender, amount);
    }

    function finalize(uint256 campaignId_) external nonReentrant returns (address token) {
        if (campaignId_ >= campaigns.length) revert CampaignNotFound();
        Campaign storage c = campaigns[campaignId_];
        if (block.timestamp < c.deadline) revert DeadlineNotPassed();
        if (c.finalized) revert AlreadyFinalized();

        c.finalized = true;
        token = c.token;

        if (c.totalRaised >= c.goal) {
            try this._seedSuccessLiquidity(campaignId_) {
                c.succeeded = true;
                emit CampaignSucceeded(campaignId_, token, c.totalRaised);
            } catch {
                emit CampaignFailed(campaignId_, c.totalRaised, c.goal);
            }
        } else {
            emit CampaignFailed(campaignId_, c.totalRaised, c.goal);
        }
    }

    function _seedSuccessLiquidity(uint256 campaignId_) external {
        if (msg.sender != address(this)) revert Unauthorized();
        Campaign storage c = campaigns[campaignId_];
        address token = c.token;

        uint256 contributorSupply = c.totalSupply * c.contributorBps / 10_000;
        uint256 lpSupply = c.totalSupply - contributorSupply;

        _seedV4(token, c.dexQuoteAsset, lpSupply, c.totalRaised, c.creator, c.hookFeeBps, c.creatorBps, c.vaultBps, c.burnBps);
    }

    function _seedV4(
        address token,
        address quoteCurrency,
        uint256 lpSupply,
        uint256 quoteAmount,
        address creator,
        uint256 hookFeeBps,
        uint16  creatorBps,
        uint16  vaultBps,
        uint16  burnBps
    ) private {
        address hookAddr = v4Hook;
        if (hookAddr == address(0)) revert HookNotSet();

        // Reward config is no longer set here -- _deployToken sets it at mint time now, using the same
        // dexQuoteAsset this function also uses (Arc has no native-quote wrap, so the two can never
        // disagree).

        (address token0, address token1) = token < quoteCurrency ? (token, quoteCurrency) : (quoteCurrency, token);
        (uint256 amount0, uint256 amount1) = token == token0
            ? (lpSupply, quoteAmount)
            : (quoteAmount, lpSupply);

        bytes32 poolId = _mintCrowdfundPosition(
            token, token0, token1, amount0, amount1, hookAddr, creator, hookFeeBps, creatorBps, vaultBps, burnBps
        );

        _finishSeedV4(token, poolId, token0, hookAddr, quoteCurrency);
    }

    function _mintCrowdfundPosition(
        address token, address token0, address token1, uint256 amount0, uint256 amount1,
        address hookAddr, address creator, uint256 hookFeeBps, uint16 creatorBps, uint16 vaultBps, uint16 burnBps
    ) private returns (bytes32 poolId) {
        // Built field-by-field into a named local, not one big struct-literal call argument -- with
        // this many fields, encoding it inline can hit stack-too-deep even under via-IR (same fix as
        // DuckHookV4.registerPool for the identical reason).
        V4Minting.MintFullRangeSetupParams memory p;
        p.positionManager = v4PositionManager;
        p.hook            = hookAddr;
        p.token           = token;
        p.token0          = token0;
        p.token1          = token1;
        p.amount0         = amount0;
        p.amount1         = amount1;
        p.creator         = creator;
        p.hookFeeBps      = hookFeeBps;
        p.creatorBps      = creatorBps;
        p.vaultBps        = vaultBps;
        p.burnBps         = burnBps;
        p.fee             = FEE_TIER;
        p.tickSpacing     = TICK_SPACING;

        PoolKey memory key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        (poolId, key, tickLower, tickUpper, liquidity) = V4Minting.setupFullRangePool(p);

        // No position NFT: liquidity goes straight to the PoolManager singleton, owned by this
        // contract, permanently (see LaunchRouting._mintFullRangeDirect).
        _mintFullRangeDirect(v4Singleton, key, tickLower, tickUpper, liquidity);
    }

    function _finishSeedV4(
        address token, bytes32 poolId, address token0, address hookAddr, address quoteToken
    ) private {
        address vault = ITokenVaultPointerLocal(token).vault();
        if (vault != address(0)) {
            try IDuckVaultLinkLocal(vault).linkPool(quoteToken, poolId, token == token0, IERC20DecimalsLocal(quoteToken).decimals()) {} catch {}
        }
    }

    function claim(uint256 campaignId_) external nonReentrant {
        if (campaignId_ >= campaigns.length) revert CampaignNotFound();
        Campaign storage c = campaigns[campaignId_];
        if (!c.finalized) revert NotFinalized();
        if (!c.succeeded) revert CampaignFailed_();
        uint256 amount = contributed[campaignId_][msg.sender];
        if (amount == 0) revert NothingToClaim();

        contributed[campaignId_][msg.sender] = 0;

        uint256 contributorSupply = c.totalSupply * c.contributorBps / 10_000;
        uint256 share = contributorSupply * amount / c.totalRaised;

        IDuckCrowdfundTokenLocal(c.token).transfer(msg.sender, share);
        emit Claimed(campaignId_, msg.sender, share);
    }

    function claimRefund(uint256 campaignId_) external nonReentrant {
        if (campaignId_ >= campaigns.length) revert CampaignNotFound();
        Campaign storage c = campaigns[campaignId_];
        if (!c.finalized) revert NotFinalized();
        if (c.succeeded) revert CampaignSucceeded_();
        uint256 amount = contributed[campaignId_][msg.sender];
        if (amount == 0) revert NothingToClaim();

        contributed[campaignId_][msg.sender] = 0;

        _safeTransfer(c.dexQuoteAsset, msg.sender, amount);
        emit Refunded(campaignId_, msg.sender, amount);
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
        // Any rate up to 10% (DuckGenesisHook's MAX_HOOK_FEE_BPS); 0 still means the hook's 2% default.
        return bps <= 1000;
    }

}
