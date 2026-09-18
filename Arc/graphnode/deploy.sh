#!/usr/bin/env bash
# Deploys a new, uniquely versioned subgraph to Goldsky and moves the "current" tag to it, so
# consumers using the /current/ endpoint never need a URL change.
set -euo pipefail
cd "$(dirname "$0")"

NAME=duck-subgraph-arc
VERSION=$(date +%Y.%m.%d%H%M%S)

npx graph codegen
npx graph build
goldsky subgraph deploy "${NAME}/${VERSION}" --path .
goldsky subgraph tag create "${NAME}/${VERSION}" --tag current
echo "Deployed ${NAME}/${VERSION} and tagged it current"
