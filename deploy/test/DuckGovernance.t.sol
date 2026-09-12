// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

import {Test} from "forge-std/Test.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {DuckVault} from "duck-lending/DuckVault.sol";
import {DuckVaultFactory} from "duck-lending/DuckVaultFactory.sol";
import {DuckVaultConfig} from "duck-lending/DuckVaultConfig.sol";
import {DuckTokenGovernor} from "duck-governance/DuckTokenGovernor.sol";
import {DuckTokenGovernorFactory} from "duck-governance/DuckTokenGovernorFactory.sol";
import {TimelockControllerUpgradeable} from "@openzeppelin/contracts-upgradeable/governance/TimelockControllerUpgradeable.sol";
import {DuckToken} from "duck-lib/DuckToken.sol";
import {DuckClones} from "duck-lib/DuckClones.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";

contract MockERC20Gov {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }
    function approve(address spender, uint256 amount) external returns (bool) { allowance[msg.sender][spender] = amount; return true; }
    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount; balanceOf[to] += amount; return true;
    }
    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 a = allowance[from][msg.sender];
        if (a != type(uint256).max) allowance[from][msg.sender] = a - amount;
        balanceOf[from] -= amount; balanceOf[to] += amount; return true;
    }
    function decimals() external pure returns (uint8) { return 18; }
}

