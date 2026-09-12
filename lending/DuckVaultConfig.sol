// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckVaultConfig

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

contract DuckVaultConfig is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable {
    error InvalidBps();
    error InvalidWindow();

    uint16 public constant BPS_DENOM = 10_000;

    uint16 public maxLtvBps;
    uint16 public liquidationThresholdBps;
    uint16 public liquidationBonusBps;
    uint16 public closeFactorBps;
    uint16 public maxBorrowerShareBps;
    uint16 public buybackBps;
    uint16 public maxPoolDepthShareBps;
    uint16 public maxCirculatingShareBps;

    uint16 public maxUtilizationBps;
    uint32 public minPoolAge;
    uint32 public shortWindow;
    uint32 public longWindow;

    uint16 public kinkBps;
    uint16 public baseRateBps;
    uint16 public slope1Bps;
    uint16 public slope2Bps;

    mapping(address currency => uint256) public minLoan;

    event MaxLtvUpdated(uint16 bps);
    event LiquidationThresholdUpdated(uint16 bps);
    event LiquidationBonusUpdated(uint16 bps);
    event CloseFactorUpdated(uint16 bps);
    event MaxBorrowerShareUpdated(uint16 bps);
    event BuybackBpsUpdated(uint16 bps);
    event MaxPoolDepthShareUpdated(uint16 bps);
    event MaxCirculatingShareUpdated(uint16 bps);
    event MaxUtilizationUpdated(uint16 bps);
    event MinPoolAgeUpdated(uint32 seconds_);
    event OracleWindowsUpdated(uint32 shortWindow, uint32 longWindow);
    event InterestCurveUpdated(uint16 kinkBps, uint16 baseRateBps, uint16 slope1Bps, uint16 slope2Bps);
    event MinLoanUpdated(address indexed currency, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_) external initializer {
        __Ownable_init(owner_);
        __Ownable2Step_init();

        maxLtvBps               = 3000;
        liquidationThresholdBps = 7500;
        liquidationBonusBps     = 800;
        closeFactorBps          = 5000;
        maxBorrowerShareBps     = 2500;
        buybackBps              = 2000;
        maxPoolDepthShareBps    = 2000;
        maxCirculatingShareBps  = 1000;
        maxUtilizationBps       = 9000;
        minPoolAge              = 24 hours;
        shortWindow             = 1800;
        longWindow              = 14400;

        kinkBps      = 8000;
        baseRateBps  = 200;
        slope1Bps    = 800;
        slope2Bps    = 10000;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function setMaxLtvBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps >= liquidationThresholdBps) revert InvalidBps();
        maxLtvBps = bps;
        emit MaxLtvUpdated(bps);
    }

    function setLiquidationThresholdBps(uint16 bps) external onlyOwner {
        if (bps <= maxLtvBps || bps > BPS_DENOM) revert InvalidBps();
        liquidationThresholdBps = bps;
        emit LiquidationThresholdUpdated(bps);
    }

    function setLiquidationBonusBps(uint16 bps) external onlyOwner {
        if (bps > 2500) revert InvalidBps();
        liquidationBonusBps = bps;
        emit LiquidationBonusUpdated(bps);
    }

    function setCloseFactorBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > BPS_DENOM) revert InvalidBps();
        closeFactorBps = bps;
        emit CloseFactorUpdated(bps);
    }

    function setMaxBorrowerShareBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > BPS_DENOM) revert InvalidBps();
        maxBorrowerShareBps = bps;
        emit MaxBorrowerShareUpdated(bps);
    }

    function setBuybackBps(uint16 bps) external onlyOwner {
        if (bps > BPS_DENOM) revert InvalidBps();
        buybackBps = bps;
        emit BuybackBpsUpdated(bps);
    }

    function setMaxPoolDepthShareBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > BPS_DENOM) revert InvalidBps();
        maxPoolDepthShareBps = bps;
        emit MaxPoolDepthShareUpdated(bps);
    }

    function setMaxCirculatingShareBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > BPS_DENOM) revert InvalidBps();
        maxCirculatingShareBps = bps;
        emit MaxCirculatingShareUpdated(bps);
    }

    function setMaxUtilizationBps(uint16 bps) external onlyOwner {
        if (bps == 0 || bps > BPS_DENOM) revert InvalidBps();
        maxUtilizationBps = bps;
        emit MaxUtilizationUpdated(bps);
    }

    function setMinPoolAge(uint32 seconds_) external onlyOwner {
        minPoolAge = seconds_;
        emit MinPoolAgeUpdated(seconds_);
    }

    function setOracleWindows(uint32 shortWindow_, uint32 longWindow_) external onlyOwner {
        if (shortWindow_ == 0 || longWindow_ <= shortWindow_) revert InvalidWindow();
        shortWindow = shortWindow_;
        longWindow  = longWindow_;
        emit OracleWindowsUpdated(shortWindow_, longWindow_);
    }

    function setInterestCurve(uint16 kinkBps_, uint16 baseRateBps_, uint16 slope1Bps_, uint16 slope2Bps_) external onlyOwner {
        if (kinkBps_ == 0 || kinkBps_ >= BPS_DENOM) revert InvalidBps();
        kinkBps     = kinkBps_;
        baseRateBps = baseRateBps_;
        slope1Bps   = slope1Bps_;
        slope2Bps   = slope2Bps_;
        emit InterestCurveUpdated(kinkBps_, baseRateBps_, slope1Bps_, slope2Bps_);
    }

    function setMinLoan(address currency, uint256 amount) external onlyOwner {
        minLoan[currency] = amount;
        emit MinLoanUpdated(currency, amount);
    }
}
