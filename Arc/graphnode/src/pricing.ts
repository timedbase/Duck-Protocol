import { Address, BigDecimal, BigInt, Bytes, dataSource, ethereum } from "@graphprotocol/graph-ts";
import { DiscoveredReferencePool, EthReferencePool, QuotePrice, QuoteToken } from "../generated/schema";
import { ERC20 } from "../generated/DuckBondingCurve/ERC20";
import { KIND_ETH_STABLE, KIND_TOKEN_ETH, RefPool, V4RefPool, refPools, stableTokens, v4RefPools, wrappedNative } from "./price-config";

const Q96 = BigInt.fromI32(2).pow(96).toBigDecimal();
const ZERO_HEX = "0x0000000000000000000000000000000000000000";

function pow10(n: i32): BigDecimal {
  return BigInt.fromI32(10).pow(n as u8).toBigDecimal();
}

export function toHuman(raw: BigInt, decimals: i32): BigDecimal {
  return raw.toBigDecimal().div(pow10(decimals));
}

// Decimals of a quote token, read from the token once and cached. Native ETH is address(0).
export function quoteDecimals(quote: Bytes | null): i32 {
  if (quote === null) return 18;
  let address = Address.fromBytes(quote as Bytes);
  if (address.equals(Address.zero())) return 18;
  let cached = QuoteToken.load(address);
  if (cached != null) return cached.decimals;

  let q = new QuoteToken(address);
  let erc20 = ERC20.bind(address);
  let d = erc20.try_decimals();
  q.decimals = d.reverted ? 18 : d.value;
  let sym = erc20.try_symbol();
  if (!sym.reverted) q.symbol = sym.value;
  q.save();
  return q.decimals;
}

function originOf(discovered: boolean): string {
  return discovered ? "DISCOVERED" : "CURATED";
}

// token1 per token0 from a pool's sqrtPriceX96, adjusted for both tokens' decimals.
export function price1Per0(sqrtPriceX96: BigInt, dec0: i32, dec1: i32): BigDecimal {
  let s = sqrtPriceX96.toBigDecimal().div(Q96);
  let raw = s.times(s);
  let e = dec0 - dec1;
  if (e > 0) return raw.times(pow10(e));
  if (e < 0) return raw.div(pow10(-e));
  return raw;
}

export function findRefPool(pool: Address): RefPool | null {
  let pools = refPools(dataSource.network());
  let hex = pool.toHexString();
  for (let i = 0; i < pools.length; i++) {
    if (pools[i].pool == hex) return pools[i];
  }
  let d = DiscoveredReferencePool.load(pool);
  if (d == null) return null;
  if (d.isV4) return null;
  let r = new RefPool(hex, d.token.toHexString(), d.kind, d.pricedIsToken0, d.dec0, d.dec1);
  r.discovered = true;
  return r;
}

export function findV4RefPool(poolId: Bytes): V4RefPool | null {
  let pools = v4RefPools(dataSource.network());
  let hex = poolId.toHexString();
  for (let i = 0; i < pools.length; i++) {
    if (pools[i].poolId == hex) return pools[i];
  }
  let d = DiscoveredReferencePool.load(poolId);
  if (d == null) return null;
  if (!d.isV4) return null;
  let r = new V4RefPool(hex, d.token.toHexString(), d.dec1);
  r.discovered = true;
  return r;
}

export function writeQuotePrice(token: Address, priceUSD: BigDecimal | null, priceETH: BigDecimal | null, source: Bytes, event: ethereum.Event, origin: string, depthUSD: BigDecimal | null): void {
  let loaded = QuotePrice.load(token);
  if (loaded == null) loaded = new QuotePrice(token);
  let q = loaded as QuotePrice;
  q.priceUSD = priceUSD;
  q.priceETH = priceETH;
  q.source = source;
  q.origin = origin;
  if (depthUSD !== null) q.depthUSD = depthUSD;
  q.updatedAt = event.block.timestamp;
  q.updatedAtBlock = event.block.number;
  q.save();
}

