# DuckProtocol — Deployment Addresses

duckfun.family (alt. duckpad.fun)

Deployed 2026-09-12. Every contract except `DuckHookV4` is deployed via CREATE2 with fixed,
named salts, so **all addresses are identical across both chains except the hook** — its
constructor embeds the chain's PoolManager, so its address can never match across chains.

| Role | Address |
|---|---|
| Owner of all governance-controlled contracts | `0xac3dc1c78Ab23161B6C5029E9638A6ceB1129ba7` |
| Platform wallet (fee recipient) | `0x1c723Cf0451e6635C748283a3e87413079E7C198` |

> **Ownership is currently held by a single deployer EOA.** That key can upgrade all five
> UUPS-upgradeable contracts, so a compromise of it is a total protocol compromise. Transfer to a
> multisig is planned but deliberately deferred.

---

## Shared addresses (identical on Robinhood Chain 4663 and Ink 57073)

| Contract | Address |
|---|---|
| DeterministicProxyFactory | `0x807c02ac02A8E08f62Bf48714Ec6eAcFC722D002` |
| DuckVaultConfig — impl | `0xbf0Ee593944d9d16314B0B39C8f382Dd31C8D6f2` |
| DuckVaultConfig — **proxy** | `0x2526d694F9b6cCefE46871D1b40aeEc1313eabfB` |
| DuckVault — impl | `0x43191A6CCf1F9940574B92825bA1f337AB8bB443` |
| DuckHookFactory | `0x66080d1fD50779A1Bc663472571deFACa24B73Ba` |
| DuckVaultFactory — impl | `0xC2ad69a1FadFcBDF085cD50814B2074CDeC95dB9` |
| DuckVaultFactory — **proxy** | `0x006e53d079BB4c2010682a4896D1950965faD5A5` |
| DuckToken — impl (clone target) | `0x83A491C728b0485A887fE9D7360C4Ae7eF8B1461` |
| DuckBondingCurve — impl | `0x86E32BEa7ECb4f30ec395faF137E05eD880AfBa1` |
| DuckBondingCurve — **proxy** | `0xcE71ce995C2A3657aF9bEC45bA1Ee2E8fA2ef5eF` |
| DuckBondingCurveViews | `0x6CD84C6e3dA0295b4A2787f1794a908A26FE8Ba1` |
| DuckLauncher — impl | `0xBAcAABBdE0096b2722Fa2803b746AC53d2bD16c5` |
| DuckLauncher — **proxy** | `0x5F37c68f9937A0524Cc441b4E1080Ca4F089693B` |
| DuckCrowdfund — impl | `0x76433Fd870eA1518b7e2Ca2DD887469A091B80Cd` |
| DuckCrowdfund — **proxy** | `0xdA868A545aB058D14a70C46CA7760226e7Dcf7b9` |
| DuckTokenGovernor — impl | `0x2f87cDd103FE4E50132EA629c9693BCa5d70a2b2` |
| TimelockController — impl | `0x68Df3b99C70E99621f38a0A90Fc1c2013a3f8Ade` |
| DuckTokenGovernorFactory — impl | `0xC238bF5628d5b02a4F06769eC3A04b82e5c153D0` |
| DuckTokenGovernorFactory — **proxy** | `0x29e600073c29b4f646C54c78AeE97aE8AE888999` |

**Integrate against the proxies**, never the implementations.

## Chain-specific

| Contract | Robinhood (4663) | Ink (57073) |
|---|---|---|
| **DuckHookV4** | `0x483b529fa121c5402778a511A98fB326940042CC` | `0x5a05a1f0A101237D8c350EFfA54f4b3c9bc142cc` |

Both satisfy the required v4 hook permission bits (`address & 0x3FFF == 0x2CC`).

---

## External infrastructure

| | Robinhood (4663) | Ink (57073) |
|---|---|---|
| WETH | `0x0Bd7D308f8E1639FAb988df18A8011f41EAcAD73` | `0x4200000000000000000000000000000000000006` |
| Uniswap v4 PoolManager | `0x8366a39CC670B4001A1121B8F6A443A643e40951` | `0x360E68faCcca8cA495c1B759Fd9EEe466db9FB32` |
| Uniswap v4 PositionManager | `0x58daec3116aae6D93017bAAea7749052E8a04fA7` | `0x1b35d13a2E2528f192637F14B05f0Dc0e7dEB566` |
| Universal Router | `0x8876789976dEcBfCbBbe364623C63652db8C0904` | `0x112908daC86e20e7241B0927479Ea3Bf935d1fa0` |
| Uniswap v3 Factory | *(not yet recovered)* | `0x640887A9ba3A9C53Ed27D0F7e8246A4F933f3424` |
| Permit2 (canonical) | `0x000000000022D473030F116dDEE9F6B43aC78BA3` | same |

Robinhood's Universal Router is a **bespoke fork** (RouteSigner / ChainedActions), not vanilla
Uniswap. Two encoding differences are handled in `lib/LaunchRouting.sol`:
- `V3_SWAP_EXACT_IN` takes an extra trailing `uint256[] minHopPriceX36`
- v4 `ExactInputSingleParams` has 6 fields on Robinhood vs 5 on Ink

