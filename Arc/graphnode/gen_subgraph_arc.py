#!/usr/bin/env python3
"""Generates the DuckProtocol subgraph for Arc (5042) in this directory.

Schema, mappings and pricing code come from the Robinhood Chain / Ink generator
(DuckProtocol-HQ/subgraph/gen_subgraphs.py), so Arc indexes the same entities with the same handlers.
What this script changes for Arc:
  - ABIs come from the Arc build (../deploy/out). The three token templates share DuckOpenToken's ABI,
    which is emitted under the name DuckToken so the shared mappings bind to it unchanged;
  - Arc's addresses and start block; Arc launched directly on DuckGenesisHook, so there is no DuckHookV4
    data source;
  - pricing: native USDC and the USDC ERC-20 are the $1 stablecoin, and a price quoted in native units is
    already USD (there is no ETH reference on Arc);
  - deploy.sh targets the self-hosted graph-node in render.yaml instead of Goldsky, which doesn't index
    Arc mainnet.

  python3 gen_subgraph_arc.py        # rewrites abis/, src/, schema, manifest, deploy.sh, package.json, README
"""
import importlib.util, json, os, shutil

HERE = os.path.dirname(os.path.abspath(__file__))
HQ_GENERATOR = os.environ.get(
    'HQ_SUBGRAPH_GENERATOR', '/home/mindless/Pictures/Unstable/DuckLibrary/DuckProtocol-HQ/subgraph/gen_subgraphs.py')
ARC_OUT = os.path.join(HERE, '..', 'deploy', 'out')

NETWORK = 'arc'                  # must match the graph-node's `ethereum` setting in render.yaml
SUBGRAPH_NAME = 'duckprotocol-arc'
START_BLOCK = 20792816           # block of the first DeployDuckProtocolArc transaction
USDC = '0x3600000000000000000000000000000000000000'
ZERO = '0x0000000000000000000000000000000000000000'
HOOK = '0x6A44E6a1dF1e4cC329Dda87389ecA12DA9422aCC'
POOL_MANAGER = '0x8366a39CC670B4001A1121B8F6A443A643e40951'
# Uniswap v3 factory on Arc (Uniswap sdks repo, sdk-core ARC_ADDRESSES.v3CoreFactoryAddress), used to discover
# a price for a quote token other than USDC. Empty would skip v3 discovery and search v4 pools only.
V3_FACTORY = '0xf0db7b58379503491d857db50ac9ece64c653918'
ADDRESSES = {
    'DuckBondingCurve':         '0xFD5FAE76B375e1dA6A3F1759eB84B26b39dE706C',
    'DuckLauncher':             '0xf916E628503639DCb4726d4B75745Ad678dc4d02',
    'DuckCrowdfund':            '0x0c8f0f1353f2d963D03C3eC558D20b151DaF7214',
    'DuckVaultFactory':         '0xE3D4d83307E6f5A2C7B4b85436eAacAfd1B873C3',
    'DuckVaultConfig':          '0xb0d1E41Af535a986e61A9ce39ea31e7ef65A4EE8',
    'DuckTokenGovernorFactory': '0x3271b5e9F53E5096508519126528373Adc4e3Aec',
}
CFG = dict(network=NETWORK, chainName='Arc (5042)', slug=SUBGRAPH_NAME, startBlock=START_BLOCK,
           hook=HOOK, genesisHook=HOOK, genesisStartBlock=START_BLOCK, poolManager=POOL_MANAGER)

GENERATED = ['abis', 'src', 'schema.graphql', 'subgraph.yaml', 'deploy.sh', 'package.json', '.gitignore', 'README.md']


def load_hq():
    spec = importlib.util.spec_from_file_location('gen_subgraphs', HQ_GENERATOR)
    g = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(g)
    return g


def patch(text, old, new):
    assert text.count(old) == 1, f'shared generator changed; cannot find: {old[:80]!r}'
    return text.replace(old, new)


def configure(g):
    g.COMMON = ADDRESSES
    g.SOURCES = [s for s in g.SOURCES if s[0] != 'DuckHookV4']
    g.STABLES[NETWORK] = [USDC, ZERO]
    g.WRAPPED_NATIVE[NETWORK] = USDC
    g.V3_FACTORY[NETWORK] = V3_FACTORY.lower()
    g.V4_POOL_MANAGER[NETWORK] = POOL_MANAGER.lower()

    pricing = g.HELPERS['pricing.ts']
    pricing = patch(pricing, '''  let native = QuotePrice.load(Address.zero());
  if (native == null) return null;''', '''  // On a stablechain (Arc) native is the $1 stablecoin, so a price in native units is already USD.
  if (stables.includes(ZERO_HEX)) return priceETH as BigDecimal;
  let native = QuotePrice.load(Address.zero());
  if (native == null) return null;''')
    g.HELPERS['pricing.ts'] = pricing

    discovery = g.HELPERS['discovery.ts']
    discovery = patch(discovery, '''  let factory = UniswapV3Factory.bind(Address.fromString(v3Factory(network)));
''', '''  // A network with no v3 factory configured searches v4 pools only.
  let factoryHex = v3Factory(network);
  if (factoryHex == "") bases = new Array<string>(0);
  let factory = UniswapV3Factory.bind(Address.fromString(factoryHex == "" ? ZERO_HEX : factoryHex));
''')
    g.HELPERS['discovery.ts'] = discovery

    # Arc has no curated reference pools, so no PriceReference data source (and no generated folder for
    # it) exists; the DiscoveredV3Pool template generates the same UniswapV3Pool binding.
    g.HELPERS['ref-pool.ts'] = patch(g.HELPERS['ref-pool.ts'],
        'from "../generated/PriceReference0/UniswapV3Pool";',
        'from "../generated/templates/DiscoveredV3Pool/UniswapV3Pool";')


