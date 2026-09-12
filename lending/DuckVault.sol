// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {DuckVaultMath} from "./DuckVaultMath.sol";
import {LaunchRouting} from "duck-lib/LaunchRouting.sol";

interface IERC20Vault {
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ITokenSupplyVault {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
}

interface IWETH9Vault {
    function withdraw(uint256 amount) external;
}

interface IDuckVaultConfigRead {
    function maxLtvBps() external view returns (uint16);
    function liquidationThresholdBps() external view returns (uint16);
    function liquidationBonusBps() external view returns (uint16);
    function closeFactorBps() external view returns (uint16);
    function maxBorrowerShareBps() external view returns (uint16);
    function maxUtilizationBps() external view returns (uint16);
    function shortWindow() external view returns (uint32);
    function longWindow() external view returns (uint32);
    function kinkBps() external view returns (uint16);
    function baseRateBps() external view returns (uint16);
    function slope1Bps() external view returns (uint16);
    function slope2Bps() external view returns (uint16);
    function minLoan(address currency) external view returns (uint256);
    function buybackBps() external view returns (uint16);
    function maxPoolDepthShareBps() external view returns (uint16);
    function maxCirculatingShareBps() external view returns (uint16);
    function minPoolAge() external view returns (uint32);
}

interface IDuckHookV4Vault {
    function observe(bytes32 poolId, uint32 secondsAgo) external view returns (int24 avgTick, bool valid);
    function poolManager() external view returns (address);
    function poolLiquidity(bytes32 poolId) external view returns (uint128 liquidity, bool ok);
}

interface IDuckVaultFactoryVault {
    function governorFactory() external view returns (address);
    function approvedVaultImpl(address impl) external view returns (bool);
}

contract DuckVault is Initializable, UUPSUpgradeable, LaunchRouting {
    error ZeroAddress();
    error NotTrustedCaller();
    error MarketDisabled();
    error ZeroAmount();
    error ExceedsMaxLtv();
    error ExceedsBorrowerShare();
    error ExceedsPoolDepthShare();
    error PoolDepthUnavailable();
    error ExceedsCirculatingShare();
    error UtilizationTooHigh();
    error InsufficientLiquidity();
    error BelowMinLoan();
    error NoDebt();
    error InsufficientCollateral();
    error NotLiquidatable();
    error OracleUnavailable();
    error NotGovernor();
    error GovernorAlreadySet();
    error AlreadyLinked();
    error NotManager();
    error ImplementationNotApproved();
    error Reentrant();
    error PoolTooYoung();

    uint256 private constant BPS_DENOM = 10_000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;
    // Must match the pool's actual native fee tier exactly -- it's part of the PoolKey hash used to
    // reconstruct this pool's poolId for the buyback swap below. All three launch families now mint
    // pools at 0% (the hook fee is the sole trading fee; see DuckHookV4.claimFees).
    uint24  private constant FEE_TIER     = 0;
    int24   private constant TICK_SPACING = 200;

    address public token;
    address public currency;
    bytes32 public poolId;
    uint8   public tokenDecimals;
    uint8   public currencyDecimals;
    bool    public tokenIsCurrency0;
    bool    public enabled;

    bool public poolQuoteIsNative;
    uint40  public poolLinkedAt;

    address public creator;
    address public manager;

    uint128 public totalReserves;
    uint128 public totalBorrows;
    uint128 public totalCollateral;
    uint256 public borrowIndex;
    uint40  public lastAccrual;

    uint128 public pendingBuyback;

    bool private _locked;

    struct Loan { uint128 collateral; uint128 principal; uint256 indexSnap; uint40 openedAt; }
    mapping(address => Loan) public loans;

    address public config;
    address public hook;
    address public family;
    address public factory;
    address public governor;

    event Deposited(address indexed from, uint256 amount);
    event Borrowed(address indexed borrower, uint256 amount, uint256 newDebt);
    event Repaid(address indexed borrower, uint256 amount, uint256 remainingDebt);
    event CollateralAdded(address indexed borrower, uint256 amount);
    event CollateralWithdrawn(address indexed borrower, uint256 amount);
    event Liquidated(address indexed borrower, address indexed liquidator, uint256 repaid, uint256 seized);
    event BadDebtRealized(address indexed borrower, uint256 amount);
    event GovernorSet(address indexed governor);
    event Withdrawn(address indexed to, uint256 amount);
    event Enabled(bool enabled);
    event BuybackQueued(uint256 amount);
    event BuybackExecuted(uint256 currencyIn, uint256 tokensBurned);
    event PoolLinked(address indexed currency, bytes32 indexed poolId);
    event CreatorSet(address indexed creator);

    constructor() {
        _disableInitializers();
    }

    // currency is an arbitrary permissionless quote token chosen at launch, so it can't be trusted
    // not to invoke recipient code on transfer. Guards every state-mutating function that moves
    // currency or token, closing same- and cross-function reentrancy through an ERC777-style hook.
    modifier nonReentrant() {
        if (_locked) revert Reentrant();
        _locked = true;
        _;
        _locked = false;
    }

    function initialize(
        address token_, uint8 tokenDecimals_, address creator_,
        address config_, address hook_, address family_
    ) external initializer {
        if (token_ == address(0) || creator_ == address(0) || config_ == address(0) || hook_ == address(0) || family_ == address(0)) {
            revert ZeroAddress();
        }
        token = token_;
        tokenDecimals = tokenDecimals_;
        creator = creator_;
        manager = hook_;
        config = config_;
        hook = hook_;
        family = family_;
        factory = msg.sender;
        borrowIndex = 1e18;
        lastAccrual = uint40(block.timestamp);
    }

    function _authorizeUpgrade(address newImplementation) internal override {
        if (msg.sender != governor) revert NotGovernor();
        if (!IDuckVaultFactoryVault(factory).approvedVaultImpl(newImplementation)) revert ImplementationNotApproved();
    }

    function linkPool(
        address currency_, bytes32 poolId_, bool tokenIsCurrency0_, uint8 currencyDecimals_, bool poolQuoteIsNative_
    ) external {
        if (msg.sender != family) revert NotTrustedCaller();
        if (enabled) revert AlreadyLinked();
        if (currency_ == address(0)) revert ZeroAddress();
        currency = currency_;
        poolId = poolId_;
        tokenIsCurrency0 = tokenIsCurrency0_;
        currencyDecimals = currencyDecimals_;
        poolQuoteIsNative = poolQuoteIsNative_;
        poolLinkedAt = uint40(block.timestamp);
        enabled = true;
        emit PoolLinked(currency_, poolId_);
        emit Enabled(true);
    }

    function setCreator(address newCreator) external {
        if (msg.sender != manager) revert NotManager();
        if (newCreator == address(0)) revert ZeroAddress();
        creator = newCreator;
        emit CreatorSet(newCreator);
    }

    modifier onlyTrustedDepositor() {
        if (msg.sender != hook && msg.sender != family) revert NotTrustedCaller();
        _;
    }

    // Deliberately NOT nonReentrant: triggerBuyback's swap legitimately loops back here via the
    // hook's auto-claim while its lock is still held. Safe on its own merits -- trusted callers only,
    // and a plain += with state committed before the external call.
    function depositFees(uint256 amount) external onlyTrustedDepositor {
        if (amount == 0) return;
        totalReserves += SafeCast.toUint128(amount);
        if (!IERC20Vault(currency).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        emit Deposited(msg.sender, amount);
    }

    function _accrue() private {
        uint40 nowTs = uint40(block.timestamp);
        uint40 elapsed = nowTs - lastAccrual;
        if (elapsed == 0) return;
        IDuckVaultConfigRead cfg = IDuckVaultConfigRead(config);
        uint256 utilBps = DuckVaultMath.utilizationBps(totalBorrows, totalReserves);
        uint256 rateBps = DuckVaultMath.borrowRateBps(
            utilBps, cfg.kinkBps(), cfg.baseRateBps(), cfg.slope1Bps(), cfg.slope2Bps()
        );
        (uint256 interest, uint256 newIndex) = DuckVaultMath.accrueInterest(totalBorrows, borrowIndex, rateBps, elapsed);
        if (interest > 0) {
            totalBorrows += SafeCast.toUint128(interest);
            borrowIndex = newIndex;
        }
        lastAccrual = nowTs;
    }

    function _priceForBorrow() private view returns (uint256) {
        IDuckVaultConfigRead cfg = IDuckVaultConfigRead(config);
        (int24 tickShort, bool okShort) = IDuckHookV4Vault(hook).observe(poolId, cfg.shortWindow());
        (int24 tickLong, bool okLong) = IDuckHookV4Vault(hook).observe(poolId, cfg.longWindow());
        if (!okShort || !okLong) revert OracleUnavailable();
        uint256 pShort = DuckVaultMath.tickToPricePerToken(tickShort, tokenIsCurrency0, tokenDecimals);
        uint256 pLong = DuckVaultMath.tickToPricePerToken(tickLong, tokenIsCurrency0, tokenDecimals);
        return pShort < pLong ? pShort : pLong;
    }

    function _priceForLiquidation() private view returns (uint256) {
        IDuckVaultConfigRead cfg = IDuckVaultConfigRead(config);
        (int24 tickShort, bool okShort) = IDuckHookV4Vault(hook).observe(poolId, cfg.shortWindow());
        (int24 tickLong, bool okLong) = IDuckHookV4Vault(hook).observe(poolId, cfg.longWindow());
        if (!okShort || !okLong) revert OracleUnavailable();
        uint256 pShort = DuckVaultMath.tickToPricePerToken(tickShort, tokenIsCurrency0, tokenDecimals);
        uint256 pLong = DuckVaultMath.tickToPricePerToken(tickLong, tokenIsCurrency0, tokenDecimals);
        return pShort > pLong ? pShort : pLong;
    }

    function _checkExposureGuards(uint128 collateral, uint256 collateralVal, IDuckVaultConfigRead cfg) private view {
        (uint128 liquidity, bool liqOk) = IDuckHookV4Vault(hook).poolLiquidity(poolId);
        if (!liqOk) revert PoolDepthUnavailable();

        (int24 tick, bool tickOk) = IDuckHookV4Vault(hook).observe(poolId, cfg.shortWindow());
        if (!tickOk) revert OracleUnavailable();

        uint256 depth = DuckVaultMath.poolCurrencyDepth(tick, liquidity, tokenIsCurrency0);
        if (collateralVal * BPS_DENOM > depth * cfg.maxPoolDepthShareBps()) revert ExceedsPoolDepthShare();

        uint256 circulating = ITokenSupplyVault(token).totalSupply() - ITokenSupplyVault(token).balanceOf(DEAD);
        if (circulating > 0 && uint256(collateral) * BPS_DENOM > circulating * cfg.maxCirculatingShareBps()) {
            revert ExceedsCirculatingShare();
        }
    }

    function borrow(uint256 amount) external nonReentrant {
        if (!enabled) revert MarketDisabled();
        if (amount == 0) revert ZeroAmount();
        _accrue();

        IDuckVaultConfigRead cfg = IDuckVaultConfigRead(config);
        // Defense-in-depth alongside DuckHookV4.observe()'s not-enough-history reporting: block
        // borrowing outright until the pool reaches minPoolAge, so a freshly-launched, thinly-traded
        // pool can never back a loan at all.
        if (block.timestamp < uint256(poolLinkedAt) + cfg.minPoolAge()) revert PoolTooYoung();
        if (amount < cfg.minLoan(currency)) revert BelowMinLoan();
        if (amount > totalReserves) revert InsufficientLiquidity();

        Loan storage loan = loans[msg.sender];
        uint256 existingDebt = DuckVaultMath.currentDebt(loan.principal, loan.indexSnap, borrowIndex);
        uint256 newDebt = existingDebt + amount;

        uint256 price = _priceForBorrow();
        uint256 collateralVal = DuckVaultMath.collateralValue(loan.collateral, price, tokenDecimals);
        if (newDebt * BPS_DENOM > collateralVal * cfg.maxLtvBps()) revert ExceedsMaxLtv();
        _checkExposureGuards(loan.collateral, collateralVal, cfg);

        uint128 newTotalBorrows = totalBorrows + SafeCast.toUint128(amount);
        uint128 newTotalReserves = totalReserves - SafeCast.toUint128(amount);
        if (DuckVaultMath.utilizationBps(newTotalBorrows, newTotalReserves) > cfg.maxUtilizationBps()) {
            revert UtilizationTooHigh();
        }
        if (newDebt * BPS_DENOM > uint256(newTotalBorrows + newTotalReserves) * cfg.maxBorrowerShareBps()) {
            revert ExceedsBorrowerShare();
        }

        loan.principal = SafeCast.toUint128(newDebt);
        loan.indexSnap = borrowIndex;
        if (loan.openedAt == 0) loan.openedAt = uint40(block.timestamp);

        totalBorrows = newTotalBorrows;
        totalReserves = newTotalReserves;

        if (!IERC20Vault(currency).transfer(msg.sender, amount)) revert TransferFailed();
        emit Borrowed(msg.sender, amount, newDebt);
    }

    function repay(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrue();
        Loan storage loan = loans[msg.sender];
        uint256 debtAtCheckpoint = loan.principal;
        uint256 debt = DuckVaultMath.currentDebt(loan.principal, loan.indexSnap, borrowIndex);
        if (debt == 0) revert NoDebt();

        uint256 payAmount = amount > debt ? debt : amount;
        uint256 remainingDebt = debt - payAmount;
        loan.principal = SafeCast.toUint128(remainingDebt);
        loan.indexSnap = borrowIndex;

        totalBorrows -= SafeCast.toUint128(payAmount);
        totalReserves += SafeCast.toUint128(payAmount);

        _earmarkBuyback(debt, debtAtCheckpoint, payAmount);

        if (!IERC20Vault(currency).transferFrom(msg.sender, address(this), payAmount)) revert TransferFailed();

        emit Repaid(msg.sender, payAmount, remainingDebt);
    }

    function _earmarkBuyback(uint256 debtNow, uint256 debtAtCheckpoint, uint256 amountCleared) private {
        uint256 interestAccrued = debtNow > debtAtCheckpoint ? debtNow - debtAtCheckpoint : 0;
        if (interestAccrued == 0) return;
        uint256 interestPortion = amountCleared < interestAccrued ? amountCleared : interestAccrued;
        uint256 cut = (interestPortion * IDuckVaultConfigRead(config).buybackBps()) / BPS_DENOM;
        if (cut == 0) return;
        pendingBuyback += SafeCast.toUint128(cut);
        emit BuybackQueued(cut);
    }

    function addCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (!IERC20Vault(token).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();
        loans[msg.sender].collateral += SafeCast.toUint128(amount);
        totalCollateral += SafeCast.toUint128(amount);
        emit CollateralAdded(msg.sender, amount);
    }

    function withdrawCollateral(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _accrue();
        Loan storage loan = loans[msg.sender];
        if (amount > loan.collateral) revert InsufficientCollateral();
        uint128 newCollateral = loan.collateral - SafeCast.toUint128(amount);

        uint256 debt = DuckVaultMath.currentDebt(loan.principal, loan.indexSnap, borrowIndex);
        if (debt > 0) {
            uint256 price = _priceForBorrow();
            uint256 collateralVal = DuckVaultMath.collateralValue(newCollateral, price, tokenDecimals);
            IDuckVaultConfigRead cfg = IDuckVaultConfigRead(config);
            if (debt * BPS_DENOM > collateralVal * cfg.maxLtvBps()) revert ExceedsMaxLtv();
        }

        loan.collateral = newCollateral;
        totalCollateral -= SafeCast.toUint128(amount);
        if (!IERC20Vault(token).transfer(msg.sender, amount)) revert TransferFailed();
        emit CollateralWithdrawn(msg.sender, amount);
    }

    function liquidate(address borrower, uint256 repayAmount) external nonReentrant {
        if (repayAmount == 0) revert ZeroAmount();
        _accrue();
        Loan storage loan = loans[borrower];
        uint256 debtAtCheckpoint = loan.principal;
        uint256 debt = DuckVaultMath.currentDebt(loan.principal, loan.indexSnap, borrowIndex);
        if (debt == 0) revert NoDebt();

        IDuckVaultConfigRead cfg = IDuckVaultConfigRead(config);
        uint256 price = _priceForLiquidation();
        uint256 collateralVal = DuckVaultMath.collateralValue(loan.collateral, price, tokenDecimals);
        if (!DuckVaultMath.isLiquidatable(debt, collateralVal, cfg.liquidationThresholdBps())) revert NotLiquidatable();

        uint256 maxRepay = (debt * cfg.closeFactorBps()) / BPS_DENOM;
        uint256 actualRepay = repayAmount > maxRepay ? maxRepay : repayAmount;

        (uint256 seize, uint256 badDebtOnCapped) = DuckVaultMath.computeSeize(
            actualRepay, price, tokenDecimals, cfg.liquidationBonusBps(), loan.collateral
        );

        uint256 liquidatorPays;
        uint256 principalCleared;
        uint256 badDebtFinal;

        if (badDebtOnCapped > 0) {
            (seize, badDebtFinal) = DuckVaultMath.computeSeize(debt, price, tokenDecimals, cfg.liquidationBonusBps(), loan.collateral);
            liquidatorPays = debt - badDebtFinal;
            principalCleared = debt;
        } else {
            liquidatorPays = actualRepay;
            principalCleared = actualRepay;
        }

        loan.collateral -= SafeCast.toUint128(seize);
        loan.principal = SafeCast.toUint128(debt - principalCleared);
        loan.indexSnap = borrowIndex;

        totalCollateral -= SafeCast.toUint128(seize);
        totalBorrows -= SafeCast.toUint128(principalCleared);
        totalReserves += SafeCast.toUint128(liquidatorPays);

        _earmarkBuyback(debt, debtAtCheckpoint, liquidatorPays);

        if (!IERC20Vault(currency).transferFrom(msg.sender, address(this), liquidatorPays)) revert TransferFailed();
        if (!IERC20Vault(token).transfer(msg.sender, seize)) revert TransferFailed();

        if (badDebtFinal > 0) emit BadDebtRealized(borrower, badDebtFinal);
        emit Liquidated(borrower, msg.sender, liquidatorPays, seize);
    }

    function triggerBuyback() external nonReentrant returns (uint256 burned) {
        uint256 amount = pendingBuyback;
        if (amount > totalReserves) amount = totalReserves;
        if (amount == 0) return 0;

        pendingBuyback -= SafeCast.toUint128(amount);
        totalReserves -= SafeCast.toUint128(amount);

        address swapCurrencyIn = currency;
        if (poolQuoteIsNative) {
            IWETH9Vault(currency).withdraw(amount);
            swapCurrencyIn = address(0);
        }

        burned = _executeV4Swap(
            IDuckHookV4Vault(hook).poolManager(), hook, FEE_TIER, TICK_SPACING,
            swapCurrencyIn, token, amount, 0, address(this)
        );
        if (burned > 0) {
            if (!IERC20Vault(token).transfer(DEAD, burned)) revert TransferFailed();
        }
        emit BuybackExecuted(amount, burned);
    }

    function setGovernor(address governor_) external {
        if (msg.sender != IDuckVaultFactoryVault(factory).governorFactory()) revert NotTrustedCaller();
        if (governor != address(0)) revert GovernorAlreadySet();
        if (governor_ == address(0)) revert ZeroAddress();
        governor = governor_;
        emit GovernorSet(governor_);
    }

    function withdraw(uint256 amount, address to) external nonReentrant {
        if (msg.sender != governor) revert NotGovernor();
        if (to == address(0)) revert ZeroAddress();
        if (amount > totalReserves) revert InsufficientLiquidity();
        totalReserves -= SafeCast.toUint128(amount);
        if (!IERC20Vault(currency).transfer(to, amount)) revert TransferFailed();
        emit Withdrawn(to, amount);
    }

    function healthFactorBps(address borrower) external view returns (uint256) {
        Loan memory loan = loans[borrower];
        uint256 debt = DuckVaultMath.currentDebt(loan.principal, loan.indexSnap, borrowIndex);
        if (debt == 0) return type(uint256).max;
        uint256 price = _priceForLiquidation();
        uint256 collateralVal = DuckVaultMath.collateralValue(loan.collateral, price, tokenDecimals);
        return DuckVaultMath.healthFactorBps(debt, collateralVal, IDuckVaultConfigRead(config).liquidationThresholdBps());
    }

    receive() external payable {}
}
