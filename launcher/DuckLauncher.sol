// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckLauncher

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {LaunchRouting, Route, RouteShape, PoolKey} from "duck-lib/LaunchRouting.sol";
import {V4Math} from "duck-lib/V4Math.sol";
import {V4Minting} from "duck-lib/V4Minting.sol";
import {SupplyTiers} from "duck-lib/SupplyTiers.sol";

interface IDuckLauncherToken {
    function initToken(string calldata name_, string calldata symbol_, uint256 totalSupply_, bool lockUntilUnlock_, string calldata metaURI_) external;
    function renounceOwnership() external;
    function setRewardConfig(address hook_, address currency_, address poolManager_) external;
}

interface IDuckVaultFactoryLocal {
    function createVault(address token, uint8 tokenDecimals, address creator_) external returns (address vault);
}

interface IDuckVaultLinkLocal {
    function linkPool(address currency, bytes32 poolId, bool tokenIsCurrency0, uint8 currencyDecimals, bool poolQuoteIsNative) external;
}

interface IERC20DecimalsLocal {
    function decimals() external view returns (uint8);
}

interface IWETHLocal {
    function deposit() external payable;
}

contract DuckLauncher is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuard, LaunchRouting {

    error UnsupportedQuoteToken();
    error UnsupportedDex();
    error WrongFee();
    error ZeroAddress();
    error ZeroAmount();
    error CloneFailed();
    error PoolAlreadyExists();
    error InvalidTickRange();
    error VanityAddressRequired();
    error InstantBuyFailed();
    error HookRequired();
    error InvalidHookFeeBps();
    error InvalidVaultBps();

    uint16 public constant VANITY_SUFFIX = 0x8888;

    // No native pool fee -- the creator-chosen 2-10% hook fee is the sole trading fee (see
    // DuckHookV4.claimFees). No position NFT or locker either: liquidity goes straight into the
    // PoolManager singleton, owned by this contract and never withdrawn -- with a 0% pool fee
    // there's nothing to claim back anyway.
    uint24 private constant FEE_TIER     = 0;
    int24  private constant MIN_TICK     = -887_200;
    int24  private constant MAX_TICK     =  887_200;
    int24  private constant TICK_SPACING =  200;

    struct DexConfig {
        address singleton;
        address hook;
        bool    enabled;
    }

    struct LaunchParams {
        string  name;
        string  symbol;
        string  metaURI;
        address feeWallet;
        address positionManager;
        address quoteToken;
        bytes32 vanitySalt;
        uint8   supplyTier;
        uint256 launchMarketCap;
        uint256 minQuoteOut;
        uint256 minTokensOut;
        uint256 hookFeeBps;
        // Three-way split of the 70% remainder (see DuckHookV4.claimFees), summing to exactly BPS.
        // Each is independently zeroable: vaultBps == 0 deploys no vault at all, burnBps == 0 never
        // buys back and burns.
        uint16  creatorBps;
        uint16  vaultBps;
        uint16  burnBps;
        bool    revertOnInstantBuyFailure;
    }

    mapping(address => DexConfig) public dexes;
    mapping(address => bool)      public quoteTokens;

    address      public weth;
    address      public tokenImpl;
    address      public vaultFactory;
    address      public platformWallet;
    uint256      public launchFee;

    address      public platformToken;

    event TokenLaunched(
        address indexed token,
        address indexed creator,
        address indexed positionManager,
        address         quoteToken,
        address         hook,
        bytes32         poolId
    );
    event DexAdded(address indexed positionManager, address singleton, address hook);
    event DexDisabled(address indexed positionManager);
    event QuoteTokenAdded(address indexed token);
    event QuoteTokenDisabled(address indexed token);
    event PlatformWalletSet(address indexed wallet);
    event PlatformTokenSet(address indexed token);
    event LaunchFeeSet(uint256 fee);
    event TokenImplSet(address indexed tokenImpl);
    event VaultFactorySet(address indexed vaultFactory);
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);
    event InstantBuySkipped(address indexed token, uint256 refundedWei);

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address weth_,
        address tokenImpl_,
        address platformWallet_,
        address initialPositionMgr_,
        address initialSingleton_,
        address initialHook_
    ) external initializer {
        if (weth_               == address(0)) revert ZeroAddress();
        if (tokenImpl_          == address(0)) revert ZeroAddress();
        if (initialPositionMgr_ == address(0)) revert ZeroAddress();
        if (initialSingleton_   == address(0)) revert ZeroAddress();
        if (platformWallet_     == address(0)) revert ZeroAddress();

        __Ownable_init(msg.sender);
        __Ownable2Step_init();

        weth            = weth_;
        tokenImpl       = tokenImpl_;
        platformWallet  = platformWallet_;
        launchFee       = 0.0005 ether;

        dexes[initialPositionMgr_] = DexConfig({
            singleton: initialSingleton_,
            hook:      initialHook_,
            enabled:   true
        });
        emit DexAdded(initialPositionMgr_, initialSingleton_, initialHook_);

        // Native ETH is the only quote asset seeded here: it is the one that means the same thing on
        // every chain. ERC20 quote tokens are chain-specific and are seeded by the deploy script from
        // its own per-chain curated list -- an earlier revision hardcoded Robinhood's list here with
        // no chain check, which silently whitelisted meaningless addresses when deployed to Ink.
        quoteTokens[address(0)] = true;
        emit QuoteTokenAdded(address(0));
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setUniversalRouter(address router_) external onlyOwner {
        if (router_ == address(0)) revert ZeroAddress();
        _setUniversalRouter(router_);
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

    function setLaunchFee(uint256 fee_) external onlyOwner {
        if (fee_ == 0) revert ZeroAmount();
        launchFee = fee_;
        emit LaunchFeeSet(fee_);
    }

    function addDex(address positionManager_, address singleton_, address hook_) external onlyOwner {
        if (positionManager_ == address(0)) revert ZeroAddress();
        if (singleton_        == address(0)) revert ZeroAddress();
        dexes[positionManager_] = DexConfig({singleton: singleton_, hook: hook_, enabled: true});
        emit DexAdded(positionManager_, singleton_, hook_);
    }

    function disableDex(address positionManager_) external onlyOwner {
        if (!dexes[positionManager_].enabled) revert UnsupportedDex();
        dexes[positionManager_].enabled = false;
        emit DexDisabled(positionManager_);
    }

    function addQuoteToken(address token_) external onlyOwner {
        quoteTokens[token_] = true;
        emit QuoteTokenAdded(token_);
    }

    function disableQuoteToken(address token_) external onlyOwner {
        if (!quoteTokens[token_]) revert UnsupportedQuoteToken();
        quoteTokens[token_] = false;
        emit QuoteTokenDisabled(token_);
    }

    function rescueETH(address to_, uint256 amount_) external onlyOwner {
        if (to_     == address(0)) revert ZeroAddress();
        if (amount_ == 0)         revert ZeroAmount();
        (bool ok,) = to_.call{value: amount_}("");
        if (!ok) revert TransferFailed();
        emit ETHRescued(to_, amount_);
    }

    function rescueERC20(address token_, address to_, uint256 amount_) external onlyOwner {
        if (token_  == address(0)) revert ZeroAddress();
        if (to_     == address(0)) revert ZeroAddress();
        if (amount_ == 0)         revert ZeroAmount();
        _safeTransfer(token_, to_, amount_);
        emit ERC20Rescued(token_, to_, amount_);
    }

    function launch(LaunchParams calldata p) external payable nonReentrant
        returns (address token, bytes32 poolId)
    {
        uint256 totalSupply = SupplyTiers.resolve(p.supplyTier);
        token = _deployAndInit(p.name, p.symbol, p.metaURI, p.vanitySalt, totalSupply);
        poolId = _setupAndRegister(token, p, totalSupply);
    }

    function _setupAndRegister(
        address token,
        LaunchParams calldata p,
        uint256 totalSupply
    ) private returns (bytes32 poolId) {
        DexConfig storage dex = dexes[p.positionManager];
        if (!dex.enabled) revert UnsupportedDex();
        if (dex.hook == address(0)) revert HookRequired();
        _requireQuoteSupported(p.quoteToken);

        // Must run BEFORE _mintV4 (and any instant-buy swap): minting the LP position is what first
        // moves real balance into the PoolManager, and DuckToken only excludes poolManagerAddr once
        // it's non-zero. Setting it first means that inbound transfer is recognized as the pool's own
        // reserve rather than a new "holder". Launcher tokens have a pool from block one; curve and
        // crowdfund wire this up at migration/success with the same before-the-mint ordering.
        IDuckLauncherToken(token).setRewardConfig(dex.hook, p.quoteToken, dex.singleton);

        if (p.launchMarketCap == 0) revert ZeroAmount();
        bool feeWaived = platformToken != address(0) && p.quoteToken == platformToken;
        uint256 fee = feeWaived ? 0 : launchFee;
        if (msg.value < fee) revert WrongFee();
        if (!_isValidHookFeeBps(p.hookFeeBps)) revert InvalidHookFeeBps();
        // Any three shares of the 70% remainder are allowed as long as they sum to the whole (see
        // DuckHookV4.claimFees). Checked here as well as in registerPool moments later, so a bad
        // combination reverts clearly before any other launch side effects run.
        if (uint256(p.creatorBps) + p.vaultBps + p.burnBps != 10_000) revert InvalidVaultBps();

        if (fee > 0) {
            (bool feeOk,) = platformWallet.call{value: fee}("");
            if (!feeOk) revert TransferFailed();
        }
        uint256 extraEth = msg.value - fee;

        address creator = p.feeWallet == address(0) ? msg.sender : p.feeWallet;

        (address token0, address token1) = token < p.quoteToken ? (token, p.quoteToken) : (p.quoteToken, token);
        bool tokenIsCurrency1 = token > p.quoteToken;

        int24 tick;
        (tick, poolId) = _initPool(p.positionManager, dex.hook, token0, token1, token, p.quoteToken, creator, p.hookFeeBps, p.creatorBps, p.vaultBps, p.burnBps, p.launchMarketCap, totalSupply);

        (int24 tickLower, int24 tickUpper, uint128 liquidity) = _computeOneSidedLiquidity(tick, tokenIsCurrency1, totalSupply);

        _mintV4(dex.singleton, dex.hook, token0, token1, tickLower, tickUpper, liquidity);

        // Vault/lending is opt-in: vaultBps == 0 skips deploying one entirely, so that token has no
        // borrowing support (vault() stays address(0)) and claimFees' vault/creator split degrades
        // to paying the creator that whole share -- same as when a vault deposit fails.
        if (vaultFactory != address(0) && p.vaultBps > 0) {
            address vault = IDuckVaultFactoryLocal(vaultFactory).createVault(token, IERC20DecimalsLocal(token).decimals(), creator);
            address vaultCurrency = p.quoteToken == address(0) ? weth : p.quoteToken;

            (uint8 vaultCurrencyDecimals, bool decOk) =
                p.quoteToken == address(0) ? (18, true) : _safeDecimals(p.quoteToken);
            if (decOk) {

                try IDuckVaultLinkLocal(vault).linkPool(vaultCurrency, poolId, !tokenIsCurrency1, vaultCurrencyDecimals, p.quoteToken == address(0)) {} catch {}
            }
        }

        if (extraEth > 0) {
            try this.instantBuy{value: extraEth}(
                p.quoteToken, token, extraEth, p.minQuoteOut, p.minTokensOut,
                dex.singleton, dex.hook, msg.sender
            ) {} catch {
                if (p.revertOnInstantBuyFailure) revert InstantBuyFailed();
                (bool refundOk,) = msg.sender.call{value: extraEth}("");
                if (!refundOk) revert TransferFailed();
                emit InstantBuySkipped(token, extraEth);
            }
        }

        // No creator allocation: the entire supply is meant to back the LP position. Whatever
        // rounding dust the one-sided liquidity mint leaves behind (if any) stays here, recoverable
        // only by the protocol owner via rescueERC20 -- never sent to msg.sender/the creator.
        IDuckLauncherToken(token).renounceOwnership();

        emit TokenLaunched(token, creator, p.positionManager, p.quoteToken, dex.hook, poolId);
    }

    receive() external payable {}

    function _initPool(
        address positionManager_,
        address hook_,
        address token0,
        address token1,
        address token,
        address quoteToken_,
        address creator,
        uint256 hookFeeBps_,
        uint16  creatorBps_,
        uint16  vaultBps_,
        uint16  burnBps_,
        uint256 launchMarketCap_,
        uint256 totalSupply
    ) private returns (int24 tick, bytes32 poolId) {
        (tick, poolId, ) = V4Minting.initAndRegisterPool(V4Minting.RegisterPoolParams({
            positionManager: positionManager_,
            hook:            hook_,
            token0:          token0,
            token1:          token1,
            fee:             FEE_TIER,
            tickSpacing:     TICK_SPACING,
            sqrtPriceX96:    _computeSqrtPriceX96(token, quoteToken_, launchMarketCap_, totalSupply),
            token:           token,
            creator:         creator,
            hookFeeBps:      hookFeeBps_,
            creatorBps:      creatorBps_,
            vaultBps:        vaultBps_,
            burnBps:         burnBps_
        }));
    }

    function _computeOneSidedLiquidity(int24 currentTick, bool tokenIsCurrency1, uint256 totalSupply)
        private pure returns (int24 tickLower, int24 tickUpper, uint128 liquidity)
    {
        return V4Minting.computeOneSidedLiquidity(currentTick, tokenIsCurrency1, TICK_SPACING, totalSupply);
    }

    function instantBuy(
        address quoteToken_,
        address token_,
        uint256 extraEth_,
        uint256 minQuoteOut_,
        uint256 minTokensOut_,
        address singleton_,
        address hook_,
        address recipient_
    ) external payable {
        if (msg.sender != address(this)) revert Unauthorized();

        uint256 quoteAmount = extraEth_;
        if (quoteToken_ != address(0)) {
            bool ok;
            (quoteAmount, ok) = _acquireQuoteToken(quoteToken_, extraEth_, minQuoteOut_, address(this));
            if (!ok) revert InstantBuyFailed();
        }

        uint256 tokensOut = _executeV4Swap(singleton_, hook_, FEE_TIER, TICK_SPACING, quoteToken_, token_, quoteAmount, minTokensOut_, recipient_);
        if (tokensOut < minTokensOut_) revert InstantBuyFailed();
    }

    // No position NFT or locker: liquidity goes straight into the PoolManager singleton, owned by
    // this contract permanently (see LaunchRouting._mintFullRangeDirect) -- the same "can never be
    // rugged" guarantee a burned NFT gave, without minting one or needing Permit2 approvals.
    function _mintV4(
        address singleton_,
        address hook_,
        address token0,
        address token1,
        int24   tickLower,
        int24   tickUpper,
        uint128 liquidity
    ) private {
        PoolKey memory key = PoolKey({
            currency0:   token0,
            currency1:   token1,
            fee:         FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks:       hook_
        });
        _mintFullRangeDirect(singleton_, key, tickLower, tickUpper, liquidity);
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

    function _deployAndInit(
        string calldata name_,
        string calldata symbol_,
        string calldata metaURI_,
        bytes32         vanitySalt_,
        uint256         totalSupply
    ) private returns (address token) {
        bytes32 salt = keccak256(abi.encode(msg.sender, vanitySalt_));
        token = _clone(tokenImpl, salt);
        if (uint16(uint160(token)) != VANITY_SUFFIX) revert VanityAddressRequired();
        IDuckLauncherToken(token).initToken(name_, symbol_, totalSupply, false, metaURI_);
    }

    function _computeSqrtPriceX96(address tokenAddr, address quoteToken_, uint256 launchMarketCap_, uint256 totalSupply)
        private pure returns (uint160)
    {
        if (tokenAddr < quoteToken_) {
            return V4Math.sqrtPriceX96FromAmounts(totalSupply, launchMarketCap_);
        } else {
            return V4Math.sqrtPriceX96FromAmounts(launchMarketCap_, totalSupply);
        }
    }

    function _safeDecimals(address token_) private view returns (uint8 dec, bool ok) {
        (bool success, bytes memory data) = token_.staticcall(abi.encodeWithSelector(IERC20DecimalsLocal.decimals.selector));
        if (success && data.length >= 32) {
            uint256 raw;
            assembly ("memory-safe") {
                raw := mload(add(data, 32))
            }
            if (raw <= type(uint8).max) {
                dec = uint8(raw);
                ok = true;
            }
        }
    }

    function _isValidHookFeeBps(uint256 bps) private pure returns (bool) {
        // Any rate up to 10% (DuckGenesisHook's MAX_HOOK_FEE_BPS); 0 still means the hook's 2% default.
        return bps <= 1000;
    }

}
