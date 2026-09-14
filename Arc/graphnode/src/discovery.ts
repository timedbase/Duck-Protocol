import { Address, BigDecimal, BigInt, ByteArray, Bytes, crypto, dataSource, ethereum } from "@graphprotocol/graph-ts";
import { DiscoveredReferencePool, QuoteDiscovery, QuotePrice } from "../generated/schema";
import { DiscoveredV3Pool } from "../generated/templates";
import { UniswapV3Factory } from "../generated/DuckBondingCurve/UniswapV3Factory";
import { UniswapV3Pool } from "../generated/DuckBondingCurve/UniswapV3Pool";
import { V4StateReader } from "../generated/DuckBondingCurve/V4StateReader";
import { ERC20 } from "../generated/DuckBondingCurve/ERC20";
import { KIND_TOKEN_ETH, KIND_TOKEN_STABLE, refPools, stableTokens, v3Factory, v4PoolManager, v4RefPools, wrappedNative } from "./price-config";
import { price1Per0, quoteDecimals, quoteUsd, toHuman, writeQuotePrice } from "./pricing";

// Finds a USD reference for a quote token with no curated one -- in practice an arbitrary token picked
// in the launcher. The token's Uniswap pools are read at the triggering event's block: v3 pools against
// WETH or a $1 stablecoin through the v3 factory the chain's Universal Router uses, and v4 pools against
// native ETH over common fee/tick-spacing pairs. The deepest, measured by USD on its ETH/stablecoin side,
// becomes the reference. No minimum depth is applied; the result is marked DISCOVERED.

const RETRY_SECONDS = BigInt.fromI32(6 * 3600);
const POOLS_SLOT: i32 = 6; // PoolManager._pools
const V3_FEES: i32[] = [100, 500, 2500, 3000, 10000];
const V4_FEES: i32[] = [100, 500, 3000, 10000, 2500, 2500, 1000, 1000, 5000, 20000, 50000];
const V4_SPACINGS: i32[] = [1, 10, 60, 200, 25, 50, 10, 20, 100, 400, 1000];
// v4 depth is the ETH a pool holds for a +10% price move; sqrt(1.1) bounds that range.
const SQRT_1_1 = BigDecimal.fromString("1.0488088481701515469914535136799");
const Q96 = BigInt.fromI32(2).pow(96).toBigDecimal();
const ZERO_HEX = "0x0000000000000000000000000000000000000000";

class Candidate {
  pool: Bytes = Bytes.empty();
  isV4: boolean = false;
  kind: i32 = 0;
  pricedIsToken0: boolean = false;
  dec0: i32 = 18;
  dec1: i32 = 18;
  depthUSD: BigDecimal = BigDecimal.zero();
  sqrtPriceX96: BigInt = BigInt.zero();
}

function isKnownQuote(hex: string, network: string): boolean {
  if (hex == ZERO_HEX) return true;
  if (hex == wrappedNative(network)) return true;
  let stables = stableTokens(network);
  for (let i = 0; i < stables.length; i++) {
    if (stables[i] == hex) return true;
  }
  let v3 = refPools(network);
  for (let i = 0; i < v3.length; i++) {
    if (v3[i].token == hex) return true;
  }
  let v4 = v4RefPools(network);
  for (let i = 0; i < v4.length; i++) {
    if (v4[i].token == hex) return true;
  }
  return false;
}

function addressWord(a: Address): Bytes {
  let out = new ByteArray(32);
  for (let i = 0; i < 20; i++) out[12 + i] = a[i];
  return Bytes.fromByteArray(out);
}

function uintWord(v: i32): Bytes {
  let out = new ByteArray(32);
  out[31] = (v & 0xff) as u8;
  out[30] = ((v >> 8) & 0xff) as u8;
  out[29] = ((v >> 16) & 0xff) as u8;
  out[28] = ((v >> 24) & 0xff) as u8;
  return Bytes.fromByteArray(out);
}

