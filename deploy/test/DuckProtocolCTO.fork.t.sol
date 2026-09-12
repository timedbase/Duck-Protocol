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
import {DuckHookFactory} from "../script/DuckHookFactory.sol";

contract DuckProtocolCTOForkTest is Test {
    address constant WETH                = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;
    address constant V4_POOL_MANAGER     = 0x8366a39CC670B4001A1121B8F6A443A643e40951;
    address constant V4_POSITION_MANAGER = 0x58daec3116aae6D93017bAAea7749052E8a04fA7;

    DuckLauncher launcher;
    DuckHookV4 hook;
    DuckToken tokenImpl;
    DuckVaultFactory vaultFactory;

    address owner      = makeAddr("dpc-owner");
    address platform   = makeAddr("dpc-platform");
    address creator    = makeAddr("dpc-creator");
    address applicant  = makeAddr("dpc-applicant");
    address newCreator = makeAddr("dpc-newcreator");

    address token;
    address vault;
    bytes32 poolId;

    uint256 private _tokenSaltNonceCursor;

    function setUp() public {
        vm.createSelectFork(vm.envString("ROBINHOOD_RPC_URL"));

        vm.etch(owner, "");
        vm.etch(platform, "");
        vm.etch(creator, "");
        vm.etch(applicant, "");
        vm.etch(newCreator, "");

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

        vm.stopPrank();

        vm.deal(creator, 1_000 ether);
        vm.deal(applicant, 1_000 ether);

        DuckLauncher.LaunchParams memory p;
        p.name = "Duck CTO";
        p.symbol = "DCTO";
        p.metaURI = "";
        p.feeWallet = address(0);
        p.positionManager = V4_POSITION_MANAGER;
        p.quoteToken = address(0);
        p.vanitySalt = _mineTokenSalt(creator);
        p.launchMarketCap = 5 ether;
        p.minQuoteOut = 0;
        p.minTokensOut = 0;
        p.hookFeeBps = 0;
        p.creatorBps = 9000;
        p.vaultBps = 1000;
        p.revertOnInstantBuyFailure = false;

        vm.prank(creator);
        (token, poolId) = launcher.launch{value: 0.0005 ether}(p);
        vault = DuckToken(payable(token)).vault();
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
        uint256 nonce = _tokenSaltNonceCursor;
        for (uint256 i = 0; i < 1_000_000; i++) {
            userSalt = bytes32(nonce + i);
            bytes32 salt = _saltFor(creator_, userSalt);
            address predicted = _computeCreate2Address(salt, initCodeHash, address(launcher));
            if (uint16(uint160(predicted)) == 0x8888) {
                _tokenSaltNonceCursor = nonce + i + 1;
                return userSalt;
            }
        }
        revert("token salt not found");
    }

    function _poolCreator() internal view returns (address c) {
        (, , , c, , , , , ,) = hook.pools(poolId);
    }

    function test_ApplyForCTORequiresRealFeeToRealPlatformWallet() public {
        vm.prank(applicant);
        vm.expectRevert(DuckHookV4.InsufficientCTOFee.selector);
        hook.applyForCTO{value: 0.05 ether}(poolId, newCreator);

        uint256 platformBefore = platform.balance;
        vm.prank(applicant);
        hook.applyForCTO{value: 0.1 ether}(poolId, newCreator);

        assertEq(platform.balance, platformBefore + 0.1 ether, "the real CTO fee must land on the real platform wallet immediately, not escrowed");
    }

    function test_ApproveCTOReassignsPoolCreatorAndRealVaultCreatorOnly() public {
        vm.prank(applicant);
        hook.applyForCTO{value: 0.1 ether}(poolId, newCreator);

        assertEq(_poolCreator(), creator, "creator must be unchanged until approval");
        assertEq(DuckVault(payable(vault)).creator(), creator);

        vm.prank(owner);
        hook.approveCTO(poolId);

        assertEq(_poolCreator(), newCreator, "the hook's own PoolInfo.creator must be reassigned");
        assertEq(
            DuckVault(payable(vault)).creator(), newCreator,
            "approveCTO must propagate to the REAL vault's creator -- the manager (this hook) is the only address allowed to call setCreator"
        );

        assertEq(DuckToken(payable(token)).vault(), vault, "CTO must never move a token to a different vault");
    }

    function test_RejectedCTOLeavesCreatorAndVaultUntouched() public {
        vm.prank(applicant);
        hook.applyForCTO{value: 0.1 ether}(poolId, newCreator);

        vm.prank(owner);
        hook.rejectCTO(poolId);

        assertEq(_poolCreator(), creator, "a rejected application must not reassign the hook's creator");
        assertEq(DuckVault(payable(vault)).creator(), creator, "a rejected application must not touch the real vault's creator");

        vm.prank(applicant);
        hook.applyForCTO{value: 0.1 ether}(poolId, newCreator);
        vm.prank(owner);
        hook.approveCTO(poolId);
        assertEq(DuckVault(payable(vault)).creator(), newCreator);
    }
}