function updateEthPrice(pool: Address, priceUSD: BigDecimal, liquidity: BigInt, event: ethereum.Event): void {
  let loaded = EthReferencePool.load(pool);
  if (loaded == null) loaded = new EthReferencePool(pool);
  let ref = loaded as EthReferencePool;
  ref.priceUSD = priceUSD;
  ref.liquidity = liquidity;
  ref.updatedAt = event.block.timestamp;
  ref.save();

  // ETH/USD across every ETH/stablecoin reference pool on this network, weighted by in-range liquidity.
  let network = dataSource.network();
  let pools = refPools(network);
  let weighted = BigDecimal.zero();
  let totalWeight = BigDecimal.zero();
  for (let i = 0; i < pools.length; i++) {
    if (pools[i].kind != KIND_ETH_STABLE) continue;
    let other = EthReferencePool.load(Address.fromString(pools[i].pool));
    if (other == null) continue;
    let w = other.liquidity.toBigDecimal();
    weighted = weighted.plus(other.priceUSD.times(w));
    totalWeight = totalWeight.plus(w);
  }
  if (totalWeight.equals(BigDecimal.zero())) return;
  let ethUSD = weighted.div(totalWeight);
  writeQuotePrice(Address.zero(), ethUSD, null, pool, event, "CURATED", null);
  writeQuotePrice(Address.fromString(wrappedNative(network)), ethUSD, null, pool, event, "CURATED", null);
}

// A swap in a v3 reference pool.
export function recordReferenceSwap(ref: RefPool, sqrtPriceX96: BigInt, liquidity: BigInt, event: ethereum.Event): void {
  if (liquidity.isZero() || sqrtPriceX96.isZero()) return;
  let p1per0 = price1Per0(sqrtPriceX96, ref.dec0, ref.dec1);
  if (p1per0.equals(BigDecimal.zero())) return;
  // Price of the priced token in units of the pool's other token (ETH or a $1 stablecoin).
  let price = ref.pricedIsToken0 ? p1per0 : BigDecimal.fromString("1").div(p1per0);
  if (ref.kind == KIND_ETH_STABLE) {
    updateEthPrice(event.address, price, liquidity, event);
  } else if (ref.kind == KIND_TOKEN_ETH) {
    writeQuotePrice(Address.fromString(ref.token), null, price, event.address, event, originOf(ref.discovered), null);
  } else {
    writeQuotePrice(Address.fromString(ref.token), price, null, event.address, event, originOf(ref.discovered), null);
  }
}

// A swap in a v4 reference pool against native ETH, which is always currency0.
export function recordV4ReferenceSwap(ref: V4RefPool, sqrtPriceX96: BigInt, liquidity: BigInt, event: ethereum.Event): void {
  if (liquidity.isZero() || sqrtPriceX96.isZero()) return;
  let tokenPerEth = price1Per0(sqrtPriceX96, 18, ref.tokenDecimals);
  if (tokenPerEth.equals(BigDecimal.zero())) return;
  let priceETH = BigDecimal.fromString("1").div(tokenPerEth);
  writeQuotePrice(Address.fromString(ref.token), null, priceETH, Bytes.fromHexString(ref.poolId), event, originOf(ref.discovered), null);
}

// Current USD price of a quote token, or null if it has no reference price yet.
export function quoteUsd(quote: Bytes | null): BigDecimal | null {
  let network = dataSource.network();
  let hex = ZERO_HEX;
  if (quote !== null) hex = (quote as Bytes).toHexString();

  let stables = stableTokens(network);
  for (let i = 0; i < stables.length; i++) {
    if (stables[i] == hex) return BigDecimal.fromString("1");
  }
  if (hex == wrappedNative(network)) hex = ZERO_HEX;

  let q = QuotePrice.load(Address.fromString(hex));
  if (q == null) return null;
  if (q.priceUSD !== null) return q.priceUSD;
  let priceETH = q.priceETH;
  if (priceETH === null) return null;
  // On a stablechain (Arc) native is the $1 stablecoin, so a price in native units is already USD.
  if (stables.includes(ZERO_HEX)) return priceETH as BigDecimal;
  let native = QuotePrice.load(Address.zero());
  if (native == null) return null;
  let ethUSD = native.priceUSD;
  if (ethUSD === null) return null;
  return (priceETH as BigDecimal).times(ethUSD as BigDecimal);
}
