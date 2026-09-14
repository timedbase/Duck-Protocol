# duckfun.family subgraph — Arc

> Copied into `DuckProtocol/Arc/graphnode` from the workspace's `subgraph-arc`, together with the graph-node
> services (`render.yaml` here). As copied, it still indexes the earlier Arc deployment described below
> (Duck-Family-Contract: DuckIncubationArc, DuckLauncherArc, DuckRaiseArc, DuckLockerArc, DuckHookV4Arc). The
> DuckProtocol Arc build in this repo (DuckBondingCurve, DuckLauncher, DuckCrowdfund, DuckGenesisHook, lending)
> needs its own data sources, ABIs and mappings once it's deployed, under a new subgraph name so the live
> `duckfun-arc` index isn't replaced.

Indexes activity across all three launcher families (`DuckIncubationArc`,
`DuckLauncherArc`, `DuckRaiseArc`), the shared `DuckLockerArc` and
`DuckHookV4Arc` (including `DuckLockerArc`'s V3-specific fee-claim/CTO flow —
Ink has no equivalent), and raw Uniswap V4 `PoolManager` swap/liquidity
activity for pools this platform created — on Arc chain (5042).

Addresses are pinned to the live deployment recorded in the
[Duck-Family-Contract](https://github.com/timedbase/Duck-Family-Contract) repo's
`deploy-arc/deployments/arc.json`.

## Why this isn't on Goldsky (unlike the Ink subgraph)

Goldsky does not support Arc mainnet (chain 5042) for subgraph indexing —
confirmed by directly testing `goldsky subgraph deploy` against their API
(not just reading docs, which are themselves inconsistent on this point).
Every plausible network slug (`arc`, `arc-mainnet`, `arc_mainnet`,
`circle-arc`, `arc1`, `arc-1`, `arcmainnet`) was rejected with `Subgraph
network not supported`. Goldsky's own docs confirm only `arc-testnet` (a
**different chain**, ID 5042002) exists on their platform today.

So this subgraph runs on a self-hosted `graph-node` instead — see
`render.yaml` in this directory (`duckfun-graph-postgres`,
`duckfun-graph-ipfs`, `duckfun-graph-node`), three private services mirroring
graph-node's own reference
[docker-compose.yml](https://github.com/graphprotocol/graph-node/blob/master/docker/docker-compose.yml)
exactly. Revisit Goldsky once/if they add real Arc mainnet support — nothing
about the subgraph code itself is Goldsky-specific.

## What's indexed

Same shape as the Ink subgraph, plus DuckLockerArc's V3 flow:

- **Token lifecycle** — creation/launch (`Token`), bonding-curve buys/sells
  (`Trade`), migration (`Migration`), curve-fee claims (`CurveFeeClaim`).
- **Crowdfunding** — `Campaign` + `Contribution`.
- **LP position / hook (V4)** — `Position` + `LPFeeClaim`, `Pool` +
  `HookFeeClaim` + `CTOApplication`.
- **LP position / locker (V3-only, Arc-specific)** — the same `Position`
  entity (`isV3: true`, `creator` set directly since V3 has no hook to look
  it up from) and `LPFeeClaim` (`toCreator` populated, unlike a V4 claim) for
  fee collection, plus a separate `V3CTOApplication` entity for the
  locker-hosted CTO flow (`applyForCTOV3`/`approveCTOV3`/`rejectCTOV3` on
  DuckLockerArc — V3 has no hook to host this on, unlike V4's `CTOApplication`
  keyed by `Pool`).
- **Raw pool activity (V4 only)** — `PoolSwap`/`PoolLiquidityChange` off the
  real Uniswap V4 `PoolManager` singleton, filtered to this platform's pools.
  No V3 equivalent is indexed — V3 pools are per-pair standalone contracts
  with no shared emitter to watch generically; DuckLockerArc's own
  `FeesClaimedV3`/`PositionRegistered` already cover what this platform needs.
- **Holder balances** — `Holder`, via a per-token `Transfer` template.

## What's different from the Ink subgraph (beyond V3)

- **No `ReferencePrice` entity / no ETH-USD tracking.** Arc has no WETH —
  native currency here already IS USDC (18-decimal), pegged 1:1 to USD, so
  `lib.ts` resolves it directly with no live reference-price pool to watch
  at all (Ink needs one because ETH itself has no fixed USD peg).
- **No `DuckMetaOverride` data source.** That registry hasn't been deployed
  on Arc yet (a separate script, not run as part of the initial Arc
  contract deploy) — add it back here if/when it is.
- **No default quote-token seeding.** Arc's contracts don't seed any quote
  tokens on deploy (see the contracts repo's notes) — until real ones are
  added via `setQuoteTokenAllowed`/`setRoutes`, only native-currency trades
  will resolve a USD price.

## Local build

```bash
npm install
npm run codegen   # generates generated/ from subgraph.yaml + schema.graphql + abis/
npm run build     # compiles the AssemblyScript mappings to build/*.wasm
```

Both run clean — zero codegen/compile errors.

## Deploying to the self-hosted graph-node

The `duckfun-graph-node`/`duckfun-graph-ipfs` services are Render **private**
services (no public internet access — graph-node's admin API has no built-in
auth, so exposing it publicly would let anyone deploy/delete subgraphs on
it). Reach them from your own machine with the Render CLI's tunnel feature:

```bash
render login                          # once, opens a browser to authenticate
render connect duckfun-graph-node     # keep running in one terminal
render connect duckfun-graph-ipfs     # keep running in another terminal
```

Each prints the local port it's forwarding. Then, in a third terminal:

```bash
cd Arc/graphnode
GRAPH_NODE_ADMIN_URL=http://localhost:<forwarded graph-node port> \
IPFS_URL=http://localhost:<forwarded ipfs port> \
  bash deploy.sh
```

`deploy.sh` runs `graph create` (once) then `graph deploy` (every time,
always under the same subgraph name `duckfun-arc` with an auto-generated
version label) — check its header comment for the full explanation.

Once deployed, the backend and anything else on Render's private network
reaches its GraphQL endpoint at `http://duckfun-graph-node:8000/subgraphs/name/duckfun-arc`
(the API's `ARC_SUBGRAPH_URL` in the workspace-root `render.yaml`) — no tunnel needed for that, since
it's server-to-server on the same private network.

## Schema conventions

Same as the Ink subgraph (see its README) — token/position/pool keyed
directly by address/poolId, not back-referenced from `Token`, everything
else event-shaped (`txHash-logIndex`).
