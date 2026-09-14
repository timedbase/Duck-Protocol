import { Address, BigInt } from "@graphprotocol/graph-ts";
import { Transfer } from "../generated/templates/DuckToken/ERC20";
import { Holder, Token } from "../generated/schema";

const ZERO_ADDRESS = Address.zero();
const DEAD_ADDRESS = Address.fromString("0x000000000000000000000000000000000000dEaD");

function loadOrCreateHolder(token: Address, account: Address): Holder {
  let id = token.toHexString() + "-" + account.toHexString();
  let holder = Holder.load(id);
  if (holder == null) {
    holder = new Holder(id);
    holder.token = token.toHexString();
    holder.account = account;
    holder.balance = BigInt.zero();
  }
  return holder as Holder;
}

export function handleTransfer(event: Transfer): void {
  let token = event.address;
  let tokenId = token.toHexString();

  if (event.params.from.notEqual(ZERO_ADDRESS)) {
    let from = loadOrCreateHolder(token, event.params.from);
    let wasHolder = from.balance.gt(BigInt.zero());
    from.balance = from.balance.minus(event.params.value);
    from.updatedAt = event.block.timestamp;
    from.updatedAtBlock = event.block.number;
    from.save();

    if (wasHolder && from.balance.equals(BigInt.zero()) && event.params.from.notEqual(DEAD_ADDRESS)) {
      let tokenEntity = Token.load(tokenId);
      if (tokenEntity != null) {
        tokenEntity.holderCount = tokenEntity.holderCount - 1;
        tokenEntity.save();
      }
    }
  }

  if (event.params.to.notEqual(ZERO_ADDRESS)) {
    let to = loadOrCreateHolder(token, event.params.to);
    let wasHolder = to.balance.gt(BigInt.zero());
    to.balance = to.balance.plus(event.params.value);
    to.updatedAt = event.block.timestamp;
    to.updatedAtBlock = event.block.number;
    to.save();

    // The dead/burn address itself is never counted as a real holder.
    if (!wasHolder && to.balance.gt(BigInt.zero()) && event.params.to.notEqual(DEAD_ADDRESS)) {
      let tokenEntity = Token.load(tokenId);
      if (tokenEntity != null) {
        tokenEntity.holderCount = tokenEntity.holderCount + 1;
        tokenEntity.save();
      }
    }
  }

  if (event.params.to.equals(DEAD_ADDRESS)) {
    let tokenEntity = Token.load(tokenId);
    if (tokenEntity != null) {
      tokenEntity.burnedSupply = tokenEntity.burnedSupply.plus(event.params.value);
      tokenEntity.save();
    }
  }
}