// A big-endian 32-byte storage slot plus n.
function slotPlus(slot: ByteArray, n: i32): Bytes {
  let out = new ByteArray(32);
  for (let i = 0; i < 32; i++) out[i] = slot[i];
  let carry = n;
  for (let i = 31; i >= 0; i--) {
    if (carry == 0) break;
    let sum = (out[i] as i32) + carry;
    out[i] = (sum & 0xff) as u8;
    carry = sum >> 8;
  }
  return Bytes.fromByteArray(out);
}

// The low `count` bytes of a big-endian 32-byte word, as an unsigned integer.
function lowBytes(word: Bytes, count: i32): BigInt {
  let littleEndian = new ByteArray(count);
  for (let i = 0; i < count; i++) littleEndian[i] = word[31 - i];
  return BigInt.fromUnsignedBytes(littleEndian);
}

function ethUsdOrZero(): BigDecimal {
  let eth = quoteUsd(Address.zero());
  if (eth === null) return BigDecimal.zero();
  return eth as BigDecimal;
}

// Finds a reference pool for `quote` if it needs one. Cheap when it does not: known quote tokens and
// already-priced ones return immediately, and failed attempts are retried at most every 6 hours.
export function ensureQuotePrice(quote: Bytes | null, event: ethereum.Event): void {
  if (quote === null) return;
  let token = Address.fromBytes(quote as Bytes);
  let network = dataSource.network();
  if (isKnownQuote(token.toHexString(), network)) return;
  if (QuotePrice.load(token) != null) return;
  let previous = QuoteDiscovery.load(token);
  if (previous != null) {
    if (previous.found) return;
    if (event.block.timestamp.minus(previous.lastAttemptAt).lt(RETRY_SECONDS)) return;
  }
  discover(token, network, event);
}

