// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — DuckWheel
//
// A daily prize wheel for $DUCK holders: eligibility is holding MIN_DUCK_BALANCE of $DUCK (an
// owner-configurable address, since $DUCK hasn't launched yet). The wheel carries up to 8 tokens --
// slot 0 is always $DUCK, 1-3 are DuckProtocol-launched tokens, 4-7 are registered "stock" tokens
// (setStockToken). Picks are pushed in by an owner call, rate-limited to once per ROTATION_INTERVAL
// so the daily cadence is enforced on-chain; choosing WHAT to push is a future backend's job.
//
// Randomness comes from DuckVRF -- a from-scratch, Pyth-Entropy-inspired commit/reveal hash chain,
// since neither Chainlink VRF nor Pyth Entropy is deployed on Robinhood Chain. A spin is two
// transactions: spin() requests randomness and locks in the player; resolveSpin() (permissionless,
// once the provider has revealed) reads the result and pays out from the 30-slot prize table.
//
// Prize payouts are owner-configurable via setPrizeTable rather than hardcoded. What IS enforced
// on-chain: exactly 30 slots, odds summing to precisely 100%, each slot within [0.1%, 30%], and
// "No Prize" carrying the single highest odds -- the most likely outcome is deliberately nothing.
//
// Prizes pay from this contract's own balances, a manually funded treasury isolated from all other
// protocol funds. Top up with plain ERC20 transfers; withdrawTreasury pulls unused funds back out.

interface IDuckVRF {
    function request(address provider, bytes32 userRandomNumber) external returns (uint64 sequenceNumber);
    function getRandomNumber(address provider, uint64 sequenceNumber)
        external
        view
        returns (bytes32 randomNumber, bool fulfilled);
}

interface IERC20Minimal {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract DuckWheel {
    error NotOwner();
    error ZeroAddress();
    error NotEligible();
    error PrizeTableNotSet();
    error SpinOnCooldown();
    error NoPendingSpin();
    error NotYetRevealed();
    error AlreadyResolved();
    error InvalidWheelTokenIndex();
    error InvalidStockToken();
    error TooSoonToRotate();
    error OddsOutOfRange();
    error OddsMustSumToWhole();
    error NoPrizeMustBeHighestOdds();

    uint256 public constant MIN_DUCK_BALANCE = 50_000e18;
    uint256 public constant WHEEL_SIZE = 8;
    uint256 public constant PRIZE_SLOTS = 30;
    uint256 public constant BPS_DENOM = 10_000;
    uint16 public constant MIN_ODDS_BPS = 10; // 0.1%
    uint16 public constant MAX_ODDS_BPS = 3000; // 30% -- the ceiling any single slot (including No Prize) may hit
    uint256 public constant ROTATION_INTERVAL = 1 days;
    uint256 public constant SPIN_COOLDOWN = 1 days;

    address public owner;
    address public vrf;
    address public vrfProvider;
    address public duckToken;

    address[8] public wheelTokens; // index 0 is always duckToken
    uint256 public lastDuckProtocolRotation;
    uint256 public lastStockRotation;

    mapping(address => bool) public isStockToken;
    address[] public stockTokenList;

    struct PrizeSlot {
        uint8 wheelTokenIndex; // ignored when isNoPrize
        uint256 amount;
        uint16 oddsBps;
        bool isNoPrize;
    }

    PrizeSlot[30] public prizeTable;
    bool public prizeTableSet;

    struct PendingSpin {
        address player;
        bool resolved;
    }

