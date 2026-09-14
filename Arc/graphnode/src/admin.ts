import { Bytes, ethereum } from "@graphprotocol/graph-ts";
import { AdminEvent } from "../generated/schema";

export function eventId(event: ethereum.Event): Bytes {
  return event.transaction.hash.concatI32(event.logIndex.toI32());
}

export function logAdminEvent(
  event: ethereum.Event,
  contractName: string,
  eventName: string,
  param0: string | null = null,
  param1: string | null = null,
  param2: string | null = null,
  param3: string | null = null
): void {
  let e = new AdminEvent(eventId(event));
  e.contractAddress = event.address;
  e.contractName = contractName;
  e.eventName = eventName;
  e.param0 = param0;
  e.param1 = param1;
  e.param2 = param2;
  e.param3 = param3;
  e.blockNumber = event.block.number;
  e.timestamp = event.block.timestamp;
  e.txHash = event.transaction.hash;
  e.save();
}

export function boolToString(b: boolean): string {
  return b ? "true" : "false";
}