function discover(token: Address, network: string, event: ethereum.Event): void {
  let tokenHex = token.toHexString();
  let tokenDec = quoteDecimals(token);
  let ethUSD = ethUsdOrZero();
  let best = new Candidate();
  let found = false;

  // v3 pools against WETH, then each $1 stablecoin.
  let bases = new Array<string>(0);
  bases.push(wrappedNative(network));
  let stables = stableTokens(network);
  for (let i = 0; i < stables.length; i++) bases.push(stables[i]);
  // A network with no v3 factory configured searches v4 pools only.
  let factoryHex = v3Factory(network);
  if (factoryHex == "") bases = new Array<string>(0);
  let factory = UniswapV3Factory.bind(Address.fromString(factoryHex == "" ? ZERO_HEX : factoryHex));
  for (let b = 0; b < bases.length; b++) {
    let baseHex = bases[b];
    let base = Address.fromString(baseHex);
    let baseIsEth = b == 0;
    let baseDec = quoteDecimals(base);
    for (let f = 0; f < V3_FEES.length; f++) {
      let poolResult = factory.try_getPool(token, base, V3_FEES[f]);
      if (poolResult.reverted) continue;
      let poolAddress = poolResult.value;
      if (poolAddress.equals(Address.zero())) continue;
      let pool = UniswapV3Pool.bind(poolAddress);
      let slot0 = pool.try_slot0();
      if (slot0.reverted) continue;
      let liquidity = pool.try_liquidity();
      if (liquidity.reverted) continue;
      if (liquidity.value.isZero()) continue;
      let balance = ERC20.bind(base).try_balanceOf(poolAddress);
      if (balance.reverted) continue;
      let depth = toHuman(balance.value, baseDec);
      if (baseIsEth) depth = depth.times(ethUSD);
      if (found && !depth.gt(best.depthUSD)) continue;

      let c = new Candidate();
      c.pool = poolAddress;
      c.kind = KIND_TOKEN_STABLE;
      if (baseIsEth) c.kind = KIND_TOKEN_ETH;
      c.pricedIsToken0 = tokenHex < baseHex; // v3 orders tokens by address
      c.dec0 = baseDec;
      c.dec1 = tokenDec;
      if (c.pricedIsToken0) {
        c.dec0 = tokenDec;
        c.dec1 = baseDec;
      }
      c.depthUSD = depth;
      c.sqrtPriceX96 = slot0.value.getSqrtPriceX96();
      best = c;
      found = true;
    }
  }

  // v4 pools against native ETH, which is always currency0.
  let manager = V4StateReader.bind(Address.fromString(v4PoolManager(network)));
  for (let i = 0; i < V4_FEES.length; i++) {
    let key = addressWord(Address.zero())
      .concat(addressWord(token))
      .concat(uintWord(V4_FEES[i]))
      .concat(uintWord(V4_SPACINGS[i]))
      .concat(addressWord(Address.zero()));
    let poolId = Bytes.fromByteArray(crypto.keccak256(key));
    let stateSlot = crypto.keccak256(poolId.concat(uintWord(POOLS_SLOT)));
    let slot0 = manager.try_extsload(Bytes.fromByteArray(stateSlot));
    if (slot0.reverted) continue;
    let sqrtPriceX96 = lowBytes(slot0.value, 20);
    if (sqrtPriceX96.isZero()) continue;
    let liquidityWord = manager.try_extsload(slotPlus(stateSlot, 3));
    if (liquidityWord.reverted) continue;
    let liquidity = lowBytes(liquidityWord.value, 16);
    if (liquidity.isZero()) continue;

    let sp = sqrtPriceX96.toBigDecimal().div(Q96);
    let one = BigDecimal.fromString("1");
    let ethDepth = liquidity.toBigDecimal().times(one.div(sp).minus(one.div(sp.times(SQRT_1_1)))).div(BigInt.fromI32(10).pow(18).toBigDecimal());
    let depth = ethDepth.times(ethUSD);
    if (found && !depth.gt(best.depthUSD)) continue;

    let c = new Candidate();
    c.pool = poolId;
    c.isV4 = true;
    c.kind = KIND_TOKEN_ETH;
    c.pricedIsToken0 = false;
    c.dec0 = 18;
    c.dec1 = tokenDec;
    c.depthUSD = depth;
    c.sqrtPriceX96 = sqrtPriceX96;
    best = c;
    found = true;
  }

  let previous = QuoteDiscovery.load(token);
  let attempts = 0;
  if (previous != null) attempts = previous.attempts;
  let record = new QuoteDiscovery(token);
  record.attempts = attempts + 1;
  record.lastAttemptAt = event.block.timestamp;
  record.found = found;
  if (found) record.pool = best.pool;
  record.save();
  if (!found) return;

  let ref = new DiscoveredReferencePool(best.pool);
  ref.isV4 = best.isV4;
  ref.token = token;
  ref.kind = best.kind;
  ref.pricedIsToken0 = best.pricedIsToken0;
  ref.dec0 = best.dec0;
  ref.dec1 = best.dec1;
  ref.depthUSD = best.depthUSD;
  ref.discoveredAt = event.block.timestamp;
  ref.discoveredAtBlock = event.block.number;
  ref.save();
  if (!best.isV4) DiscoveredV3Pool.create(Address.fromBytes(best.pool));

  // Seed the price from the pool's current state so this event's own trade already has a USD value.
  let p1per0 = price1Per0(best.sqrtPriceX96, best.dec0, best.dec1);
  if (p1per0.equals(BigDecimal.zero())) return;
  let price = p1per0;
  if (!best.pricedIsToken0) price = BigDecimal.fromString("1").div(p1per0);
  if (best.kind == KIND_TOKEN_STABLE) {
    writeQuotePrice(token, price, null, best.pool, event, "DISCOVERED", best.depthUSD);
  } else {
    writeQuotePrice(token, null, price, best.pool, event, "DISCOVERED", best.depthUSD);
  }
}
