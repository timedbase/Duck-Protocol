import { BigInt, BigDecimal } from "@graphprotocol/graph-ts";
import {
  TokenCreated,
  TokenBought,
  TokenSold,
  TokenMigrated,
  EmergencyMigrated,
  CurveFeeClaimed,
  DexConfigUpdated,
} from "../generated/DuckIncubation/DuckIncubation";
import { TokenMetadata } from "../generated/DuckIncubation/TokenMetadata";
import { Token, Trade, Migration, CurveFeeClaim } from "../generated/schema";
import { DuckToken, DuckHookV4Dynamic } from "../generated/templates";
import { recordTrade, quoteHexOf } from "./lib";

export function handleTokenCreated(event: TokenCreated): void {
  let token = new Token(event.params.token.toHexString());
  token.family = "CURVE";
  token.creator = event.params.creator;
  token.quoteToken = event.params.quoteToken;
  token.totalSupply = event.params.totalSupply;
  token.createdAt = event.block.timestamp;
  token.createdAtBlock = event.block.number;
  token.createdAtTx = event.transaction.hash;

  // The clone is fully initialized in the same transaction before this
  // event fires, so these calls always succeed in practice -- try_ variants
  // used defensively so a genuinely-unexpected revert can't fail indexing.
  let meta = TokenMetadata.bind(event.params.token);
  let nameResult = meta.try_name();
  let symbolResult = meta.try_symbol();
  let metaUriResult = meta.try_metaURI();
  token.name = nameResult.reverted ? null : nameResult.value;
  token.symbol = symbolResult.reverted ? null : symbolResult.value;
  token.metaUri = metaUriResult.reverted ? null : metaUriResult.value;

  token.virtualQuote = event.params.virtualQuote;
  token.migrationTarget = event.params.migrationTarget;
  token.antibotEnabled = event.params.antibotEnabled;
  token.tradingBlock = event.params.tradingBlock;
  token.migrated = false;
  token.bcTokensSold = BigInt.zero();
  token.raisedQuote = BigInt.zero();
  token.burnedSupply = BigInt.zero();
  token.holderCount = 0;
  token.volumeAllTime = BigInt.zero();
  token.volumeAllTimeUsd = BigDecimal.zero();

  token.save();

  DuckToken.create(event.params.token);
}

export function handleTokenBought(event: TokenBought): void {
  let token = Token.load(event.params.token.toHexString());
  if (token == null) return;
  token.bcTokensSold = token.bcTokensSold!.plus(event.params.tokensOut);
  token.raisedQuote = event.params.raisedQuote;
  token.save();

  let trade = new Trade(event.transaction.hash.toHexString() + "-" + event.logIndex.toString());
  trade.token = token.id;
  trade.trader = event.params.buyer;
  trade.side = "BUY";
  trade.quoteAmount = event.params.quoteIn;
  trade.tokenAmount = event.params.tokensOut;
  trade.tokensToDead = event.params.tokensToDead;
  trade.raisedQuoteAfter = event.params.raisedQuote;
  trade.timestamp = event.block.timestamp;
  trade.blockNumber = event.block.number;
  trade.txHash = event.transaction.hash;
  trade.save();

  let quoteHex = quoteHexOf(token);
  recordTrade(token.id, event.block.timestamp, trade.quoteAmount, trade.tokenAmount, quoteHex);
}

export function handleTokenSold(event: TokenSold): void {
  let token = Token.load(event.params.token.toHexString());
  if (token == null) return;
  token.bcTokensSold = token.bcTokensSold!.minus(event.params.tokensIn);
  token.raisedQuote = event.params.raisedQuote;
  token.save();

  let trade = new Trade(event.transaction.hash.toHexString() + "-" + event.logIndex.toString());
  trade.token = token.id;
  trade.trader = event.params.seller;
  trade.side = "SELL";
  trade.quoteAmount = event.params.quoteOut;
  trade.tokenAmount = event.params.tokensIn;
  trade.tokensToDead = null;
  trade.raisedQuoteAfter = event.params.raisedQuote;
  trade.timestamp = event.block.timestamp;
  trade.blockNumber = event.block.number;
  trade.txHash = event.transaction.hash;
  trade.save();

  let quoteHex = quoteHexOf(token);
  recordTrade(token.id, event.block.timestamp, trade.quoteAmount, trade.tokenAmount, quoteHex);
}

export function handleTokenMigrated(event: TokenMigrated): void {
  let token = Token.load(event.params.token.toHexString());
  if (token == null) return;
  token.migrated = true;
  token.raisedQuote = BigInt.zero();
  token.save();

  let migration = new Migration(token.id);
  migration.token = token.id;
  migration.poolId = event.params.poolId;
  migration.liquidityQuote = event.params.liquidityQuote;
  migration.liquidityTokens = event.params.liquidityTokens;
  migration.emergency = false;
  migration.timestamp = event.block.timestamp;
  migration.blockNumber = event.block.number;
  migration.txHash = event.transaction.hash;
  migration.save();
}

export function handleEmergencyMigrated(event: EmergencyMigrated): void {
  let token = Token.load(event.params.token.toHexString());
  if (token == null) return;
  token.migrated = true;
  token.raisedQuote = BigInt.zero();
  token.save();

  let migration = new Migration(token.id);
  migration.token = token.id;
  // No real V4 pool exists for an emergency migration -- that's precisely
  // why it was needed (initAndMintFullRange reverted PoolAlreadyExists).
  migration.poolId = null;
  migration.liquidityQuote = event.params.quoteAmount;
  migration.liquidityTokens = event.params.tokenAmount;
  migration.emergency = true;
  migration.timestamp = event.block.timestamp;
  migration.blockNumber = event.block.number;
  migration.txHash = event.transaction.hash;
  migration.save();
}

export function handleCurveFeeClaimed(event: CurveFeeClaimed): void {
  let token = Token.load(event.params.token.toHexString());
  if (token == null) return;

  let claim = new CurveFeeClaim(event.transaction.hash.toHexString() + "-" + event.logIndex.toString());
  claim.token = token.id;
  claim.creator = event.params.creator;
  claim.creatorAmount = event.params.creatorAmount;
  claim.platformAmount = event.params.platformAmount;
  claim.timestamp = event.block.timestamp;
  claim.blockNumber = event.block.number;
  claim.txHash = event.transaction.hash;
  claim.save();
}

// Fires whenever the owner points this positionManager at a different hook
// (see subgraph.yaml's DuckHookV4Dynamic template comment) -- starts
// indexing Pool/HookFeeClaim/CTOApplication for it from here on, instead of
// silently orphaning every migrated-curve token that ends up on the new hook.
export function handleDexConfigUpdated(event: DexConfigUpdated): void {
  DuckHookV4Dynamic.create(event.params.hook);
}
