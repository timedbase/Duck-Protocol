// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// QuiverX -- Liquifier
//
// Replaces the canonical Multicall3 as the approval target for the self-built swap router engine
// (backend/src/chain/router/*), after a real incident: an approval to Multicall3 (a public,
// permissionless "call anything" contract) was drained by a bot within one block of being granted.
// Multicall3 executes whatever (target, calldata) a caller hands it -- including a transferFrom whose
// `from` argument is just calldata, not tied to who's actually calling Multicall3 -- so once a user
// approves it, ANYONE who calls Multicall3 with the right calldata can spend that approval, not just
// the user themselves. A normal DEX router doesn't have this problem because it always pulls from
// msg.sender; Multicall3 breaks that assumption entirely.
//
// This contract restores that assumption. Two things make it safe where Multicall3 wasn't:
//   1. The pull is hardcoded to msg.sender inside executeSwap -- never a parameter, so the only way to
//      trigger a pull of YOUR tokens is to call this contract AS you. No relayer, no third party, no
//      one who merely observes your approval can ever spend it on your behalf.
//   2. Every address this contract will approve or call (the venue routers, Permit2, the InkyPump
//      proxy) is drawn from an owner-maintained allowlist, not arbitrary caller-supplied addresses.
//      Every allowlisted router already only pulls from ITS OWN direct caller (this contract, once
//      it's holding the funds) -- none of them has a "pull from an arbitrary third party" primitive --
//      so even fully attacker-chosen calldata aimed at an allowlisted target can't be turned into
//      theft from someone else's balance.
//
// Backend calldata construction is otherwise unchanged: chain/router/*.ts still builds the exact same
// venue-specific swap calldata it always did; it just targets this contract's executeSwap instead of
// Multicall3's aggregate3Value, and the pull/fee/approvals move from generic calldata into this
// contract's own hardcoded, parameterized logic.

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {Ownable2StepUpgradeable} from "@openzeppelin/contracts-upgradeable/access/Ownable2StepUpgradeable.sol";

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IPermit2Approve {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

contract Liquifier is Initializable, UUPSUpgradeable, Ownable2StepUpgradeable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error ZeroAddress();
    error TargetNotAllowed(address target);
    error FeeTooHigh(uint16 bps);
    error NativeValueMismatch();
    error ApprovalExceedsSwapAmount(uint256 requested, uint256 available);
    error FeeTransferFailed();
    error SwapCallFailed();
    error NothingToRescue();

    // Plain ERC-20 approve(spender, amount) for V2/V3/InkyPump-sell, or Permit2's own approve(token,
    // spender, amount, expiration) for V4 -- see executeSwap. `spender` must itself be allowlisted:
    // the only spenders a real trade ever needs are Permit2 or one of the venue routers/proxies below,
    // so restricting this too closes off even a dust-draining edge case (an approve targeting a
    // non-allowlisted address on whatever balance this contract happens to be holding).
    struct Approval {
        bool viaPermit2;
        address spender;
        uint256 amount;
        uint48 expiration; // only read when viaPermit2 is true
    }

    uint16 public constant MAX_FEE_BPS = 1000; // 10% hard ceiling, matches this codebase's other fee sanity caps
    address private constant NATIVE = address(0);

    address public treasury;
    uint16 public feeBps;
    address public permit2;
    mapping(address => bool) public allowedTargets;

    event TreasurySet(address indexed treasury);
    event FeeBpsSet(uint16 bps);
    event Permit2Set(address indexed permit2);
    event TargetAllowedSet(address indexed target, bool allowed);
    event SwapExecuted(address indexed taker, address indexed sellToken, uint256 sellAmount, uint256 feeAmount, address indexed swapTarget);
    event ETHRescued(address indexed to, uint256 amount);
    event ERC20Rescued(address indexed token, address indexed to, uint256 amount);

    constructor() {
        _disableInitializers();
    }

    function initialize(address owner_, address treasury_, uint16 feeBps_, address permit2_) external initializer {
        if (owner_ == address(0) || treasury_ == address(0) || permit2_ == address(0)) revert ZeroAddress();
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        __Ownable_init(owner_);
        __Ownable2Step_init();
        treasury = treasury_;
        feeBps = feeBps_;
        permit2 = permit2_;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    // ---------- admin config (all onlyOwner, instant-toggle -- same shape every other launch family
    // in this protocol already uses) ----------

    function setTreasury(address treasury_) external onlyOwner {
        if (treasury_ == address(0)) revert ZeroAddress();
        treasury = treasury_;
        emit TreasurySet(treasury_);
    }

    function setFeeBps(uint16 feeBps_) external onlyOwner {
        if (feeBps_ > MAX_FEE_BPS) revert FeeTooHigh(feeBps_);
        feeBps = feeBps_;
        emit FeeBpsSet(feeBps_);
    }

    function setPermit2(address permit2_) external onlyOwner {
        if (permit2_ == address(0)) revert ZeroAddress();
        permit2 = permit2_;
        emit Permit2Set(permit2_);
    }

    // The only addresses this contract will ever approve or call into: canonical Uniswap
    // V2Router02/SwapRouter02/UniversalRouter, Permit2 itself (as an approval spender for the plain
    // ERC-20 leg of the V4 dance), and the InkyPump proxy -- one call per chain deployment, matching
    // chain/router/addresses.ts's own per-chain constants.
    function setAllowedTarget(address target, bool allowed) external onlyOwner {
        if (target == address(0)) revert ZeroAddress();
        allowedTargets[target] = allowed;
        emit TargetAllowedSet(target, allowed);
    }

    // ---------- the swap itself ----------

    // `sellToken` is address(0) for native. `sellAmount` is the trader's full amount before the fee --
    // the fee is always computed here, from the stored feeBps, never trusted as a caller-supplied
    // parameter. `approvals` covers whatever this venue's swap needs before the final call: empty for
    // native-in or an InkyPump buy, one plain entry for V2/V3/InkyPump-sell, or a plain entry
    // (sellToken -> Permit2) followed by a viaPermit2 entry (Permit2 -> the actual router) for V4.
    // `swapTarget` executes `swapCalldata` with `swapValue` attached -- msg.value must equal exactly
    // what this call needs: swapValue for a native sell, or the post-fee-computed... no, exactly
    // sellAmount for a native sell (the fee is paid out of it here), or 0 for an ERC-20 sell.
    function executeSwap(
        address sellToken,
        uint256 sellAmount,
        Approval[] calldata approvals,
        address swapTarget,
        bytes calldata swapCalldata,
        uint256 swapValue
    ) external payable nonReentrant returns (uint256 feeAmount) {
        if (!allowedTargets[swapTarget]) revert TargetNotAllowed(swapTarget);
        for (uint256 i = 0; i < approvals.length; i++) {
            if (!allowedTargets[approvals[i].spender]) revert TargetNotAllowed(approvals[i].spender);
        }

        feeAmount = (sellAmount * feeBps) / 10_000;
        // The post-fee amount actually available to spend. Enforced below rather than just computed
        // and trusted: a future bug in the (trusted, but not infallible) backend caller should fail
        // loudly here rather than silently leave dust behind or over-approve a router.
        uint256 swapAmount = sellAmount - feeAmount;

        if (sellToken == NATIVE) {
            if (msg.value != sellAmount || swapValue != swapAmount) revert NativeValueMismatch();
            if (feeAmount > 0) {
                (bool ok, ) = treasury.call{value: feeAmount}("");
                if (!ok) revert FeeTransferFailed();
            }
        } else {
            if (msg.value != 0 || swapValue != 0) revert NativeValueMismatch();
            IERC20(sellToken).safeTransferFrom(msg.sender, address(this), sellAmount);
            if (feeAmount > 0) IERC20(sellToken).safeTransfer(treasury, feeAmount);
            for (uint256 i = 0; i < approvals.length; i++) {
                Approval calldata a = approvals[i];
                if (a.amount > swapAmount) revert ApprovalExceedsSwapAmount(a.amount, swapAmount);
                if (a.viaPermit2) {
                    IPermit2Approve(permit2).approve(sellToken, a.spender, uint160(a.amount), a.expiration);
                } else {
                    IERC20(sellToken).forceApprove(a.spender, a.amount);
                }
            }
        }

        (bool success, bytes memory ret) = swapTarget.call{value: swapValue}(swapCalldata);
        if (!success) {
            if (ret.length > 0) {
                assembly ("memory-safe") { revert(add(ret, 32), mload(ret)) }
            }
            revert SwapCallFailed();
        }

        emit SwapExecuted(msg.sender, sellToken, sellAmount, feeAmount, swapTarget);
    }

    // ---------- rescue (dust / accidental sends only -- this contract never holds a real balance
    // between calls by design: executeSwap pulls, spends and forwards everything within one atomic
    // transaction) ----------

    function rescueETH(address to, uint256 amount) external onlyOwner nonReentrant {
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0 || amount > address(this).balance) revert NothingToRescue();
        (bool ok, ) = to.call{value: amount}("");
        if (!ok) revert FeeTransferFailed();
        emit ETHRescued(to, amount);
    }

    function rescueERC20(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        if (amount == 0) revert NothingToRescue();
        IERC20(token).safeTransfer(to, amount);
        emit ERC20Rescued(token, to, amount);
    }

    receive() external payable {}
}
