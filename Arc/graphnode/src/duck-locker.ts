import { Address, BigInt } from "@graphprotocol/graph-ts";
import {
  PositionRegistered,
  FeesClaimed,
  FeesClaimedV3,
  V3CTOApplied,
  V3CTOApproved,
  V3CTORejected,
} from "../generated/DuckLocker/DuckLocker";
import { Position, LPFeeClaim, V3CTOApplication, Token } from "../generated/schema";

// registerPosition (V4) and registerPositionV3 emit the exact same
// PositionRegistered event -- V3 always passes poolId/hook as zero (V3 has
// neither), so a zero hook unambiguously means this was a V3 registration.
// The event carries no creator field for V3 (unlike V4, which looks it up
// from the hook's Pool later) -- Token.creator (set by TokenLaunched, which
// always fires earlier in the same launch flow) is the original creator and
// exactly right as the starting value; handleV3CTOApproved below is what
// moves it away from that after a successful CTO.
export function handlePositionRegistered(event: PositionRegistered): void {
  let position = new Position(event.params.token.toHexString());
  position.token = event.params.token.toHexString();
  position.tokenId = event.params.tokenId;
  position.poolId = event.params.poolId;
  position.hook = event.params.hook;
  position.positionManager = event.params.positionManager;
  position.isV3 = event.params.hook.equals(Address.zero());
  if (position.isV3) {
    let token = Token.load(event.params.token.toHexString());
    position.creator = token != null ? token.creator : null;
  }
  position.registeredAt = event.block.timestamp;
  position.registeredAtBlock = event.block.number;
  position.registeredAtTx = event.transaction.hash;
  position.totalBurned = BigInt.zero();
  position.totalToPlatform = BigInt.zero();
  position.totalToCreator = BigInt.zero();
  position.save();
}

export function handleFeesClaimed(event: FeesClaimed): void {
  let position = Position.load(event.params.token.toHexString());
  if (position == null) return;
  position.totalBurned = position.totalBurned.plus(event.params.burned);
  position.totalToPlatform = position.totalToPlatform.plus(event.params.toPlatform);
  position.save();

  let claim = new LPFeeClaim(event.transaction.hash.toHexString() + "-" + event.logIndex.toString());
  claim.position = position.id;
  claim.burned = event.params.burned;
  claim.toPlatform = event.params.toPlatform;
  claim.timestamp = event.block.timestamp;
  claim.blockNumber = event.block.number;
  claim.txHash = event.transaction.hash;
  claim.save();
}

// V3 positions have no hook, so their creator cut is paid out synchronously
// right here (unlike V4, where the hook's own HookFeeClaim covers the
// creator side) -- see DuckLockerArc._collectAndDistributeV3.
export function handleFeesClaimedV3(event: FeesClaimedV3): void {
  let position = Position.load(event.params.token.toHexString());
  if (position == null) return;
  position.totalBurned = position.totalBurned.plus(event.params.burned);
  position.totalToPlatform = position.totalToPlatform.plus(event.params.toPlatform);
  position.totalToCreator = position.totalToCreator.plus(event.params.toCreator);
  position.save();

  let claim = new LPFeeClaim(event.transaction.hash.toHexString() + "-" + event.logIndex.toString());
  claim.position = position.id;
  claim.burned = event.params.burned;
  claim.toPlatform = event.params.toPlatform;
  claim.toCreator = event.params.toCreator;
  claim.timestamp = event.block.timestamp;
  claim.blockNumber = event.block.number;
  claim.txHash = event.transaction.hash;
  claim.save();
}

// Mirrors duck-hook.ts's applyForCTO/approveCTO/rejectCTO exactly, keyed by
// Position instead of Pool since a V3 position has no hook to host this on.
export function handleV3CTOApplied(event: V3CTOApplied): void {
  let position = Position.load(event.params.token.toHexString());
  if (position == null) return;

  let id = event.params.token.toHexString() + "-" + event.transaction.hash.toHexString() + "-" + event.logIndex.toString();
  let application = new V3CTOApplication(id);
  application.position = position.id;
  application.applicant = event.params.applicant;
  application.newCreator = event.params.newCreator;
  application.paid = event.params.paid;
  application.status = "PENDING";
  application.appliedAt = event.block.timestamp;
  application.appliedAtBlock = event.block.number;
  application.appliedAtTx = event.transaction.hash;
  application.save();

  position.pendingCTO = id;
  position.save();
}

export function handleV3CTOApproved(event: V3CTOApproved): void {
  let position = Position.load(event.params.token.toHexString());
  if (position == null || position.pendingCTO == null) return;

  let application = V3CTOApplication.load(position.pendingCTO!);
  if (application == null) return;
  application.status = "APPROVED";
  application.resolvedAt = event.block.timestamp;
  application.resolvedAtBlock = event.block.number;
  application.save();

  position.creator = event.params.newCreator;
  position.pendingCTO = null;
  position.save();
}

export function handleV3CTORejected(event: V3CTORejected): void {
  let position = Position.load(event.params.token.toHexString());
  if (position == null || position.pendingCTO == null) return;

  let application = V3CTOApplication.load(position.pendingCTO!);
  if (application == null) return;
  application.status = "REJECTED";
  application.resolvedAt = event.block.timestamp;
  application.resolvedAtBlock = event.block.number;
  application.save();

  position.pendingCTO = null;
  position.save();
}