    mapping(uint64 => PendingSpin) public pendingSpins; // keyed by DuckVRF sequenceNumber
    mapping(address => uint256) public lastSpinAt;
    uint256 private _spinNonce;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event DuckTokenSet(address indexed token);
    event WheelTokenSet(uint256 indexed index, address indexed token);
    event StockTokenRegistered(address indexed token, bool listed);
    event PrizeTableUpdated();
    event SpinRequested(address indexed player, uint64 indexed sequenceNumber);
    event SpinResolved(
        address indexed player, uint64 indexed sequenceNumber, uint8 prizeSlot, address token, uint256 amount, bool noPrize
    );

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(address vrf_, address vrfProvider_, address duckToken_) {
        if (vrf_ == address(0) || vrfProvider_ == address(0)) revert ZeroAddress();
        owner = msg.sender;
        vrf = vrf_;
        vrfProvider = vrfProvider_;
        duckToken = duckToken_;
        if (duckToken_ != address(0)) wheelTokens[0] = duckToken_;
    }

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, newOwner);
        owner = newOwner;
    }

    // $DUCK hasn't launched yet -- this lets the owner point eligibility/wheel-slot-0 at the real
    // token the moment it does, without redeploying this contract.
    function setDuckToken(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        duckToken = token;
        wheelTokens[0] = token;
        emit DuckTokenSet(token);
        emit WheelTokenSet(0, token);
    }

    function setStockToken(address token, bool listed) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (isStockToken[token] == listed) return;
        isStockToken[token] = listed;
        if (listed) {
            stockTokenList.push(token);
        } else {
            uint256 len = stockTokenList.length;
            for (uint256 i; i < len; ++i) {
                if (stockTokenList[i] == token) {
                    stockTokenList[i] = stockTokenList[len - 1];
                    stockTokenList.pop();
                    break;
                }
            }
        }
        emit StockTokenRegistered(token, listed);
    }

    function stockTokenCount() external view returns (uint256) {
        return stockTokenList.length;
    }

    // Sets the 3 daily DuckProtocol-launched token picks (wheel slots 1-3). Picked off-chain today --
    // see the file header for why -- rate-limited to once per ROTATION_INTERVAL so the "daily"
    // cadence is a real on-chain guarantee regardless of who or what ends up calling this.
    function setDailyDuckProtocolTokens(address[3] calldata tokens) external onlyOwner {
        if (lastDuckProtocolRotation != 0 && block.timestamp < lastDuckProtocolRotation + ROTATION_INTERVAL) {
            revert TooSoonToRotate();
        }
        lastDuckProtocolRotation = block.timestamp;
        for (uint256 i; i < 3; ++i) {
            if (tokens[i] == address(0)) revert ZeroAddress();
            wheelTokens[1 + i] = tokens[i];
            emit WheelTokenSet(1 + i, tokens[i]);
        }
    }

    // Sets the 4 daily stock-token picks (wheel slots 4-7) -- each must already be registered via
    // setStockToken.
    function setDailyStockTokens(address[4] calldata tokens) external onlyOwner {
        if (lastStockRotation != 0 && block.timestamp < lastStockRotation + ROTATION_INTERVAL) {
            revert TooSoonToRotate();
        }
        lastStockRotation = block.timestamp;
        for (uint256 i; i < 4; ++i) {
            if (!isStockToken[tokens[i]]) revert InvalidStockToken();
            wheelTokens[4 + i] = tokens[i];
            emit WheelTokenSet(4 + i, tokens[i]);
        }
    }

    // Full 30-slot prize table. Enforced invariants: odds sum to exactly 100% (10_000 bps), every
    // slot's odds fall within [MIN_ODDS_BPS, MAX_ODDS_BPS], and NO_PRIZE -- wherever it sits in the
    // array -- must carry strictly the single highest odds of any slot.
    function setPrizeTable(PrizeSlot[30] calldata slots) external onlyOwner {
        uint256 sum;
        bool sawNoPrize;
        uint16 noPrizeOdds;
        uint16 highestOtherOdds;
        for (uint256 i; i < 30; ++i) {
            PrizeSlot calldata s = slots[i];
            if (s.oddsBps < MIN_ODDS_BPS || s.oddsBps > MAX_ODDS_BPS) revert OddsOutOfRange();
            sum += s.oddsBps;
            if (s.isNoPrize) {
                sawNoPrize = true;
                noPrizeOdds = s.oddsBps;
            } else {
                if (s.wheelTokenIndex >= WHEEL_SIZE) revert InvalidWheelTokenIndex();
                if (s.oddsBps > highestOtherOdds) highestOtherOdds = s.oddsBps;
            }
            prizeTable[i] = s;
        }
        if (sum != BPS_DENOM) revert OddsMustSumToWhole();
        if (!sawNoPrize || noPrizeOdds <= highestOtherOdds) revert NoPrizeMustBeHighestOdds();
        prizeTableSet = true;
        emit PrizeTableUpdated();
    }

    function isEligible(address account) public view returns (bool) {
        if (duckToken == address(0)) return false;
        return IERC20Minimal(duckToken).balanceOf(account) >= MIN_DUCK_BALANCE;
    }

    function spin() external returns (uint64 sequenceNumber) {
        if (!isEligible(msg.sender)) revert NotEligible();
        if (!prizeTableSet) revert PrizeTableNotSet();
        if (lastSpinAt[msg.sender] != 0 && block.timestamp < lastSpinAt[msg.sender] + SPIN_COOLDOWN) {
            revert SpinOnCooldown();
        }
        lastSpinAt[msg.sender] = block.timestamp;

        bytes32 userRandomNumber =
            keccak256(abi.encode(msg.sender, block.timestamp, block.prevrandao, _spinNonce++));
        sequenceNumber = IDuckVRF(vrf).request(vrfProvider, userRandomNumber);
        pendingSpins[sequenceNumber] = PendingSpin({player: msg.sender, resolved: false});
        emit SpinRequested(msg.sender, sequenceNumber);
    }

    // Permissionless -- anyone can resolve a spin once DuckVRF's provider has revealed the
    // corresponding randomness (see DuckVRF.sol; that reveal step is off-chain infrastructure
    // intentionally out of scope for this pass, so a spin may sit unresolved until it exists).
    function resolveSpin(uint64 sequenceNumber) external {
        PendingSpin storage spinInfo = pendingSpins[sequenceNumber];
        if (spinInfo.player == address(0)) revert NoPendingSpin();
        if (spinInfo.resolved) revert AlreadyResolved();

        (bytes32 randomNumber, bool fulfilled) = IDuckVRF(vrf).getRandomNumber(vrfProvider, sequenceNumber);
        if (!fulfilled) revert NotYetRevealed();

        spinInfo.resolved = true; // checks-effects-interactions -- before any external call below

        uint256 roll = uint256(randomNumber) % BPS_DENOM;
        uint256 cumulative;
        for (uint256 i; i < 30; ++i) {
            PrizeSlot storage s = prizeTable[i];
            cumulative += s.oddsBps;
            if (roll < cumulative) {
                if (s.isNoPrize) {
                    emit SpinResolved(spinInfo.player, sequenceNumber, uint8(i), address(0), 0, true);
                } else {
                    address token = wheelTokens[s.wheelTokenIndex];
                    IERC20Minimal(token).transfer(spinInfo.player, s.amount);
                    emit SpinResolved(spinInfo.player, sequenceNumber, uint8(i), token, s.amount, false);
                }
                return;
            }
        }
    }

    function withdrawTreasury(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC20Minimal(token).transfer(to, amount);
    }
}
