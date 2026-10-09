# Kiln — Sepolia rehearsal

Kiln is an immutable Uniswap v4 ETH/ZTO hook and Pepeolithic market. Launcher opens one pool and deploys its Kiln with CREATE2. Neither application has an owner, administrator, pause, upgrade, withdrawal, rescue, arbitrary-call or approval function. ZTO reserve leaves Kiln only as payment to a caller who sells it a Pepeolithic piece.

This is the Sepolia rehearsal, chain ID **11155111**. The same application code is intended for mainnet with different dependency addresses. This repository prepares deployment; no transactions have been broadcast and it contains no wallet keys.

| Constructor parameter, in order | Sepolia value supplied in the brief |
| --- | --- |
| `zto` | `0xfFf9976782d46CC05630D1f6eBAb18b2324d6B14` |
| `pepeo` | `0x0ce3157eac34eccdcff239738983976fabdefb2a` |
| `poolManager` | `0xE03A1074c86CFeDd5C142C4F04F1a1536e203543` |

ZTO here is Sepolia WETH used as a plain ERC-20; Kiln never wraps or unwraps it. Its decimals are the constant 18. Pepeolithic is the supplied ERC-721 collection with a maximum of 737 pieces (ids `0..736`). **Rehearsal scope:** the Sepolia contract above (name `Ochre`, `MAX_SUPPLY` 737) had only 7 pieces minted on 2026-10-09, held by different wallets, so no Sepolia wallet can currently reach the 4-piece or 21-piece tiers against the live contract; those tiers are exercised only by the local tests with the mock collection. That contract is also a sale contract with its own admin role for minting and metadata (not transfers); the "no admin" statement in this README covers Launcher and Kiln only. Constructors accept exactly those three addresses, make no external calls, and work with no dependency code present. Addresses are immutable; they are constructor arguments so local tests can substitute mocks. They are not validated against live Sepolia in this project. The deployment operator must verify the supplied dependencies before sending transactions.

## Pool and pass

Native ETH (`address(0)`) is currency0 and ZTO is currency1. The pool has static `lpFee = 2000` (0.20%) and `tickSpacing = 60`. LPs receive the normal pool fee. Kiln additionally takes a ZTO cut according to the trader's Pepeolithic balance:

| Minimum pieces | `kilnCut` (hundredths of a basis point) | Cut |
| ---: | ---: | ---: |
| 0 | 13000 | 1.30% |
| 1 | 8000 | 0.80% |
| 4 | 3000 | 0.30% |
| 21 | 0 | 0% |

`tierOf(wallet)` returns the applicable `uint24 kilnCut`. The highest qualifying tier wins. Tier 21 still pays the 0.20% LP fee.

**Pass caveat: the trader is `tx.origin`, not the router or smart wallet.** A pass only needs to be in that wallet during the swap: there is no minimum holding time or block-held guard. Borrowing or moving pieces within the same transaction can qualify. That includes Kiln's own inventory: whenever it holds at least 21 pieces, a wallet can `buy` them, swap cut-free and `sell` them back in one transaction, paying the spread plus the geometric bid drift (about 5.5% of the reserve for 21 pieces) instead of the cut. That rent lands in the reserve and does not depend on the swap size, so very large swaps (roughly more than four times the reserve) are cheaper rented; this is an accepted consequence of the no-hold rule. Account-abstraction/bundler routes therefore assess the transaction origin's holdings rather than necessarily the end user's smart account. This use of `tx.origin` determines a discount only; it grants no custody or administrative authority.

Let `D = 1,000,000` and `r = kilnCut`. The fee basis is gross ZTO: total ZTO paid when ZTO is input, or total ZTO output by the pool before the cut when ETH is input. All divisions round down. For exact-output requests, gross-up preserves the requested output and makes the cut agree with `grossZTO * r / D` within one ZTO wei.

| Swap | Cut calculation | Hook delta |
| --- | --- | --- |
| ZTO input, exact input `A` | `floor(A * r / D)`; pool receives `A - cut` | positive specified delta in `beforeSwap` |
| ETH input, exact output `N` ZTO | `floor(N * r / (D-r))`; pool outputs `N + cut` | positive specified delta in `beforeSwap` |
| ETH input, exact input | `floor(poolZTOOutput * r / D)` | positive unspecified delta in `afterSwap` |
| ZTO input, exact output | `floor(poolZTOInput * r / (D-r))` | positive unspecified delta in `afterSwap` |

Every successful swap emits `Passed(trader, pepes, kilnCut, ztoTaken)`, including zero-cut swaps. A positive hook delta deducts ZTO from the router's balance delta. Kiln settles its corresponding credit with `poolManager.mint` of ERC-6909 claims to itself, and increments `claims`. It never calls `take` during a swap; this also works when the manager initially has no real ZTO and the router settles afterward.