contract DuckGovernanceTest is Test {
    DuckVaultFactory vaultFactory;
    DuckTokenGovernorFactory governorFactory;
    DuckVaultConfig config;
    DuckToken token;
    MockERC20Gov currency;
    DuckVault vault;

    address creator = makeAddr("creator");
    address holderA = makeAddr("holderA");
    address holderB = makeAddr("holderB");
    address destination = makeAddr("destination");
    address hook = makeAddr("hook");

    uint256 constant SUPPLY = 1_000_000e18;

    function setUp() public {
        currency = new MockERC20Gov();

        DuckVaultConfig configImpl = new DuckVaultConfig();
        ERC1967Proxy configProxy = new ERC1967Proxy(address(configImpl), abi.encodeCall(DuckVaultConfig.initialize, (address(this))));
        config = DuckVaultConfig(address(configProxy));

        DuckVault vaultImpl = new DuckVault();
        DuckVaultFactory vfImpl = new DuckVaultFactory();
        ERC1967Proxy vfProxy = new ERC1967Proxy(
            address(vfImpl),
            abi.encodeCall(DuckVaultFactory.initialize, (address(this), address(vaultImpl), address(config), hook))
        );
        vaultFactory = DuckVaultFactory(address(vfProxy));

        vaultFactory.setFamily(address(this), true);

        DuckToken tokenImpl = new DuckToken(address(vaultFactory));
        address tokenClone = DuckClones.clone(address(tokenImpl), address(this), bytes32(0));
        token = DuckToken(payable(tokenClone));
        token.initToken("Duck Gov", "DGOV", SUPPLY, false, "");

        vaultFactory.createVault(address(token), 18, creator);
        vault = DuckVault(payable(vaultFactory.getVault(address(token))));

        DuckTokenGovernor governorImpl = new DuckTokenGovernor();
        TimelockControllerUpgradeable timelockImpl = new TimelockControllerUpgradeable();
        DuckTokenGovernorFactory gfImpl = new DuckTokenGovernorFactory();
        ERC1967Proxy gfProxy = new ERC1967Proxy(
            address(gfImpl),
            abi.encodeCall(DuckTokenGovernorFactory.initialize, (address(this), address(governorImpl), address(timelockImpl), 1, 100))
        );
        governorFactory = DuckTokenGovernorFactory(address(gfProxy));
        vaultFactory.setGovernorFactory(address(governorFactory));

        vault.linkPool(address(currency), bytes32(uint256(1)), true, 18, false);

        currency.mint(address(this), 100 ether);
        currency.approve(address(vault), type(uint256).max);
        vault.depositFees(100 ether);

        token.transfer(holderA, (SUPPLY * 25) / 100);
        token.transfer(holderB, (SUPPLY * 20) / 100);
    }

    function test_OnlyCreatorCanDeployGovernor() public {
        vm.expectRevert(DuckTokenGovernorFactory.NotCreator.selector);
        governorFactory.createGovernor(address(vault), address(token));

        vm.prank(creator);
        address governor = governorFactory.createGovernor(address(vault), address(token));

        assertEq(vault.governor(), governorFactory.timelockOf(address(vault)));
        assertEq(governorFactory.governorOf(address(vault)), governor);
    }

    function test_CreateVaultRevertsForUnknownFamily() public {
        vm.prank(makeAddr("randomCaller"));
        vm.expectRevert(DuckVaultFactory.UnknownFamily.selector);
        vaultFactory.createVault(address(token), 18, creator);
    }

    function test_CreateVaultRevertsIfMarketAlreadyOpen() public {

        vm.expectRevert(DuckVaultFactory.MarketAlreadyOpen.selector);
        vaultFactory.createVault(address(token), 18, creator);
    }

    function test_CannotDeployGovernorTwiceForTheSameVault() public {
        vm.prank(creator);
        governorFactory.createGovernor(address(vault), address(token));

        vm.prank(creator);
        vm.expectRevert(DuckTokenGovernorFactory.GovernorAlreadyExists.selector);
        governorFactory.createGovernor(address(vault), address(token));
    }

    function test_OnlyCreatorCanPropose() public {
        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(address(vault), address(token));
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (1 ether, destination));

        vm.prank(holderA);
        vm.expectRevert(DuckTokenGovernor.NotCreator.selector);
        governor.propose(targets, values, calldatas, "nope");
    }

    function test_ProposalFailsWithoutQuorum() public {
        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(address(vault), address(token));
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (10 ether, destination));

        vm.roll(100);
        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Withdraw 10");

        vm.roll(102);

        vm.prank(holderB);
        governor.castVote(proposalId, 1);

        vm.roll(203);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_ProposalSucceedsAndExecutesWithdrawal() public {
        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(address(vault), address(token));
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (10 ether, destination));
        string memory description = "Withdraw 10";

        vm.roll(100);
        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(102);

        vm.prank(holderA);
        governor.castVote(proposalId, 1);
        vm.prank(holderB);
        governor.castVote(proposalId, 1);

        vm.roll(203);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));

        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Queued));

        vm.expectRevert();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        vm.warp(block.timestamp + 5 days + 1);

        uint256 destBalanceBefore = currency.balanceOf(destination);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(currency.balanceOf(destination), destBalanceBefore + 10 ether);
        assertEq(vault.totalReserves(), 100 ether - 10 ether);
    }

    // Predates the anti-sniping/min-voting-threshold gate in DuckTokenGovernor._countVote: a
    // zero-weight wallet used to be allowed to cast a vote that simply didn't count toward
    // participation. Now the same protection is enforced more directly -- any wallet that doesn't
    // hold more than 0.2% of supply (checked against its balance from before the proposal existed)
    // can't vote at all, zero-weight included, so this asserts the revert instead of a silent no-op.
    function test_ZeroWeightVotesCannotVoteAtAll() public {
        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(address(vault), address(token));
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (10 ether, destination));

        vm.roll(100);
        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Withdraw 10");

        vm.roll(102);

        governor.castVote(proposalId, 1);

        for (uint256 i; i < 5; i++) {
            vm.prank(makeAddr(string.concat("zeroWeightVoter", vm.toString(i))));
            vm.expectRevert(DuckTokenGovernor.BelowMinVotingThreshold.selector);
            governor.castVote(proposalId, 1);
        }

        vm.roll(203);

        // address(this) (55% of supply) ends up the ONLY successful voter -- 100% of actual voters,
        // comfortably above the 40% weight-quorum too -- so the proposal legitimately succeeds. The
        // point of this test is that the 5 zero-weight wallets above could never join the tally at
        // all (each reverted), not that a lone large holder can never pass a proposal alone.
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded));
    }

    // Predates the redesigned headcount quorum: abstain now DOES count toward the total-voter
    // denominator (see DuckTokenGovernor._quorumReached), so this old scenario (1 For vs 1 Abstain,
    // out of 3 total eligible holders) actually SUCCEEDS under the new rule -- For is 1 of 2 actual
    // voters (50% >= 40%) and clears the supply-weight quorum outright (address(this) holds 55%).
    // Replaced with a test that isolates the new rule's actual bite: For can win the supply-weighted
    // vote outright and still be Defeated if it isn't more than 40% of the wallets that showed up.
    function test_ForWinsByWeightButFailsHeadcountShareAmongActualVoters() public {
        // Mirrors: For=38%, Against=37%, Abstain=25% of actual voters -> Defeated, even though For
        // is the single largest bucket. 3 For voters hold enough combined weight (45% of supply) to
        // clear the 40% weight-quorum and outweigh Against by a wide margin -- isolating that this
        // fails on HEADCOUNT alone, not on supply weight.
        address for1 = makeAddr("for1");
        address for2 = makeAddr("for2");
        address for3 = makeAddr("for3");
        address against1 = makeAddr("against1");
        address against2 = makeAddr("against2");
        address against3 = makeAddr("against3");
        address abstain1 = makeAddr("abstain1");
        address abstain2 = makeAddr("abstain2");

        token.transfer(for1, 150_000e18);
        token.transfer(for2, 150_000e18);
        token.transfer(for3, 150_000e18);
        // Against/Abstain voters each hold just over the 0.2% eligibility floor (2_000e18) -- enough
        // to be eligible to vote at all, negligible by weight.
        token.transfer(against1, 3_000e18);
        token.transfer(against2, 3_000e18);
        token.transfer(against3, 3_000e18);
        token.transfer(abstain1, 3_000e18);
        token.transfer(abstain2, 3_000e18);

        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(address(vault), address(token));
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (10 ether, destination));

        vm.roll(100);
        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Withdraw 10");

        vm.roll(102);

        vm.prank(for1); governor.castVote(proposalId, 1);
        vm.prank(for2); governor.castVote(proposalId, 1);
        vm.prank(for3); governor.castVote(proposalId, 1);
        vm.prank(against1); governor.castVote(proposalId, 0);
        vm.prank(against2); governor.castVote(proposalId, 0);
        vm.prank(against3); governor.castVote(proposalId, 0);
        vm.prank(abstain1); governor.castVote(proposalId, 2);
        vm.prank(abstain2); governor.castVote(proposalId, 2);

        vm.roll(203);
        assertEq(
            uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Defeated),
            "For must exceed 40% of ACTUAL voters (for+against+abstain), not just win by supply weight"
        );
    }

    function test_ExactlyFortyPercentHeadcountAndSupplyBoundaryPasses() public {

        address holderC = makeAddr("holderC");
        address holderD = makeAddr("holderD");
        uint256 fifth = SUPPLY / 5;
        token.transfer(holderC, fifth);
        token.transfer(holderD, fifth);

        vm.prank(holderA);
        token.transfer(address(this), fifth * 5 / 4 - fifth);

        assertEq(token.balanceOf(address(this)), fifth, "address(this) must end up at exactly 20% too");
        assertEq(token.balanceOf(holderA), fifth);
        assertEq(token.balanceOf(holderB), fifth);
        assertEq(token.holderCount(), 5);

        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(address(vault), address(token));
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (10 ether, destination));

        vm.roll(100);
        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Withdraw 10");

        vm.roll(102);

        // 5 total voters: 2 For (40% headcount, exactly at the floor; also 40% supply weight,
        // exactly at the weight-quorum floor), 1 Against, 2 Abstain.
        governor.castVote(proposalId, 1);
        vm.prank(holderA);
        governor.castVote(proposalId, 1);
        vm.prank(holderB);
        governor.castVote(proposalId, 0);
        vm.prank(holderC);
        governor.castVote(proposalId, 2);
        vm.prank(holderD);
        governor.castVote(proposalId, 2);

        vm.roll(203);
        assertEq(
            uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Succeeded),
            "exactly 40% (both by headcount share of actual voters and by supply weight) must pass under a >= threshold"
        );
    }

    function test_CannotExecuteTheSameProposalTwice() public {
        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(address(vault), address(token));
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (10 ether, destination));
        string memory description = "Withdraw 10";

        vm.roll(100);
        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);

        vm.roll(102);
        vm.prank(holderA);
        governor.castVote(proposalId, 1);
        vm.prank(holderB);
        governor.castVote(proposalId, 1);

        vm.roll(203);
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        vm.warp(block.timestamp + 5 days + 1);
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));

        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Executed));
        vm.expectRevert();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
    }

    function test_CancelOnlyAllowedDuringPendingByOriginalProposer() public {
        vm.prank(creator);
        address governorAddr = governorFactory.createGovernor(address(vault), address(token));
        DuckTokenGovernor governor = DuckTokenGovernor(payable(governorAddr));

        address[] memory targets = new address[](1);
        targets[0] = address(vault);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(DuckVault.withdraw, (10 ether, destination));
        string memory description = "Withdraw 10";
        bytes32 descriptionHash = keccak256(bytes(description));

        vm.roll(100);
        vm.prank(creator);
        uint256 proposalId = governor.propose(targets, values, calldatas, description);
        assertEq(uint256(governor.state(proposalId)), uint256(IGovernor.ProposalState.Pending));

        vm.expectRevert();
        vm.prank(holderA);
        governor.cancel(targets, values, calldatas, descriptionHash);

        vm.roll(102);
        vm.expectRevert();
        vm.prank(creator);
        governor.cancel(targets, values, calldatas, descriptionHash);

        vm.prank(creator);
        uint256 secondProposalId = governor.propose(targets, values, calldatas, "Withdraw 10 (second)");
        vm.prank(creator);
        governor.cancel(targets, values, calldatas, keccak256(bytes("Withdraw 10 (second)")));
        assertEq(uint256(governor.state(secondProposalId)), uint256(IGovernor.ProposalState.Canceled));
    }
}
