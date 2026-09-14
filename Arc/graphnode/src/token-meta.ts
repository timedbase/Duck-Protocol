import { Address, BigDecimal, BigInt, ethereum } from "@graphprotocol/graph-ts";
import { Token } from "../generated/schema";
import { DuckToken } from "../generated/DuckBondingCurve/DuckToken";
import { ensureQuotePrice } from "./discovery";

// Builds a Token from what the token contract reports about itself. Every read is a try_ call, so a
// token that is not initialised yet leaves the field null rather than failing the block.
export function newToken(address: Address, family: string, creator: Address, quoteToken: Address, event: ethereum.Event): Token {
  let t = new Token(address);
  t.family = family;
  t.creator = creator;
  t.quoteToken = quoteToken;

  let c = DuckToken.bind(address);
  let name = c.try_name();
  if (!name.reverted) t.name = name.value;
  let symbol = c.try_symbol();
  if (!symbol.reverted) t.symbol = symbol.value;
  let supply = c.try_totalSupply();
  if (!supply.reverted) t.totalSupply = supply.value;
  let decimals = c.try_decimals();
  t.decimals = decimals.reverted ? 18 : decimals.value;
  let meta = c.try_metaURI();
  if (!meta.reverted) t.metaUri = meta.value;

  t.burnedSupply = BigInt.zero();
  t.hasPool = false;
  t.migrated = false;
  t.volumeAllTime = BigInt.zero();
  t.volumeUSDAllTime = BigDecimal.zero();
  t.holderCount = 0;
  t.createdAtBlock = event.block.number;
  t.createdAtTimestamp = event.block.timestamp;
  t.createdAtTx = event.transaction.hash;
  ensureQuotePrice(quoteToken, event);
  return t;
}