Both chains run a newer v4-periphery than the docs assume — action ids are `0x06` / `0x0c` / `0x0f`,
not `0x04` / `0x10` / `0x13`.

---

## Configured quote tokens

Native ETH (`address(0)`) is enabled on all three launch families on both chains. On the curve and
crowdfund it bypasses the allowlist entirely, so `quoteTokenAllowed[address(0)]` reads `false` by
design — that is correct, not a misconfiguration.

Curated from a real on-chain liquidity scan; every token below cleared $20,000 of usable liquidity
at scan time.

### Robinhood (4663) — 16 tokens

| Symbol | Address |
|---|---|
| BTC | `0xCEC185eB182c47d1bA1EFc84e6959e18cd620Be4` |
| USDG | `0x5fc5360D0400a0Fd4f2af552ADD042D716F1d168` |
| TAO | `0xf3081494B87e8D5fb7960f066E931D1D0e6E3d67` |
| U | `0xcE24439F2D9C6a2289F741120FE202248B666666` |
| SPY | `0x117cc2133c37B721F49dE2A7a74833232B3B4C0C` |
| NVDA | `0xd0601CE157Db5bdC3162BbaC2a2C8aF5320D9EEC` |
| SPCX | `0x4a0E65A3EcceC6dBe60AE065F2e7bb85Fae35eEa` |
| AAPL | `0xaF3D76f1834A1d425780943C99Ea8A608f8a93f9` |
| TSLA | `0x322F0929c4625eD5bAd873c95208D54E1c003b2d` |
| GLD | `0xC9a981FEE1F9DEc688bb123ccDeCc63D0deBFC4e` |
| GOOGL | `0x2e0847E8910a9732eB3fb1bb4b70a580ADAD4FE3` |
| QQQ | `0xD5f3879160bc7c32ebb4dC785F8a4F505888de68` |
| MSTR | `0xec262a75e413fAfD0dF80480274532C79D42da09` |
| GME | `0x1b0E319c6A659F002271B69dB8A7df2F911c153E` |
| AMZN | `0x12f190a9F9d7D37a250758b26824B97CE941bF54` |
| MSFT | `0xe93237C50D904957Cf27E7B1133b510C669c2e74` |

Deliberately **disabled** (real tokens, but below the $20,000 liquidity bar): LINK
`0x492641F648a4986844848E0beFE66D14817bCE34`, PONS `0x39dBED3a2bd333467115dE45665cC57F813C4571`,
CASHCAT `0x020bfC650A365f8BB26819deAAbF3E21291018b4`, Index
`0x56910D4409F3a0C78C64DD8D0545FF0705389870`.

### Ink (57073) — 10 tokens

| Symbol | Address |
|---|---|
| BTC | `0x73E0C0d45E048D25Fc26Fa3159b0aA04BfA4Db98` |
| USDT0 | `0x0200C29006150606B650577BBE7B6248F58470c1` |
| USDC (bridged) | `0xF1815bd50389c46847f0Bda824eC8da914045D14` |
| NVDA (wrapped) | `0xa8ddb5Cd96b5222AFe198316E9A57CAA642850D5` |
| MSTR (wrapped) | `0x30987adF0B11dc698438a99BA04ec3a1AB2c7EaB` |
| SPY (wrapped) | `0xE7E553Cd128F0011777323A0b44a7b96EA1CB540` |
| SPCX (wrapped) | `0x8e2eeD8b8B5E13Ea7BF38e50d7821d2C57309072` |
| AAPL (wrapped) | `0x943BF64D566c32A2Bcd41AC92FB63C111cC9De8f` |
| NFLX (wrapped) | `0x7d87fD6A379714194a797c0bBB8B40c30D250856` |
| TSLA (wrapped) | `0xc3FdBe3A68EE5dE461D30415a8165cf9Aefe1171` |

---

## Known outstanding work

1. **`setRoutes` is not configured for any quote token on either chain.** Until it is, every swap
   path through the Universal Router is inert. Verified real pool parameters exist for only two
   pairs so far: Robinhood USDG (v3 fee 100; v4 fee 100 / tickSpacing 1) and Ink USDT0 (v3 fee
   3000; v4 fee 3000 / tickSpacing 60). The remaining 24 need an on-chain pool scan.
2. **`DuckLauncher.initialize()` hardcodes Robinhood's quote-token list with no chain check**
   (`launcher/DuckLauncher.sol`, `_seedDefaultQuoteTokens`). Live state on both chains has been
   corrected by owner calls, but a third chain would reproduce the bug. Fix belongs in the next
   implementation revision.
3. **No contracts are verified on either explorer.** `foundry.toml` has no `[etherscan]` block.
4. **Ownership transfer** to a multisig (see warning above).
5. `test_HardFork_ManyTokensManyWalletsCurveFeeNeverLeaksToVault` has never completed a run — three
   transient RPC failures against the free public Robinhood endpoint. Believed infrastructural, but
   unproven; it should be run once against a paid RPC.

## Deployment cost (actual)

| Chain | Transactions | Gas | Paid |
|---|---|---|---|
| Robinhood | 76 | 44,906,256 | 0.00438 ETH @ ~0.0975 gwei |
| Ink | 64 | 44,270,946 | 0.000000106 ETH @ ~0.0000024 gwei |
