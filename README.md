# Conduit

Conduit is a unidirectional payment-channel protocol on Sepolia (chain id 11155111). It has two contracts:

| Contract | File | Purpose |
| --- | --- | --- |
| `ConduitToken` (CNDT) | `src/ConduitToken.sol` | Fixed-supply ERC-20 launch token |
| `PaymentChannel` | `src/PaymentChannel.sol` | CNDT payment channels settled with EIP-712 vouchers |

ABIs are exported to `docs/abi/ConduitToken.json` and `docs/abi/PaymentChannel.json`.

## Build and test (offline)

```sh
forge build
forge test
forge fmt --check
```

`forge-std` is vendored as plain files in `lib/forge-std` (v1.16.2), so nothing is fetched at build time.
`foundry.toml` pins solc 0.8.26 and EVM `cancun`, and sets `bytecode_hash = "none"`. It does not enable ffi or filesystem access.

## ConduitToken (CNDT)

- Name "Conduit", symbol "CNDT", 18 decimals.
- Its constructor takes no arguments. It mints exactly 1,000,000,000 CNDT (10^27 base units) to `msg.sender`, which is the ProjectFactory in a launch.
- There is no mint, burn, owner, admin, pause, proxy or upgrade path. `totalSupply` is immutable.
- Transfers to the zero address revert. An allowance of `type(uint256).max` never decreases.

## PaymentChannel

Its only constructor argument is `token` (address), given as `$token` in the manifest. The constructor is nonpayable and reverts if `token` has no code. The contract has no owner, admin, fee or upgradeability, and it makes no external calls except to the immutable token.

### Lifecycle

1. **open(payee, amount, expiresAt)**: the caller becomes the payer and deposits `amount` CNDT. The payer must first `approve` the contract.
   - It reverts if `payee` is zero, the payer, or the contract itself; if `amount == 0`; or if `expiresAt <= block.timestamp`.
   - The contract must receive exactly `amount` (checked by comparing its balance before and after), so fee-on-transfer tokens are rejected.
   - Channel ids run 1, 2, 3, … and are never reused. Emits `ChannelOpened`.
2. **close(channelId, amount, signature)**: callable only by the payee, at any time while the channel exists, including after `expiresAt`. The payee must hold the payer's EIP-712 signature over `Voucher(uint256 channelId, uint256 amount)`, where `amount` is **cumulative** and `amount <= deposit`. The payee receives `amount` and the payer gets `deposit - amount` back in the same transaction. The channel is then deleted. Emits `ChannelClosed`.
3. **reclaim(channelId)**: callable only by the payer once `block.timestamp >= expiresAt`. It returns the whole deposit and deletes the channel. Emits `ChannelReclaimed`.

After expiry, whichever of `close` and `reclaim` runs first settles the channel, and the other then reverts with `ChannelNotFound`. **The payee should close before `expiresAt`.** Until then the payer cannot reclaim.

### EIP-712 voucher

```
domain = { name: "PaymentChannel", version: "1", chainId: <chain id>, verifyingContract: <PaymentChannel address> }
types  = { Voucher: [ { name: "channelId", type: "uint256" }, { name: "amount", type: "uint256" } ] }
```

- `voucherDigest(channelId, amount)` and `DOMAIN_SEPARATOR()` expose the exact digest. The domain is recomputed on every call, so a chain fork cannot replay a voucher.
- A voucher only works for its own channel id, contract and chain. Because channels are deleted when settled and ids are never reused, a voucher cannot be replayed.
- Signatures must be exactly 65 bytes (`r || s || v`), with `v` equal to 27 or 28 and low-`s` (EIP-2). Malleated or unrecoverable signatures revert.
- Only EOA signatures (ecrecover) are accepted. Payers using contract wallets (ERC-1271) are **not** supported, because that would need calls to addresses other than the token.
- Each voucher is cumulative, so the payee only needs the latest (largest) one. The payer should sign increasing amounts and never sign more than the deposit.

### Safety properties

- Checks-effects-interactions: channel state is deleted and events are emitted before any token transfer. A `nonReentrant` guard also protects `open`, `close` and `reclaim`. Tests re-enter through a malicious token on every entry point.
- Token calls must succeed and return either nothing or `true`. Otherwise the call reverts with `TokenTransferFailed` and all state rolls back.
- Conservation: every settlement pays out exactly `deposit`, split between payee and payer. A fuzz test checks this.

### Assumptions and limitations

- Timing uses `block.timestamp`. A validator can skew it by a few seconds, which only matters within seconds of `expiresAt`. Choose timeouts with generous margins.
- A payee who goes offline past `expiresAt` risks the payer reclaiming everything, including amounts already covered by vouchers. This is the intended timeout rule.
- The contract holds deposits for many channels in one balance. The balance-delta check at `open` and the exact accounting at settlement assume a standard, non-rebasing token. CNDT meets this.
- There is no way to extend or top up a channel. To do either, open a new channel.
- Tests passing is not an audit. The workflow requires an independent adversarial review of these contracts and the manifest before deployment.

## Deployment parameters (for the manifest and service stages)

- Network: Sepolia, chain id 11155111. The services deploy through ProjectFactory; contributors never broadcast and never hold keys.
- Launch token: `ConduitToken`, no constructor arguments, 18 decimals, supply 10^27 minted to the factory.
- Application contracts, in dependency order:
  1. `PaymentChannel` with `constructorArgs: ["$token"]`.
- No constructor argument grants a privileged role. Neither contract has an owner, so `$owner` is not used.
- The pool (policy terms, not a valuation) pairs against native ETH (zero address) with fee 3000, tickSpacing 60 and sqrtPriceX96 `79228162514264337593543950336`.

## Operational responsibilities

- **Builders** (this stage): source, tests, ABI exports and this README.
- **Manifest node**: writes `launch.json` only.
- **Independent reviewers**: an adversarial review of source and manifest before deployment, and a final review after the website is built.
- **Services**: publish the source, attest, admit and deploy through the deployer, then host the frontend. The frontend loads `dist/imd-deployment.json` and its ABIs.
- After deployment there is nothing to administer. The contracts have no privileged functions.
