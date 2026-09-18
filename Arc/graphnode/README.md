# DuckProtocol subgraph — Arc

Subgraph for the DuckProtocol Arc build (`../`) on Arc mainnet (5042), deployed to
Goldsky as `duck-subgraph-arc`, alongside the Robinhood Chain and Ink subgraphs.

It indexes the same entities, with the same handlers, as the Robinhood Chain and Ink subgraphs: the
bonding curve, launcher, crowdfund and reliquify (token migrations), DuckGenesisHook and the PoolManager swaps in its pools, lending
vaults and their factory/config, per-token governance, and each token's transfers and holder rewards.
Every other admin event is stored as an `AdminEvent`.

## Contracts

| Data source | Address |
|---|---|
| DuckBondingCurve | `0xFD5FAE76B375e1dA6A3F1759eB84B26b39dE706C` |
| DuckLauncher | `0xf916E628503639DCb4726d4B75745Ad678dc4d02` |
| DuckCrowdfund | `0x0c8f0f1353f2d963D03C3eC558D20b151DaF7214` |
| DuckReliquify | `0xf7F65C4e96E8D2f4b960E1d7837Cf3c4520412bA` |
| DuckVaultFactory | `0xE3D4d83307E6f5A2C7B4b85436eAacAfd1B873C3` |
| DuckVaultConfig | `0xb0d1E41Af535a986e61A9ce39ea31e7ef65A4EE8` |
| DuckTokenGovernorFactory | `0x3271b5e9F53E5096508519126528373Adc4e3Aec` |
| DuckGenesisHook | `0x6A44E6a1dF1e4cC329Dda87389ecA12DA9422aCC` |
| PoolManager (Uniswap v4) | `0x8366a39CC670B4001A1121B8F6A443A643e40951` |

All start at block 20792816, except `DuckReliquify` (deployed later) at block 21535490. `DuckToken` (the three token templates), `DuckVault`,
`DuckTokenGovernor` and `TimelockControllerUpgradeable` are templates created as they appear.

## USD pricing on Arc

USDC is Arc's native gas token and the ERC-20 at `0x3600000000000000000000000000000000000000` is the same balance, so both count as
exactly $1 and every USDC-quoted trade is priced directly. There is no ETH reference: a quote token
other than USDC gets a price discovered from its deepest Uniswap v3 pool against USDC (factory
`0xf0db7b58379503491d857db50ac9ece64c653918`) or v4 pool against native USDC, marked `origin: DISCOVERED`.

## Deploy

```
npm install
npm run deploy     # new Goldsky version, tagged "current"
```

`deploy.sh` runs codegen and build, deploys a uniquely versioned `duck-subgraph-arc` to Goldsky and moves the
`current` tag to it, so consumers using the `/current/` endpoint never need a URL change (the backend and
keeper default to it). It needs the `goldsky` CLI logged in to the DuckProtocol project.

`render.yaml` in this directory describes the self-hosted graph-node Arc used before Goldsky supported it.
It is no longer used; delete it once those Render services are gone.

## Changing it

Everything here except `render.yaml` (retired) and this generator is generated. Edit the shared generator
(`DuckProtocol-HQ/subgraph/gen_subgraphs.py`) or `gen_subgraph_arc.py`, then run
`python3 gen_subgraph_arc.py`.
