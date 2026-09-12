// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {DuckLauncher} from "duck-launcher/DuckLauncher.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultFactory} from "duck-lending/DuckVaultFactory.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckTokenGovernor} from "duck-governance/DuckTokenGovernor.sol";
import {DuckTokenGovernorFactory} from "duck-governance/DuckTokenGovernorFactory.sol";
import {TimelockControllerUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {DuckHookFactory} from "../script/DuckHookFactory.sol";
import {PoolKey, SwapParams} from "duck-lib/LaunchRouting.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

interface IPoolManagerSwapForkGov {
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData) external returns (int256);
    function settle() external payable returns (uint256);
    function take(address currency, address to, uint256 amount) external;
    function sync(address currency) external;
}

interface IERC20ForkGov {
    function balanceOf(address) external view returns (uint256);
    function transfer(address, uint256) external returns (bool);
    function approve(address, uint256) external returns (bool);
}

interface IWETHForkGov {
    function balanceOf(address) external view returns (uint256);
    function approve(address, uint256) external returns (bool);
}

contract DuckProtocolGovernanceForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;
    uint24  constant FEE_TIER            = 0;
    int24   constant TICK_SPACING        = 200;

    DuckLauncher launcher;
    DuckHookV4 hook;
    DuckToken tokenImpl;
    DuckVaultFactory vaultFactory;
    DuckTokenGovernorFactory governorFactory;

    address owner    = makeAddr("dpg-owner");
    address platform = makeAddr("dpg-platform");
    address creator  = makeAddr("dpg-creator");
    address trader   = makeAddr("dpg-trader");
    address holderA  = makeAddr("dpg-holderA");
    address holderB  = makeAddr("dpg-holderB");
    address destination = makeAddr("dpg-destination");

    address token;
    address vault;
    address _cbExpected;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        vm.etch(owner, "");
        vm.etch(platform, "");
        vm.etch(creator, "");
        vm.etch(trader, "");
        vm.etch(holderA, "");
        vm.etch(holderB, "");
        vm.etch(destination, "");

        vm.startPrank(owner);

        DuckVaultConfig configImpl = new DuckVaultConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(
            address(configImpl), abi.encodeCall(DuckVaultConfig.initialize, (owner))
        );
        DuckVault vaultImpl = new DuckVault();

        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(type(DuckHookV4).creationCode, abi.encode(V4_POOL_MANAGER)));
        (bytes32 hookSalt,) = _mineHookSalt(address(hookFactory), initCodeHash);
        address hookAddr = hookFactory.deploy(hookSalt, V4_POOL_MANAGER, owner);
        hook = DuckHookV4(payable(hookAddr));
        require(uint160(hookAddr) & 0x3FFF == 0x2CC, "bad hook permission bits");
        hook.setWeth(WETH);
        hook.setPlatformWallet(platform);

        DuckVaultFactory vaultFactoryImpl = new DuckVaultFactory();
        ERC1967Proxy vaultFactoryProxy = new ERC1967Proxy(
            address(vaultFactoryImpl),
            abi.encodeCall(DuckVaultFactory.initialize, (owner, address(vaultImpl), address(configProxy), hookAddr))
        );
        vaultFactory = DuckVaultFactory(address(vaultFactoryProxy));

        tokenImpl = new DuckToken(address(vaultFactory));

        DuckLauncher launcherImpl = new DuckLauncher();
        ERC1967Proxy launcherProxy = new ERC1967Proxy(
            address(launcherImpl),
            abi.encodeCall(DuckLauncher.initialize, (
                WETH, address(tokenImpl), platform,
                V4_POSITION_MANAGER, V4_POOL_MANAGER, hookAddr
            ))
        );
        launcher = DuckLauncher(payable(address(launcherProxy)));
        launcher.setVaultFactory(address(vaultFactory));

        hook.addLauncher(address(launcher));
        vaultFactory.setFamily(address(launcher), true);

        DuckTokenGovernor governorImpl = new DuckTokenGovernor();
        TimelockControllerUpgradeable timelockImpl = new TimelockControllerUpgradeable();
        DuckTokenGovernorFactory gfImpl = new DuckTokenGovernorFactory();
        ERC1967Proxy gfProxy = new ERC1967Proxy(
            address(gfImpl),
            abi.encodeCall(DuckTokenGovernorFactory.initialize, (owner, address(governorImpl), address(timelockImpl), 1, 100))
        );
        governorFactory = DuckTokenGovernorFactory(address(gfProxy));
        vaultFactory.setGovernorFactory(address(governorFactory));

        vm.stopPrank();

        vm.deal(creator, 1_000 ether);
        vm.deal(trader, 1_000 ether);

        _launchAndAccrueRealFees();

        // Advance one block past every setUp() transfer (holderA/holderB included) so that, by the
        // time any test's body creates a proposal, those balances are already checkpointed as
        // "held before this block" -- exactly the real-world situation the anti-snipe eligibility
        // check (DuckTokenGovernor._proposalCreatedAt, keyed on clock() - 1 at propose() time) is
        // designed around. Without this, a genuine long-standing holder whose setUp() transfer
        // landed in the very same block as propose() would be indistinguishable from an actual
        // snipe, since block-level checkpoints can't see intra-block transaction order.
        vm.roll(block.number + 1);
    }

    function _launchAndAccrueRealFees() internal {
        DuckLauncher.LaunchParams memory p;
        p.name = "Duck Gov";
        p.symbol = "DGOV";
        p.metaURI = "";
        p.feeWallet = address(0);
        p.positionManager = V4_POSITION_MANAGER;
        p.quoteToken = address(0);
        p.vanitySalt = _mineTokenSalt(creator);

        p.launchMarketCap = 1 ether;
        p.minQuoteOut = 0;
        p.minTokensOut = 0;
        p.hookFeeBps = 0;
        p.vaultBps = 10_000;
        p.revertOnInstantBuyFailure = false;

        vm.prank(creator);
        (token,) = launcher.launch{value: 0.0005 ether + 10 ether}(p);
        vault = DuckToken(payable(token)).vault();

        uint256 creatorTokens = DuckToken(payable(token)).balanceOf(creator);
        assertGt(creatorTokens, 0, "instant buy should have landed tokens on the creator to sell/distribute");

        uint256 TOTAL_SUPPLY = 1_000_000_000e18;

        vm.prank(creator);
        DuckToken(payable(token)).transfer(trader, creatorTokens / 20);

        bool tokenIsC0 = token < address(0);
        PoolKey memory key = PoolKey({
            currency0: tokenIsC0 ? token : address(0),
            currency1: tokenIsC0 ? address(0) : token,
            fee: FEE_TIER,
            tickSpacing: TICK_SPACING,
            hooks: address(hook)
        });
        uint256 sellAmount = (creatorTokens / 20) / 10;
        vm.prank(trader);
        IERC20ForkGov(token).approve(address(this), sellAmount);
        // Advance a block: this trade and the launch's own instantBuy above are meant to represent two
        // genuinely separate real-world transactions (different traders), which would always land in
        // different blocks in practice (or at least carry different tx.origin -- the hook's
        // SameBlockSwap guard now keys on tx.origin, which Foundry's single-arg vm.prank doesn't vary).
        vm.roll(block.number + 1);
        _sell(key, token, tokenIsC0, sellAmount, trader);

        hook.claimFees(_poolIdOf(token));

        vm.startPrank(creator);
        DuckToken(payable(token)).transfer(holderA, (TOTAL_SUPPLY * 25) / 100);
        DuckToken(payable(token)).transfer(holderB, (TOTAL_SUPPLY * 20) / 100);
        vm.stopPrank();
    }

    function _poolIdOf(address token_) internal view returns (bytes32) {
        return DuckVault(payable(DuckToken(payable(token_)).vault())).poolId();
    }

    function _mineHookSalt(address factory, bytes32 initCodeHash) internal pure returns (bytes32 salt, address predicted) {
        for (uint256 nonce = 0; nonce < 200_000; nonce++) {
            salt = bytes32(nonce);
            predicted = _computeCreate2Address(salt, initCodeHash, factory);
            if (uint160(predicted) & 0x3FFF == 0x2CC) return (salt, predicted);
        }
        revert("hook salt not found");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer) internal pure returns (address addr) {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), initCodeHash)
            addr := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }

    function _saltFor(address creator_, bytes32 userSalt) internal pure returns (bytes32 salt) {
        assembly {
            let ptr := mload(0x40)
            mstore(ptr, creator_)
            mstore(add(ptr, 32), userSalt)
            salt := keccak256(ptr, 64)
        }
    }

    function _mineTokenSalt(address creator_) internal returns (bytes32 userSalt) {
        bytes memory initCode = abi.encodePacked(
            hex"3d602d80600a3d3981f3363d3d373d3d3d363d73",
            address(tokenImpl),
            hex"5af43d82803e903d91602b57fd5bf3"
        );
        bytes32 initCodeHash = keccak256(initCode);
        for (uint256 i = 0; i < 1_000_000; i++) {
            userSalt = bytes32(i);
            bytes32 salt = _saltFor(creator_, userSalt);
            address predicted = _computeCreate2Address(salt, initCodeHash, address(launcher));
            if (uint16(uint160(predicted)) == 0x8888) return userSalt;
        }
        revert("token salt not found");
    }

    function _sell(PoolKey memory key, address token_, bool tokenIsC0, uint256 amountIn, address trader_) internal {
        _cbExpected = V4_POOL_MANAGER;
        IPoolManagerSwapForkGov(V4_POOL_MANAGER).unlock(abi.encode(key, token_, tokenIsC0, amountIn, trader_));
        _cbExpected = address(0);
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == _cbExpected, "unauthorized callback");
        (PoolKey memory key, address token_, bool tokenIsC0, uint256 amountIn, address trader_) =
            abi.decode(data, (PoolKey, address, bool, uint256, address));

        int256 delta = IPoolManagerSwapForkGov(msg.sender).swap(
            key,
            SwapParams({
                zeroForOne: tokenIsC0,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: tokenIsC0 ? 4295128739 + 1 : 1461446703485210103287273052203988822378723970342 - 1
            }),
            ""
        );

        (bool ok,) = token_.call(abi.encodeWithSelector(0x23b872dd, trader_, address(this), amountIn));
        require(ok, "transferFrom failed");
        IPoolManagerSwapForkGov(msg.sender).sync(token_);
        (bool ok2,) = token_.call(abi.encodeWithSelector(0xa9059cbb, msg.sender, amountIn));
        require(ok2, "transfer to pool manager failed");
        IPoolManagerSwapForkGov(msg.sender).settle();

        address quote = tokenIsC0 ? key.currency1 : key.currency0;
        int128 quoteDelta = tokenIsC0 ? int128(delta) : int128(delta >> 128);
        uint256 amountOut = uint256(uint128(quoteDelta));
        IPoolManagerSwapForkGov(msg.sender).take(quote, trader_, amountOut);

        return "";
    }

    function test_GovernorDeploymentIsCreatorGated() public {
        vm.expectRevert(DuckTokenGovernorFactory.NotCreator.selector);
        governorFactory.createGovernor(vault, token);

        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(vault, token);

        assertEq(DuckVault(payable(vault)).governor(), governorFactory.timelockOf(vault));
        assertEq(governorFactory.governorOf(vault), governorAddr);
    }

    function test_ProposalAgainstRealVaultExecutesRealWithdrawal() public {
        uint256 reserves = DuckVault(payable(vault)).totalReserves();
        assertGt(reserves, 0, "the real sell + claimFees must have left real reserves in the vault to withdraw");

        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(vault, token);
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = vault;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        uint256 withdrawAmount = reserves / 2;
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (withdrawAmount, destination));
        string memory description = "Withdraw half of real accrued reserves";

        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + 2);

        vm.prank(holderA);
        governor.castVote(proposalId, 1);
        vm.prank(holderB);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + 101);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Queued));

        vm.expectRevert();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        vm.warp(block.timestamp + 5 days + 1);

        uint256 destBalanceBefore = IWETHForkGov(WETH).balanceOf(destination);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(
            IWETHForkGov(WETH).balanceOf(destination), destBalanceBefore + withdrawAmount,
            "a passed proposal must move real WETH out of the real vault to the real destination"
        );
        assertEq(DuckVault(payable(vault)).totalReserves(), reserves - withdrawAmount);
    }

    function test_ProposalFailsQuorumAgainstRealVault() public {
        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(vault, token);
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        uint256 reserves = DuckVault(payable(vault)).totalReserves();

        address[] memory targets = new address[](1);
        targets[0] = vault;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (reserves, destination));

        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Drain everything");

        vm.roll(block.number + 2);

        vm.prank(holderB);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + 101);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_SmallHolderBelowMinVoteThresholdCannotVote() public {
        address smallHolder = makeAddr("dpg-smallHolder");
        uint256 TOTAL_SUPPLY = 1_000_000_000e18;
        // 0.1% of total supply -- comfortably nonzero, comfortably under the 0.2% voting floor.
        uint256 smallAmount = TOTAL_SUPPLY / 1000;
        vm.prank(creator);
        DuckToken(payable(token)).transfer(smallHolder, smallAmount);

        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(vault, token);
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = vault;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (1, destination));

        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Tiny test proposal");

        vm.roll(block.number + 2);

        vm.prank(smallHolder);
        vm.expectRevert(DuckTokenGovernor.BelowMinVotingThreshold.selector);
        governor.castVote(proposalId, 1);

        // A real holder comfortably above the 0.2% floor must still be able to vote normally --
        // the gate must reject only wallets below the threshold, not break voting altogether.
        vm.prank(holderB);
        governor.castVote(proposalId, 1);
    }

    function test_SniperBuyingInAfterProposalCreationCannotVote() public {
        address sniper = makeAddr("dpg-sniper");
        uint256 TOTAL_SUPPLY = 1_000_000_000e18;
        // Comfortably above the 0.2% floor -- if eligibility were (wrongly) checked at the vote
        // snapshot instead of proposal creation, this wallet would pass easily.
        uint256 snipeAmount = (TOTAL_SUPPLY * 5) / 100;

        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(vault, token);
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = vault;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (1, destination));

        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Snipe target proposal");

        // The snipe: buy in only AFTER the proposal already exists, then wait out the voting delay
        // and try to vote with a real, held (non-flash-loaned) balance well above the 0.2% floor.
        vm.prank(creator);
        DuckToken(payable(token)).transfer(sniper, snipeAmount);

        vm.roll(block.number + 2);

        vm.prank(sniper);
        vm.expectRevert(DuckTokenGovernor.BelowMinVotingThreshold.selector);
        governor.castVote(proposalId, 1);

        // A real holder who already held above the floor BEFORE the proposal existed must still be
        // able to vote normally -- the anti-snipe gate must reject only post-creation buy-ins.
        vm.prank(holderB);
        governor.castVote(proposalId, 1);
    }

    bytes32 constant IMPLEMENTATION_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    function _currentImpl() internal view returns (address) {
        return address(uint160(uint256(vm.load(vault, IMPLEMENTATION_SLOT))));
    }

    function test_GovernanceCanUpgradeVaultToApprovedImplementation() public {
        address newImpl = address(new DuckVault());
        vm.prank(owner);
        vaultFactory.approveVaultImpl(newImpl);

        address oldImpl = _currentImpl();
        assertTrue(oldImpl != newImpl, "sanity: the freshly deployed implementation must be a genuinely different address");

        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(vault, token);
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        uint256 reservesBefore = DuckVault(payable(vault)).totalReserves();

        address[] memory targets = new address[](1);
        targets[0] = vault;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault(payable(vault)).upgradeToAndCall, (newImpl, ""));
        string memory description = "Upgrade vault to newImpl";

        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + 2);
        vm.prank(holderA);
        governor.castVote(proposalId, 1);
        vm.prank(holderB);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + 101);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(_currentImpl(), newImpl, "a passed, timelocked proposal must actually swap the vault's real implementation");
        assertEq(
            DuckVault(payable(vault)).totalReserves(), reservesBefore,
            "an upgrade must never touch the vault's existing storage/state"
        );
    }

    function test_GovernanceCannotUpgradeVaultToUnapprovedImplementation() public {

        address rogueImpl = address(new DuckVault());
        address oldImpl = _currentImpl();

        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(vault, token);
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = vault;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault(payable(vault)).upgradeToAndCall, (rogueImpl, ""));
        string memory description = "Upgrade vault to an unapproved implementation";

        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(block.number + 2);
        vm.prank(holderA);
        governor.castVote(proposalId, 1);
        vm.prank(holderB);
        governor.castVote(proposalId, 1);

        vm.roll(block.number + 101);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(block.timestamp + 5 days + 1);

        vm.expectRevert();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(_currentImpl(), oldImpl, "a rejected implementation must never actually replace the vault's real code");
    }

    function test_DirectUpgradeCallBypassingGovernanceReverts() public {
        address newImpl = address(new DuckVault());
        vm.prank(owner);
        vaultFactory.approveVaultImpl(newImpl);

        vm.prank(owner);
        vm.expectRevert(DuckVault.NotGovernor.selector);
        DuckVault(payable(vault)).upgradeToAndCall(newImpl, "");

        vm.prank(creator);
        vm.expectRevert(DuckVault.NotGovernor.selector);
        DuckVault(payable(vault)).upgradeToAndCall(newImpl, "");
    }

    function test_RevokingImplementationDoesNotAffectAlreadyUpgradedVault() public {
        address newImpl = address(new DuckVault());
        vm.prank(owner);
        vaultFactory.approveVaultImpl(newImpl);

        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(vault, token);
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = vault;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault(payable(vault)).upgradeToAndCall, (newImpl, ""));
        string memory description = "Upgrade vault to newImpl";

        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        vm.roll(block.number + 2);
        vm.prank(holderA);
        governor.castVote(proposalId, 1);
        vm.prank(holderB);
        governor.castVote(proposalId, 1);
        vm.roll(block.number + 101);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(_currentImpl(), newImpl, "sanity: the vault must have actually upgraded");
        uint256 reservesBeforeRevoke = DuckVault(payable(vault)).totalReserves();

        vm.prank(owner);
        vaultFactory.revokeVaultImpl(newImpl);

        assertEq(
            _currentImpl(), newImpl,
            "revoking the implementation the vault is CURRENTLY running must never move it off that implementation"
        );

        deal(WETH, address(launcher), 1 ether);
        vm.prank(address(launcher));
        IWETHForkGov(WETH).approve(vault, 1 ether);
        vm.prank(address(launcher));
        DuckVault(payable(vault)).depositFees(1 ether);
        assertEq(DuckVault(payable(vault)).totalReserves(), reservesBeforeRevoke + 1 ether);
    }

    // Needed for _launchAndAccrueRealFees()'s claimFees() call: since the test contract itself is
    // the caller (not the creator), it earns the 1% claimer reward as native ETH -- same as the
    // receive() already present in the sibling DuckProtocol.fork.t.sol / DuckProtocolLending.fork.t.sol.
    receive() external payable {}
}