If a price limit or lack of liquidity partially fills a swap with a **nonzero specified cut**, Kiln reverts with `PartialSpecifiedSwap`. `afterSwap` can adjust only the unspecified currency, so it cannot refund that earlier specified cut. This avoids retaining a fee on unfilled volume. For unspecified cuts, fees use only realized pool ZTO. Zero-cut swaps retain normal v4 partial-fill behavior. Routers must enforce user limits and exact-output fulfillment as usual.

The hook checks its complete pool key on both callbacks, and only its immutable PoolManager can call them. Other pools may reference its address but cannot swap through it with a different key. There are no liquidity callbacks or restrictions on adding/removing liquidity.

## Claims, reserve and pieces

`claims()` is the accumulated swap cut still held as ERC-6909 claims. `reserve()` is real ZTO accounted for pieces. Uncollected claims do not increase quotes:

- `bid() = reserve / 50` (`depth = 50`).
- `ask() = floor(bid() * 11500 / 10000)` (`spreadBps = 1500`, a 15% spread).
- `inventory()` returns the unsorted array of sale-acquired IDs; `inInventory(id)` tests membership. Removing an ID uses swap-and-pop, so array order is not stable.

Anyone can call `collect()`. It unlocks the PoolManager, burns Kiln's entire ZTO claim balance and takes the corresponding real ZTO, clears `claims`, increases `reserve`, and emits `Collected(amount)`. Claim tokens donated directly to Kiln are also collected. Their amount is not included in the swap-only `claims` counter before collection. Collecting zero is a harmless no-op that emits `Collected(0)`. Collection with outstanding claims must happen outside an already unlocked manager; nested unlocks revert atomically.

`sell(id)` first collects, requires a positive bid, quotes the resulting bid, records the ID in inventory and reduces reserve. It then pulls the caller's piece using `transferFrom` and pays the quoted ZTO, checking the token's boolean result. Approve Kiln for that ID (or as NFT operator) beforehand. It emits `Sold(id, seller, price)`. Each purchase of a piece consumes only 1/50 of the current reserve, making bids payable and decreasing them geometrically until integer rounding reaches zero.

`buy(id)` first collects, requires the ID to be in inventory, quotes the resulting ask and reverts with `ZeroBid` if it is zero (mirroring `sell`: both quotes are zero exactly when the reserve is below 50 wei, and only a `seed` can reopen the market). It then removes the ID, increases reserve, pulls that ZTO from the buyer, requiring a true result, and transfers the piece to the buyer with `transferFrom`. It emits `Bought(id, buyer, price)`.

**Price caveat: both functions take only an id.** There is no caller-supplied minimum, maximum or deadline, and the price is whatever quote holds when the transaction executes. Every `sell` lowers the bid by 2% of the reserve, every `buy` and `seed` raises it, and `buy` collects pending claims first, so the executed ask is at least the `ask()` quoted while claims were pending. The buyer's protection is the allowance: approve Kiln for exactly the quoted ask (not an unlimited amount) and the purchase reverts if the price has moved up. A seller whose transaction lands after another sale simply receives the lower bid; use an atomic wrapper with postconditions if that is unacceptable.

`seed(amount)` lets anyone transfer ZTO into reserve and emits `Seeded(from, amount)`. Seeds have no shares, rights or refund. **Seeding caveat:** because the quotes are pure functions of the reserve, a visible seed (or a large pending cut about to be collected) can be sandwiched whenever inventory is non-empty: buy a piece at the pre-seed ask, let the seed land, sell it back at the post-seed bid. The capture is roughly 2% of the inflow and is positive once the inflow exceeds about 12.7% of the current reserve; it is paid out of the seed and the spread stays in the reserve. Seed in tranches below that fraction, seed while inventory is empty, or submit through a private relay. All token transfers happen after effects, and any failure reverts the entire operation. There is no ReentrancyGuard: this application is specifically for the supplied ordinary ERC-20 and ERC-721 using `transferFrom`, with no receiver callbacks. Callback-bearing, fee-on-transfer or rebasing token substitutions are unsupported. The accounting guarantee is `reserve <= ZTO.balanceOf(Kiln)` at completed transaction boundaries.

**Transfer caveat: pieces sent directly with plain `transferFrom` without `sell()` are not inventory and are permanently stuck.** There is no rescue function. Kiln also has no ERC-721 safe-transfer receiver. Direct ERC-20 transfers do not increase reserve and cannot be swept; use `seed`. There is no application path for receiving, wrapping or withdrawing native ETH.

## Deployment handoff

