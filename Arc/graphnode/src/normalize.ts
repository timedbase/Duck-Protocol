import { BigDecimal, BigInt, ethereum } from "@graphprotocol/graph-ts";
import { Token, TokenHourData } from "../generated/schema";
import { ensureQuotePrice } from "./discovery";
import { quoteDecimals, quoteUsd } from "./pricing";

const HOUR = BigInt.fromI32(3600);

function toHuman(raw: BigInt, decimals: i32): BigDecimal {
  return raw.toBigDecimal().div(BigInt.fromI32(10).pow(decimals as u8).toBigDecimal());
}

// USD value of one trade; either field is null when the quote token has no reference price yet.
export class TradeValue {
  priceUSD: BigDecimal | null = null;
  volumeUSD: BigDecimal | null = null;
}

// One price/volume series for a token across both of its trading venues: the bonding curve, then
// its v4 pool. Saves the token.
export function recordTrade(token: Token, event: ethereum.Event, quoteRaw: BigInt, tokenRaw: BigInt): TradeValue {
  let value = new TradeValue();
  let timestamp = event.block.timestamp;
  token.lastTradeAt = timestamp;

  let quoteHuman = toHuman(quoteRaw, quoteDecimals(token.quoteToken));
  let hasPrice = !tokenRaw.isZero();
  let price = BigDecimal.zero();
  if (hasPrice) {
    price = quoteHuman.div(toHuman(tokenRaw, token.decimals));
    token.lastPrice = price;
  }
  token.volumeAllTime = token.volumeAllTime.plus(quoteRaw);

  let usd = quoteUsd(token.quoteToken);
  if (usd === null) {
    // No reference price yet: try discovering one (rate-limited), then look again.
    ensureQuotePrice(token.quoteToken, event);
    usd = quoteUsd(token.quoteToken);
  }
  let hasUsd = usd !== null;
  let quoteUsdPrice = BigDecimal.zero();
  let volumeUSD = BigDecimal.zero();
  let priceUSD = BigDecimal.zero();
  if (hasUsd) {
    quoteUsdPrice = usd as BigDecimal;
    volumeUSD = quoteHuman.times(quoteUsdPrice);
    value.volumeUSD = volumeUSD;
    token.volumeUSDAllTime = token.volumeUSDAllTime.plus(volumeUSD);
    if (hasPrice) {
      priceUSD = price.times(quoteUsdPrice);
      value.priceUSD = priceUSD;
      token.lastPriceUSD = priceUSD;
      if (token.totalSupply !== null) {
        let circulating = token.totalSupply!.minus(token.burnedSupply);
        token.marketCapUSD = priceUSD.times(toHuman(circulating, token.decimals));
      }
    }
  }
  token.save();

  let hourIndex = timestamp.div(HOUR);
  let id = token.id.toHexString() + "-" + hourIndex.toString();
  let bucket = TokenHourData.load(id);
  if (bucket == null) {
    bucket = new TokenHourData(id);
    bucket.token = token.id;
    bucket.hourStartUnix = hourIndex.times(HOUR);
    bucket.volumeQuote = BigInt.zero();
    bucket.volumeUSD = BigDecimal.zero();
  }
  bucket.volumeQuote = bucket.volumeQuote.plus(quoteRaw);
  if (hasPrice) bucket.closePrice = price;
  if (hasUsd) {
    bucket.volumeUSD = bucket.volumeUSD.plus(volumeUSD);
    if (hasPrice) bucket.closePriceUSD = priceUSD;
  }
  bucket.save();
  return value;
}
