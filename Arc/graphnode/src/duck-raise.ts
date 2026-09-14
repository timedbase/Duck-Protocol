import { BigInt, BigDecimal } from "@graphprotocol/graph-ts";
import {
  CampaignCreated,
  Contributed,
  CampaignSucceeded,
  CampaignFailed,
  Claimed,
  Refunded,
  DexConfigSet,
} from "../generated/DuckRaise/DuckRaise";
import { TokenMetadata } from "../generated/DuckRaise/TokenMetadata";
import { Token, Campaign, Contribution } from "../generated/schema";
import { DuckToken, DuckHookV4Dynamic } from "../generated/templates";

// DuckRaise.TOTAL_SUPPLY -- fixed for every campaign, not carried in
// CampaignCreated itself.
const TOTAL_SUPPLY = BigInt.fromString("1000000000000000000000000000");

export function handleCampaignCreated(event: CampaignCreated): void {
  let campaignId = event.params.campaignId.toString();

  let token = new Token(event.params.token.toHexString());
  token.family = "CAMPAIGN";
  token.creator = event.params.creator;
  token.quoteToken = event.params.dexQuoteAsset;
  token.totalSupply = TOTAL_SUPPLY;
  token.createdAt = event.block.timestamp;
  token.createdAtBlock = event.block.number;
  token.createdAtTx = event.transaction.hash;
  token.campaign = campaignId;

  // name/symbol are already in the event itself (chosen before the token
  // exists) -- mirrored onto Token too so every family exposes them the
  // same way. The token contract does exist by this point (DuckRaise
  // deploys it immediately at launch(), not at finalize()), so metaURI is
  // readable now same as the other two families.
  token.name = event.params.name;
  token.symbol = event.params.symbol;
  let metaUriResult = TokenMetadata.bind(event.params.token).try_metaURI();
  token.metaUri = metaUriResult.reverted ? null : metaUriResult.value;
  token.burnedSupply = BigInt.zero();
  token.holderCount = 0;
  token.volumeAllTime = BigInt.zero();
  token.volumeAllTimeUsd = BigDecimal.zero();

  token.save();

  DuckToken.create(event.params.token);

  let campaign = new Campaign(campaignId);
  campaign.token = token.id;
  campaign.creator = event.params.creator;
  campaign.name = event.params.name;
  campaign.symbol = event.params.symbol;
  campaign.dexQuoteAsset = event.params.dexQuoteAsset;
  campaign.goal = event.params.goal;
  campaign.startTime = event.params.startTime;
  campaign.deadline = event.params.deadline;
  campaign.totalRaised = BigInt.zero();
  campaign.succeeded = false;
  campaign.failed = false;
  campaign.createdAt = event.block.timestamp;
  campaign.createdAtBlock = event.block.number;
  campaign.createdAtTx = event.transaction.hash;
  campaign.save();
}

export function handleContributed(event: Contributed): void {
  let campaignId = event.params.campaignId.toString();
  let campaign = Campaign.load(campaignId);
  if (campaign == null) return;
  campaign.totalRaised = campaign.totalRaised.plus(event.params.amount);
  campaign.save();

  let id = campaignId + "-" + event.params.contributor.toHexString();
  let contribution = Contribution.load(id);
  if (contribution == null) {
    contribution = new Contribution(id);
    contribution.campaign = campaignId;
    contribution.contributor = event.params.contributor;
    contribution.amount = BigInt.zero();
    contribution.claimed = false;
    contribution.claimedAmount = BigInt.zero();
    contribution.refunded = false;
    contribution.refundedAmount = BigInt.zero();
    contribution.firstContributedAt = event.block.timestamp;
  }
  contribution.amount = contribution.amount.plus(event.params.amount);
  contribution.lastContributedAt = event.block.timestamp;
  contribution.save();
}

export function handleCampaignSucceeded(event: CampaignSucceeded): void {
  let campaign = Campaign.load(event.params.campaignId.toString());
  if (campaign == null) return;
  campaign.succeeded = true;
  campaign.totalRaised = event.params.totalRaised;
  campaign.resolvedAt = event.block.timestamp;
  campaign.resolvedAtBlock = event.block.number;
  campaign.save();
}

export function handleCampaignFailed(event: CampaignFailed): void {
  let campaign = Campaign.load(event.params.campaignId.toString());
  if (campaign == null) return;
  campaign.failed = true;
  campaign.totalRaised = event.params.totalRaised;
  campaign.resolvedAt = event.block.timestamp;
  campaign.resolvedAtBlock = event.block.number;
  campaign.save();
}

export function handleClaimed(event: Claimed): void {
  let id = event.params.campaignId.toString() + "-" + event.params.contributor.toHexString();
  let contribution = Contribution.load(id);
  if (contribution == null) return;
  contribution.claimed = true;
  contribution.claimedAmount = contribution.claimedAmount.plus(event.params.amount);
  contribution.save();
}

export function handleRefunded(event: Refunded): void {
  let id = event.params.campaignId.toString() + "-" + event.params.contributor.toHexString();
  let contribution = Contribution.load(id);
  if (contribution == null) return;
  contribution.refunded = true;
  contribution.refundedAmount = contribution.refundedAmount.plus(event.params.amount);
  contribution.save();
}

// Fires whenever the owner points this positionManager at a different hook
// (see subgraph.yaml's DuckHookV4Dynamic template comment) -- starts
// indexing Pool/HookFeeClaim/CTOApplication for it from here on, instead of
// silently orphaning every successful campaign's pool that ends up on the
// new hook.
export function handleDexConfigSet(event: DexConfigSet): void {
  DuckHookV4Dynamic.create(event.params.hook);
}