1. Deploy **Launcher only**, with the three addresses above in that order. Both applications are nonpayable at construction. The application's deployment manifest should contain Launcher; Kiln is created later by `open`, not independently as another initial application.
2. Read `Launcher.initCodeHash()` from the actual deployed Launcher. Mine a salt against that **Launcher address**. Kiln's constructor deliberately does not validate its address bits. Launcher validates them immediately after CREATE2 and rolls back the whole call if they are wrong.
3. The exact address condition is `(uint160(kiln) & 0x3fff) == 0x00cc`: beforeSwap, afterSwap, beforeSwapReturnDelta, afterSwapReturnDelta, and no other permissions. The CREATE2 preimage is `0xff || launcher || salt || initCodeHash`.
4. Choose and independently check the opening price: `sqrtPriceX96 = floor(sqrt(ZTO raw units / ETH wei) * 2^96)`. Both currencies have 18 decimals. No opening price is assumed by deployment code. Anyone can call `open(salt, sqrtPriceX96)` exactly once, including before the intended operator. Opening is permissionless: the operator must verify the actual `Opened(kiln, poolId)` event, pool price, bytecode, constructor values and hook address before funding liquidity. An invalid price or address rolls back creation and leaves `open` available to retry.
   **Pre-initialized pool.** The predicted Kiln address carries no initialize bits, and v4 does not require code at a hook address, so anyone who knows the salt (it is visible in a pending `open` transaction, and the miner below is deterministic) can initialize the same pool key first, at any price, before the Kiln exists. `open` therefore reads the pool's `slot0` and only calls `initialize` when the price is still zero; otherwise it adopts the existing pool and emits `Opened` as usual, so no salt can be burned. The supplied `sqrtPriceX96` is then ignored, so **always read the pool price after `open` and before step 5.** The adopted pool is empty unless the stranger also added liquidity, and an empty pool's price moves to the swap's `sqrtPriceLimitX96` with zero deltas. Recovery paths that work from any wallet, including one with no pieces: to raise the price, swap `zeroForOne = false` with a positive (exact-output) `amountSpecified` and the target price as limit; to lower it, swap `zeroForOne = true` with a negative (exact-input) amount and the target limit. The other two modes (ZTO exact-input, ETH exact-output) mint a specified cut in `beforeSwap` and revert with `PartialSpecifiedSwap` on a zero fill unless the wallet holds 21 pieces. If liquidity was added by the stranger, the pool behaves like any pool somebody else seeded at a price: move it with capital or add liquidity around the intended price. Submitting `open` through a private relay avoids the race entirely.
5. Add liquidity through the normal v4 PositionManager with explicit position amounts, tick bounds and slippage checks. Launcher adds none. Use the dependency's established deployment handoff for the PositionManager; this repository does not guess another address.
6. Seed the reserve if an immediate nonzero bid is desired, or let swaps accrue claims and call `collect`. Seed before any piece is in inventory, or in tranches (see the seeding caveat above). Anyone can collect; no keeper privilege or reward is needed. Frontends/indexers can follow the emitted events. No reserve withdrawal, privileged configuration or later owner action exists.

**Range-direction correction:** with this required currency ordering and v4's price `currency1/currency0`, a **ZTO-only** range is **below** the opening tick (upper tick at or below the current tick), not above it. A range above the opening tick is ETH-only. The tests prove both using the real PoolManager and liquidity router. For example, at test tick 0, ticks `[-1200, -60]` require only ZTO, whereas `[60, 1200]` require only ETH. These are test values, not deployment recommendations. A below-price ZTO range needs an ETH-in swap to enter the range before it has ETH to pay out in the reverse direction.

An offline Solidity salt miner is included. Supply the actual values returned by the deployed launcher:

```sh
forge script script/MineSalt.s.sol:MineSalt \
  --sig 'find(address,bytes32,uint256,uint256)' \
  <launcher-address> <init-code-hash> 0 200000
```

It returns the salt and predicted address without RPC, environment variables, filesystem cheatcodes, FFI, keys or broadcast. If no match is found, increase the starting index and repeat. Rebuild/redeploy/recompute after changing compiler settings, constructor addresses or application source: they affect the CREATE2 address.

## Local verification

The project pins Solidity 0.8.26, Cancun, optimizer with one run, via-IR and `bytecode_hash = "none"`. All required Solidity dependencies are ordinary files under `lib/`, with upstream revisions and licenses in `DEPENDENCIES.md`; no submodules, npm install or network are required once the pinned compiler and Foundry are installed. Tests use an in-process real v4 PoolManager, core swap/liquidity test routers, the periphery MockV4Router, and mock tokens. They do not fork a network or read environment variables.

```sh
forge build
forge test
forge fmt --check
```

Coverage includes the four swap modes at every tier, exact settlement and LP fees, periphery routing, a manager initially empty of ZTO, partial fills, same-block pass transfers, constructor deployment without dependency code, exact hook bits and one-time opening, adoption and re-pricing of a pool a stranger initialized first, salt mining, zero-quote reverts on both sides of the market, forbidden runtime opcodes and runtime size, collection/donations, market success and failure paths, and fuzzed reserve/inventory accounting. The mocks explicitly reject `safeTransferFrom`, ensuring the application uses `transferFrom`.

Separate adversarial review and verification of the actual deployed dependencies remain release responsibilities; local passing tests are not an independent audit. Slither and Mythril were not installed or run. No upgrade or pause mechanism can repair this deployed application.
