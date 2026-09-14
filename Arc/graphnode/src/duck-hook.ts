import { BigInt, Bytes } from "@graphprotocol/graph-ts";
import {
  PoolRegistered as PoolRegisteredStatic,
  FeesClaimed as FeesClaimedStatic,
  CTOApplied as CTOAppliedStatic,
  CTOApproved as CTOApprovedStatic,
  CTORejected as CTORejectedStatic,
} from "../generated/DuckHookV4/DuckHookV4";
// The original, constructor-set hook (see subgraph.yaml's static DuckHookV4
// dataSource) and any hook rotated in later via addDex/setDexConfig (see
// the DuckHookV4Dynamic template, started from duck-launcher.ts/
// duck-incubation.ts/duck-raise.ts's DexAdded/DexConfigUpdated/
// DexConfigSet handlers) are the same ABI, but codegen gives a static
// dataSource and a template distinct, non-interchangeable event classes --
// hence the Static/Dynamic import split and thin per-source wrappers below,
// both delegating to the same entity-mutation logic.
import {
  PoolRegistered as PoolRegisteredDynamic,
  FeesClaimed as FeesClaimedDynamic,
  CTOApplied as CTOAppliedDynamic,
  CTOApproved as CTOApprovedDynamic,
  CTORejected as CTORejectedDynamic,
} from "../generated/templates/DuckHookV4Dynamic/DuckHookV4";
import { Pool, HookFeeClaim, CTOApplication } from "../generated/schema";

function registerPool(poolId: Bytes, token: Bytes, creator: Bytes, hookFeeBps: BigInt, timestamp: BigInt, blockNumber: BigInt): void {
  let pool = new Pool(poolId.toHexString());
  pool.token = token.toHexString();
  pool.creator = creator;
  pool.hookFeeBps = hookFeeBps;
  pool.registeredAt = timestamp;
  pool.registeredAtBlock = blockNumber;
  pool.swapCount = BigInt.zero();
  pool.save();
}

export function handlePoolRegistered(event: PoolRegisteredStatic): void {
  registerPool(event.params.poolId, event.params.token, event.params.creator, event.params.hookFeeBps, event.block.timestamp, event.block.number);
}
export function handlePoolRegisteredDynamic(event: PoolRegisteredDynamic): void {
  registerPool(event.params.poolId, event.params.token, event.params.creator, event.params.hookFeeBps, event.block.timestamp, event.block.number);
}

function claimFees(poolId: Bytes, amount: BigInt, timestamp: BigInt, blockNumber: BigInt, txHash: Bytes, logIndex: BigInt): void {
  let pool = Pool.load(poolId.toHexString());
  if (pool == null) return;

  let claim = new HookFeeClaim(txHash.toHexString() + "-" + logIndex.toString());
  claim.pool = pool.id;
  claim.amount = amount;
  claim.timestamp = timestamp;
  claim.blockNumber = blockNumber;
  claim.txHash = txHash;
  claim.save();
}

export function handleFeesClaimed(event: FeesClaimedStatic): void {
  claimFees(event.params.poolId, event.params.amount, event.block.timestamp, event.block.number, event.transaction.hash, event.logIndex);
}
export function handleFeesClaimedDynamic(event: FeesClaimedDynamic): void {
  claimFees(event.params.poolId, event.params.amount, event.block.timestamp, event.block.number, event.transaction.hash, event.logIndex);
}

function applyForCTO(
  poolId: Bytes, applicant: Bytes, newCreator: Bytes, paid: BigInt,
  timestamp: BigInt, blockNumber: BigInt, txHash: Bytes, logIndex: BigInt
): void {
  let pool = Pool.load(poolId.toHexString());
  if (pool == null) return;

  let id = poolId.toHexString() + "-" + txHash.toHexString() + "-" + logIndex.toString();
  let application = new CTOApplication(id);
  application.pool = pool.id;
  application.applicant = applicant;
  application.newCreator = newCreator;
  application.paid = paid;
  application.status = "PENDING";
  application.appliedAt = timestamp;
  application.appliedAtBlock = blockNumber;
  application.appliedAtTx = txHash;
  application.save();

  pool.pendingCTO = id;
  pool.save();
}

export function handleCTOApplied(event: CTOAppliedStatic): void {
  applyForCTO(event.params.poolId, event.params.applicant, event.params.newCreator, event.params.paid, event.block.timestamp, event.block.number, event.transaction.hash, event.logIndex);
}
export function handleCTOAppliedDynamic(event: CTOAppliedDynamic): void {
  applyForCTO(event.params.poolId, event.params.applicant, event.params.newCreator, event.params.paid, event.block.timestamp, event.block.number, event.transaction.hash, event.logIndex);
}

function approveCTO(poolId: Bytes, newCreator: Bytes, timestamp: BigInt, blockNumber: BigInt): void {
  let pool = Pool.load(poolId.toHexString());
  if (pool == null || pool.pendingCTO == null) return;

  let application = CTOApplication.load(pool.pendingCTO!);
  if (application == null) return;
  application.status = "APPROVED";
  application.resolvedAt = timestamp;
  application.resolvedAtBlock = blockNumber;
  application.save();

  pool.creator = newCreator;
  pool.pendingCTO = null;
  pool.save();
}

export function handleCTOApproved(event: CTOApprovedStatic): void {
  approveCTO(event.params.poolId, event.params.newCreator, event.block.timestamp, event.block.number);
}
export function handleCTOApprovedDynamic(event: CTOApprovedDynamic): void {
  approveCTO(event.params.poolId, event.params.newCreator, event.block.timestamp, event.block.number);
}

function rejectCTO(poolId: Bytes, timestamp: BigInt, blockNumber: BigInt): void {
  let pool = Pool.load(poolId.toHexString());
  if (pool == null || pool.pendingCTO == null) return;

  let application = CTOApplication.load(pool.pendingCTO!);
  if (application == null) return;
  application.status = "REJECTED";
  application.resolvedAt = timestamp;
  application.resolvedAtBlock = blockNumber;
  application.save();

  pool.pendingCTO = null;
  pool.save();
}

export function handleCTORejected(event: CTORejectedStatic): void {
  rejectCTO(event.params.poolId, event.block.timestamp, event.block.number);
}
export function handleCTORejectedDynamic(event: CTORejectedDynamic): void {
  rejectCTO(event.params.poolId, event.block.timestamp, event.block.number);
}
