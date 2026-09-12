# Duck Protocol

Duck Protocol is a token-launch and lending platform on Ink (chain id `57073`). It offers three
independent ways to launch a token — a bonding curve, an instant Uniswap v4 launcher, and a
crowdfund — all backed by shared infrastructure for fee routing, LP locking, and a per-token
lending market that lets holders borrow against their launched tokens.

## Architecture

### Launch mechanisms

- **Bonding curve** (`bonding-curve/`) — tokens trade against a virtual curve until a migration
  target is hit, then migrate into a real Uniswap v4 pool. Supports both native and ERC-20 quote
  assets; the raise is always held directly in the token's real quote asset, never swapped from a
  different one at migration.
- **Launcher** (`launcher/`) — deploys a token and a fully-seeded Uniswap v4 pool in one
  transaction, with an optional instant buy. Quote-asset choice is permissionless: any token
  address may be used, not just a platform-curated one.
- **Crowdfund** (`crowdfund/`) — a time-boxed raise with a funding goal; on success the raised
  funds seed a v4 pool and contributors claim a pro-rata token share, on failure they're refunded.
  Contributions are pulled directly in the campaign's own quote asset (native or ERC-20) — there is
  no swap at finalize, closing off the sandwich-attack surface a raise-then-swap design would have.

Bonding curve and crowdfund both gate quote-asset choice behind an owner-curated allowlist
(`quoteTokenAllowed` / `quoteAssetAllowed`); the launcher does not.

### Shared infrastructure (`shared/`)

- **`DuckHookV4`** — a Uniswap v4 hook shared by all three families. Applies the sell-side fee,
  splits it between a token's creator and its lending vault, and maintains a manipulation-resistant
  TWAP oracle (a fixed-cardinality ring buffer, committed to at most once per period) that the
  lending market prices collateral from.
- **`DuckLocker`** — holds every family's LP position and claims the pool's own LP-tier fee on the
  platform's behalf.

### Lending (`lending/`)

Every launched token gets its own per-token lending vault (`DuckVault`, deployed as an
`ERC1967Proxy` by `DuckVaultFactory`), funded by a creator-directed cut of the token's own fee
revenue (`vaultBps`, chosen at launch: 100/0, 90/10, 50/50, or 0/100 creator/vault). Holders can
borrow against their tokens up to a shared, owner-tunable LTV; positions are liquidated
permissionlessly once they cross a liquidation threshold, with the liquidator paid a bonus and any
uncoverable shortfall socialized against the vault's own reserves. Borrowing is bounded both by a
single-borrower cap (a share of circulating supply) and by a share of the pool's own live on-chain
depth, so the vault's exposure can never exceed what the token's real market could plausibly absorb.
Shared risk parameters (LTV, liquidation threshold/bonus, interest curve, exposure caps) live in one
singleton, `DuckVaultConfig`, so a platform-wide change is a single transaction rather than one per
vault.

Each vault is individually, opt-in upgradeable: only its own token's governance can authorize an
upgrade, and only to an implementation the platform has separately approved — a captured vote can
never point a vault at arbitrary code.

### Governance (`governance/`)

Each token can lazily deploy its own `DuckTokenGovernor` (cloned on first use, timelocked 5 days)
to vote on moving funds out of its lending vault. A withdrawal needs both a supermajority of
circulating-supply-weighted FOR votes and a minimum headcount of distinct participating holders,
so neither a single whale nor a crowd of zero-balance addresses can pass a proposal alone.

## Repository layout

```
lib/            shared libraries and types used by all three families
                (fee-split math, migration/minting helpers, the token
                implementation, the supply-tier menu, clone helpers)
bonding-curve/  DuckBondingCurve + its read-only views contract
launcher/       DuckLauncher
crowdfund/      DuckCrowdfund
shared/         DuckHookV4, DuckLocker
lending/        DuckVault, DuckVaultFactory, DuckVaultConfig, DuckVaultMath
governance/     DuckTokenGovernor, DuckTokenGovernorFactory
deploy/         the Foundry project: deploy scripts, the full test suite,
                and its own foundry.toml/remappings
```

Each of `lib/`, `bonding-curve/`, `launcher/`, `crowdfund/`, `shared/`, `lending/`, and
`governance/` is a plain source tree, not its own Foundry project — `deploy/` is the only one, and
it reaches the others through remappings (`duck-lib/`, `duck-bonding-curve/`, `duck-launcher/`,
`duck-crowdfund/`, `duck-shared/`, `duck-lending/`, `duck-governance/`) defined in
`deploy/foundry.toml`.

## Supply

A token's total supply is chosen at launch from a fixed menu of seven tiers (`lib/SupplyTiers.sol`),
selected by index — there is no free-form supply amount in any family:

| Tier | Supply |
|------|--------|
| 0 (default) | 1,000,000,000 |
| 1 | 10,000,000,000 |
| 2 | 100,000,000,000 |
| 3 | 1,000,000,000,000 |
| 4 | 10,000,000,000,000 |
| 5 | 100,000,000,000,000 |
| 6 | 1,000,000,000,000,000 |

## Building and testing

The Foundry project lives in `deploy/`:

```
cd deploy
forge build
INK_RPC_URL=<an Ink RPC endpoint> forge test
```

The fork tests (`test/*.fork.t.sol`) run against real Ink chain state — real Uniswap v4 contracts,
real tokens — rather than mocks, and need `INK_RPC_URL` set to a working Ink RPC endpoint.

## Deployment

Duck Protocol targets Ink mainnet, chain id `57073`. `deploy/script/DeployDuckProtocol.s.sol`
deploys every contract (families, shared infrastructure, lending, governance) and performs all
cross-contract wiring in one script; `deploy/deployments/` records deployed addresses.

## License

MIT.
