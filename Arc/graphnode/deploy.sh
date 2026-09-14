#!/usr/bin/env bash
# Goldsky does not support Arc mainnet (chain 5042) for subgraph indexing
# yet -- confirmed by direct testing against their API, not just docs (they
# only have arc-testnet, a different chain, ID 5042002). So this deploys to
# our own self-hosted graph-node instead (see this directory's render.yaml,
# duckfun-graph-node/-ipfs/-postgres services) rather than Goldsky.
#
# graph-node's admin/IPFS ports are on Render's private network only (no
# public internet access -- graph-node's admin API has no built-in auth, so
# exposing it publicly would let anyone deploy/delete subgraphs on it). Reach
# them from your own machine with the Render CLI's tunnel feature:
#
#   render login                          # once
#   render connect duckfun-graph-node     # keep running in another terminal;
#                                          # prints the local ports it forwards
#
# Then set GRAPH_NODE_ADMIN_URL/IPFS_URL below to whatever localhost ports
# that tunnel printed (it forwards every port the service exposes, so both
# graph-node's 8020 admin port and duckfun-graph-ipfs's 5001 need their own
# `render connect` tunnel, or run two tunnels at once in separate terminals).
set -euo pipefail

GRAPH_NODE_ADMIN_URL="${GRAPH_NODE_ADMIN_URL:?Set to the tunneled graph-node admin URL, e.g. http://localhost:8020 (see this file's header)}"
IPFS_URL="${IPFS_URL:?Set to the tunneled duckfun-graph-ipfs URL, e.g. http://localhost:5001 (see this file's header)}"

npx graph create --node "$GRAPH_NODE_ADMIN_URL" duckfun-arc
npx graph deploy --node "$GRAPH_NODE_ADMIN_URL" --ipfs "$IPFS_URL" duckfun-arc --version-label "$(date +%Y.%m.%d%H%M%S)"
