import { BigInt, BigDecimal } from "@graphprotocol/graph-ts";
import { Token, TokenHourData } from "../generated/schema";

const HOUR_SECONDS = BigInt.fromI32(3600);

// Arc has no WETH and no ETH<->stablecoin reference pool to track (unlike
// Ink) -- native currency here IS USDC itself (18-decimal), already pegged
// 1:1 to USD, so there's no live reference price to resolve at all. The
// ERC20 mirror of native USDC (see deploy-arc's NATIVE_ERC20_MIRROR) mirrors
// native exactly per Circle's own docs, so it's treated identically. Any
// other quote token (a real future Arc asset, or a platform token) falls
// through to the 18-decimals/unresolvable default below -- its own USD
// value isn't knowable without its own tracked market.
const ZERO_ADDRESS_HEX = "0x0000000000000000000000000000000000000000";
const NATIVE_USDC_MIRROR = "0x3600000000000000000000000000000000000000";

export function quoteHexOf(token: Token): string {
  return token.quoteToken !== null ? token.quoteToken!.toHexString() : ZERO_ADDRESS_HEX;
}

function isNativeUsdc(quoteHex: string): boolean {
  return quoteHex == ZERO_ADDRESS_HEX || quoteHex == NATIVE_USDC_MIRROR;
}

function quoteDecimals(quoteHex: string): i32 {
  return 18; // native USDC (or its mirror), or an unknown/platform quote token -- all 18 decimals on Arc
}

function toHuman(raw: BigInt, decimals: i32): BigDecimal {
  return raw.toBigDecimal().div(BigInt.fromI32(10).pow(decimals as u8).toBigDecimal());
}

// Native USDC (and its mirror) pegged 1:1 to USD -- no separate market
// needed, unlike Ink's ETH which required a live reference price. Anything
// else (a platform token) returns null -- honestly unresolvable without
// that token's own tracked market, never fabricated.
function resolveUsd(quoteHex: string, humanQuoteAmount: BigDecimal): BigDecimal | null {
  if (isNativeUsdc(quoteHex)) return humanQuoteAmount;
  return null;
}

// Shared by curve Trade handling (duck-incubation.ts) and pool-based
// PoolSwap handling (pool-manager.ts) -- both real trade paths, quoteAmount/
// tokenAmount always the absolute RAW magnitudes actually exchanged (token
// side always 18 decimals -- every token clone this platform creates is a
// plain 18-decimal ERC20). Updates Token.lastPrice/lastPriceUsd,
// volumeAllTime/volumeAllTimeUsd, and this hour's TokenHourData bucket
// (volume + a closePrice/closePriceUsd snapshot -- the last trade's price
// each hour naturally becomes that hour's "close" as later trades overwrite
// it) in one pass, avoiding two separate Token.load()/save() round-trips.
export function recordTrade(tokenId: string, timestamp: BigInt, quoteAmountRaw: BigInt, tokenAmountRaw: BigInt, quoteHex: string): void {
  let token = Token.load(tokenId);
  if (token == null) return;

  token.lastTradeAt = timestamp;

  let price: BigDecimal | null = null;
  let priceUsd: BigDecimal | null = null;
  if (!tokenAmountRaw.equals(BigInt.zero())) {
    let humanQuote = toHuman(quoteAmountRaw, quoteDecimals(quoteHex));
    let humanToken = toHuman(tokenAmountRaw, 18);
    let p: BigDecimal = humanQuote.div(humanToken);
    price = p;
    token.lastPrice = p;
    let usd = resolveUsd(quoteHex, p);
    if (usd === null) {
      token.lastPriceUsd = null;
    } else {
      let usdValue: BigDecimal = usd;
      priceUsd = usdValue;
      token.lastPriceUsd = usdValue;
    }
  }

  let humanQuoteVol = toHuman(quoteAmountRaw, quoteDecimals(quoteHex));
  let volUsd = resolveUsd(quoteHex, humanQuoteVol);
  token.volumeAllTime = token.volumeAllTime.plus(quoteAmountRaw);
  if (volUsd !== null) {
    let usdValue: BigDecimal = volUsd;
    token.volumeAllTimeUsd = token.volumeAllTimeUsd.plus(usdValue);
  }
  token.save();

  let hourIndex = timestamp.div(HOUR_SECONDS);
  let bucketId = tokenId + "-" + hourIndex.toString();
  let bucket = TokenHourData.load(bucketId);
  if (bucket == null) {
    bucket = new TokenHourData(bucketId);
    bucket.token = tokenId;
    bucket.hourStartUnix = hourIndex.times(HOUR_SECONDS);
    bucket.volumeQuote = BigInt.zero();
    bucket.volumeUsd = BigDecimal.zero();
  }
  bucket.volumeQuote = bucket.volumeQuote.plus(quoteAmountRaw);
  if (volUsd !== null) {
    let usdValue: BigDecimal = volUsd;
    bucket.volumeUsd = bucket.volumeUsd.plus(usdValue);
  }
  if (price !== null) {
    let p: BigDecimal = price;
    bucket.closePrice = p;
  }
  if (priceUsd !== null) {
    let p: BigDecimal = priceUsd;
    bucket.closePriceUsd = p;
  }
  bucket.save();
}
