// SPDX-License-Identifier: MIT
pragma solidity ^0.8.32;

// duckfun.family (alt. duckpad.fun) — standalone redeploy of DuckHookV4 to Robinhood Chain (4663).
// The live hook's mined address carries 0xCC but not BEFORE_REMOVE_LIQUIDITY (bit 9), so
// beforeRemoveLiquidity's unconditional revert would never run -- PoolManager wouldn't call it at
// all. New target: 0x2CC. See DuckHookV4's REQUIRED_PERMISSIONS.
//
// Does NOT redeploy the rest of the protocol: the launch contracts store the hook as a settable var,
// so pointing new launches at this one is a separate later admin call on each, once this script's
// output is confirmed good on a fork. Existing pools keep their original hook forever (bound into
// the PoolKey at creation), so this only affects launches after those follow-up calls.

import {Script, console} from "forge-std/Script.sol";
import {DuckHookV4} from "duck-shared/DuckHookV4.sol";
import {DuckHookFactory} from "./DuckHookFactory.sol";

contract DeployNewHook is Script {

    address constant V4_POOL_MANAGER = 0x8366a39CC670B4001A1121B8F6A443A643e40951;

    // Read live off the currently-deployed hook rather than re-guessed -- reused as-is, nothing
    // about these changes with the new hook.
    address constant OLD_HOOK        = 0xA62a288125E730622a75006ed54a3ecD73B740cc;
    address constant PLATFORM_WALLET = 0x586Eb3db5866D76D752916396D63352DB29a47Bd;
    address constant WETH            = 0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73;

    // The three launch contracts that will (later, separately) be pointed
    // at the new hook via setDexConfig/addDex.
    address constant DUCK_BONDING_CURVE = 0x9AE7383af6ea77037c09459a9aF8f4AEC038f083;
    address constant DUCK_LAUNCHER      = 0xDA4fAD8E339d1F1f243C810CCDa29de80c5040Dc;
    address constant DUCK_CROWDFUND     = 0x5066B217106De6f7b1A5F43eAa138C3C6306FC7d;

    // DuckVaultFactory also stores a plain settable hook address (passed into every new
    // DuckVault.initialize() call it makes) -- missed in this script's own printed checklist last
    // round, so listing it here explicitly this time.
    address constant DUCK_VAULT_FACTORY = 0xeB191E04445046cDD3f21Bae6e79Ef78bE08D28F;

    function run() external {
        uint256 deployerKey = vm.envOr("PRIVATE_KEY", uint256(0));
        address deployer    = deployerKey != 0 ? vm.addr(deployerKey) : vm.envOr("DEPLOYER_ADDRESS", address(0));
        require(deployer != address(0), "Set DEPLOYER_ADDRESS (with --account/--ledger) or PRIVATE_KEY");

        // stateView is unset on the old hook (oracle not wired up), so nothing to carry over.
        // ctoFee defaults to 0.1 ether in DuckHookV4 itself, matching the old hook's live value.

        if (deployerKey != 0) {
            vm.startBroadcast(deployerKey);
        } else {
            vm.startBroadcast(deployer);
        }

        DuckHookFactory hookFactory = new DuckHookFactory();
        bytes32 initCodeHash = keccak256(abi.encodePacked(
            type(DuckHookV4).creationCode,
            abi.encode(V4_POOL_MANAGER)
        ));
        (bytes32 hookSalt, address predictedHook) = _mineHookSalt(address(hookFactory), initCodeHash);
        address hookAddr = hookFactory.deploy(hookSalt, V4_POOL_MANAGER, deployer);
        require(hookAddr == predictedHook, "hook address mismatch");
        require(uint160(hookAddr) & 0x3FFF == 0x2CC, "bad hook permission bits");

        DuckHookV4 hook = DuckHookV4(payable(hookAddr));
        hook.addLauncher(DUCK_BONDING_CURVE);
        hook.addLauncher(DUCK_LAUNCHER);
        hook.addLauncher(DUCK_CROWDFUND);
        hook.setPlatformWallet(PLATFORM_WALLET);
        hook.setWeth(WETH);

        vm.stopBroadcast();

        console.log("");
        console.log("=== New DuckHookV4 deployed ===");
        console.log("New hook:  ", hookAddr);
        console.log("Old hook:  ", OLD_HOOK, "(unchanged, existing pools keep using it forever)");
        console.log("Owner:     ", deployer);
        console.log("");
        console.log("Not done by this script -- do these yourself once this is verified on a fork:");
        console.log("  DuckBondingCurve.setDexConfig(positionManager, singleton, <new hook>)");
        console.log("  DuckLauncher.addDex(positionManager, singleton, <new hook>)  -- same positionManager key, overwrites in place");
        console.log("  DuckCrowdfund.setDexConfig(positionManager, singleton, <new hook>)");
        console.log("  DuckVaultFactory.setHook(<new hook>)  --", DUCK_VAULT_FACTORY);
        console.log("  Add the new hook address as a second DuckHookV4 data source in DuckProtocol-RH/subgraph.yaml");
        console.log("  Update DUCK_HOOK in frontend/src/chain/addresses.js and backend/src/chain/addresses.ts");
    }

    // Same brute-force mining approach as DeployDuckProtocol.s.sol's
    // _mineHookSalt, just targeting 0x2CC instead of 0xCC (see this file's
    // header comment for why).
    function _mineHookSalt(address factory, bytes32 initCodeHash)
        internal pure returns (bytes32 salt, address predicted)
    {
        for (uint256 nonce = 0; nonce < 200_000; nonce++) {
            salt = bytes32(nonce);
            predicted = _computeCreate2Address(salt, initCodeHash, factory);
            if (uint160(predicted) & 0x3FFF == 0x2CC) return (salt, predicted);
        }
        revert("hook salt not found");
    }

    function _computeCreate2Address(bytes32 salt, bytes32 initCodeHash, address deployer_)
        internal pure returns (address addr)
    {
        assembly {
            let ptr := mload(0x40)
            mstore8(ptr, 0xff)
            mstore(add(ptr, 1), shl(96, deployer_))
            mstore(add(ptr, 21), salt)
            mstore(add(ptr, 53), initCodeHash)
            addr := and(keccak256(ptr, 85), 0xffffffffffffffffffffffffffffffffffffffff)
        }
    }
}
