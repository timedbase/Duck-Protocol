#!/usr/bin/env bash
# Deploys the DuckProtocol Arc subgraph to the self-hosted graph-node (render.yaml in this directory).
# Goldsky doesn't index Arc mainnet (5042). The graph-node admin API and IPFS are private Render services,
# so tunnel to them first, each in its own terminal:
#
#   render login
#   render connect duckfun-graph-node     # forwards 8020 (admin) and 8000 (queries)
#   render connect duckfun-graph-ipfs     # forwards 5001
#
# then, with the local ports those tunnels print:
#
#   GRAPH_NODE_ADMIN_URL=http://localhost:8020 IPFS_URL=http://localhost:5001 bash deploy.sh
set -euo pipefail
cd "$(dirname "$0")"

NAME=duckprotocol-arc
GRAPH_NODE_ADMIN_URL="${GRAPH_NODE_ADMIN_URL:?set to the tunneled graph-node admin URL, e.g. http://localhost:8020}"
IPFS_URL="${IPFS_URL:?set to the tunneled IPFS URL, e.g. http://localhost:5001}"
VERSION=$(date +%Y.%m.%d%H%M%S)

npx graph codegen
npx graph build
# Registers the name on first deploy; on later deploys the name already exists and this is skipped.
if ! out=$(npx graph create --node "$GRAPH_NODE_ADMIN_URL" "$NAME" 2>&1); then
  echo "$out" | grep -qi "already exists" || { echo "$out"; exit 1; }
fi
npx graph deploy --node "$GRAPH_NODE_ADMIN_URL" --ipfs "$IPFS_URL" "$NAME" --version-label "$VERSION"
echo "Deployed $NAME ($VERSION). Queries: http://duckfun-graph-node:8000/subgraphs/name/$NAME"