def load_abis(g):
    names = [n for n in g.CONTRACT_ABIS if n not in ('DuckHookV4', 'DuckToken')]
    abis = {n: json.load(open(f'{ARC_OUT}/{n}.sol/{n}.json'))['abi'] for n in names}
    # DuckCurveToken, DuckLauncherToken and DuckCrowdfundToken are DuckOpenToken with a constructor.
    abis['DuckToken'] = json.load(open(f'{ARC_OUT}/DuckOpenToken.sol/DuckOpenToken.json'))['abi']
    abis['PoolManager'] = json.load(open(g.OLD_POOLMANAGER_ABI))
    abis['ERC20'] = g.ERC20_ABI
    abis['UniswapV3Pool'] = g.UNISWAP_V3_POOL_ABI
    abis['UniswapV3Factory'] = g.UNISWAP_V3_FACTORY_ABI
    abis['V4StateReader'] = g.V4_STATE_READER_ABI
    return abis


DEPLOY = r'''#!/usr/bin/env bash
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

NAME=__NAME__
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
'''


def readme():
    rows = ''.join(f'| {name} | `{addr}` |\n' for name, addr in ADDRESSES.items())
    return f'''# DuckProtocol subgraph — Arc

Subgraph for the DuckProtocol Arc build (`../`) on Arc mainnet (5042), deployed to the self-hosted
graph-node described in `render.yaml` as `{SUBGRAPH_NAME}`. Goldsky doesn't index Arc mainnet.

It indexes the same entities, with the same handlers, as the Robinhood Chain and Ink subgraphs: the
bonding curve, launcher and crowdfund, DuckGenesisHook and the PoolManager swaps in its pools, lending
vaults and their factory/config, per-token governance, and each token's transfers and holder rewards.
Every other admin event is stored as an `AdminEvent`.

## Contracts

| Data source | Address |
|---|---|
{rows}| DuckGenesisHook | `{HOOK}` |
| PoolManager (Uniswap v4) | `{POOL_MANAGER}` |

All start at block {START_BLOCK}. `DuckToken` (the three token templates), `DuckVault`,
`DuckTokenGovernor` and `TimelockControllerUpgradeable` are templates created as they appear.

## USD pricing on Arc

USDC is Arc's native gas token and the ERC-20 at `{USDC}` is the same balance, so both count as
exactly $1 and every USDC-quoted trade is priced directly. There is no ETH reference: a quote token
other than USDC gets a price discovered from its deepest Uniswap v3 pool against USDC (factory
`{V3_FACTORY}`) or v4 pool against native USDC, marked `origin: DISCOVERED`.

## Deploy

```
npm install
bash deploy.sh      # needs GRAPH_NODE_ADMIN_URL and IPFS_URL; see the header of deploy.sh
```

`deploy.sh` runs codegen and build, registers `{SUBGRAPH_NAME}` on first use, and deploys a new
version. Services on the same Render network query it at
`http://duckfun-graph-node:8000/subgraphs/name/{SUBGRAPH_NAME}`. The earlier `duckfun-arc` subgraph on
that node (the previous Arc contracts) is left as it is.

## Changing it

Everything here except `render.yaml` and this generator is generated. Edit the shared generator
(`DuckProtocol-HQ/subgraph/gen_subgraphs.py`) or `gen_subgraph_arc.py`, then run
`python3 gen_subgraph_arc.py`.
'''


def main():
    g = load_hq()
    configure(g)
    abis = load_abis(g)

    for name in GENERATED:
        path = os.path.join(HERE, name)
        if os.path.isdir(path):
            shutil.rmtree(path)
        elif os.path.exists(path):
            os.remove(path)
    os.makedirs(f'{HERE}/src')
    os.makedirs(f'{HERE}/abis')

    for name, abi in abis.items():
        json.dump(abi, open(f'{HERE}/abis/{name}.json', 'w'), indent=2)
    open(f'{HERE}/schema.graphql', 'w').write(g.SCHEMA)
    for fname, text in g.HELPERS.items():
        open(f'{HERE}/src/{fname}', 'w').write(text)
    open(f'{HERE}/src/price-config.ts', 'w').write(g.price_config())
    total_events = total_rich = 0
    for source, abi_name, file_, is_template, extra, entities in g.SOURCES:
        text, n_ev, n_rich = g.build_mapping(abis, source, abi_name, file_, is_template)
        open(f'{HERE}/src/{file_}.ts', 'w').write(text)
        total_events += n_ev
        total_rich += n_rich
    open(f'{HERE}/subgraph.yaml', 'w').write(g.manifest(abis, CFG))
    open(f'{HERE}/deploy.sh', 'w').write(DEPLOY.replace('__NAME__', SUBGRAPH_NAME))
    os.chmod(f'{HERE}/deploy.sh', 0o755)
    pkg = {"name": SUBGRAPH_NAME, "version": "1.0.0", "private": True,
           "scripts": {"codegen": "graph codegen", "build": "graph build", "deploy": "bash deploy.sh"},
           "dependencies": {"@graphprotocol/graph-cli": "^0.98.1", "@graphprotocol/graph-ts": "^0.38.1"}}
    open(f'{HERE}/package.json', 'w').write(json.dumps(pkg, indent=2) + '\n')
    open(f'{HERE}/.gitignore', 'w').write('node_modules/\ngenerated/\nbuild/\n')
    open(f'{HERE}/README.md', 'w').write(readme())
    print(f'{SUBGRAPH_NAME}: {total_events} events indexed, {total_rich} with dedicated handlers, rest recorded as AdminEvent')


if __name__ == '__main__':
    main()
