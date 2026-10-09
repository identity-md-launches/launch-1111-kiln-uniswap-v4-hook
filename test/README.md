# Kiln test coverage

Run `forge build` and `forge test` from the repository root. Everything runs offline with the vendored v4 PoolManager, core test routers, periphery router, mock ZTO and mock Pepeolithic. No RPC, environment mutation, FFI or new dependency is needed.

The pre-existing suites check one-time CREATE2 opening, exact hook permissions, all four swap modes at all four tiers, ERC-6909 collection, real LP fee growth, periphery settlement, liquidity, piece trades and failure paths. Launcher tests also reject a mined address with an extra permission or a missing required permission and check both constructors' missing-dependency errors.

`AdversarialEdges.t.sol` adds collection rollback after failed trades, rollback of swap-and-pop and token allowances, final NFT delivery failure, failed router settlement, duplicate sales, unfunded seeds, sales of unminted or out-of-collection ids, all 737 pieces, near-maximum reserve arithmetic, one-wei swaps and zero/minimum-signed swap rejection. The fee-rounding property runs 1,000 examples with amounts from one wei to one million wei. Tiny swaps can have zero output or zero cut after rounding; exact settlement and the fee equation are still checked.

Two tests pin the economic consequences the root README discloses rather than hide them. A zero-piece wallet can rent the Kiln's own inventory (buy 21 pieces, swap cut-free, sell them back): the test shows the swap pays no cut, the rent lands in the reserve, is about 5.5% of the reserve regardless of swap size, and only undercuts the 1.30% cut for swaps of several reserves. The seed sandwich (buy a listed piece, let a seed land, sell it back) is a 1,000-run property with pinned cases on both sides of breakeven: the capture never exceeds 2% of the inflow, loses below about 12.7% of the reserve, wins above 20%, and the rest of the seed stays in the reserve.

`Launcher.t.sol` also covers the adoption path for a pool a stranger initialized at the predicted Kiln address before `open()`. With stranger liquidity the supplied `sqrtPriceX96` is ignored and the pool trades at the stranger's price, but the Kiln still charges and collects its cut there. On an empty adopted pool the two modes that mint a specified cut in `beforeSwap` (ZTO exact-input, ETH exact-output) revert with `PartialSpecifiedSwap` on the zero fill for wallets with 0, 1 or 4 pieces and succeed, moving the price with zero deltas, for a 21-piece wallet, as the root README states.

`KilnInvariant.t.sol` runs 256 sequences of 96 calls, with unexpected reverts treated as failures. Its handler starts with four funded wallets holding 0, 1, 4 and 21 NFTs, and a pool with real liquidity. Random actions include all swap modes, seed, collect, sell, buy, pass transfers, direct ZTO/NFT donations, claim donations, and rejected purchases. NFT ownership and the wallets' tiers change during a sequence. Inputs are bounded; token supply and balances are never replenished during the campaign.

The handler records cash flows and NFT ownership separately from application storage. After every step, the invariant checks:

- Reserve equals seeds plus buyer payments plus redeemed claims minus seller payouts; real ZTO equals reserve plus unaccounted direct donations.
- Redeemed plus outstanding claims equal total fee claims plus donated claims, with donations distinguished from the swap-only `claims()` counter.
- Inventory matches completed trades, contains no duplicates, and excludes stuck plain transfers; NFT ownership matches the independent model.
- Bid remains payable, total ZTO is conserved across all participants, the manager is locked with no outstanding deltas, and the Launcher still references the original Kiln.

After every sequence, collection must succeed and every remaining inventory piece must be buyable. A deterministic handler test exercises every action, all four swap modes at each starting tier, and both nonempty and empty collections. Sell/buy handlers return early only if no eligible piece or payable bid exists; they do not catch or suppress unexpected failures.

The invariant tracks 26 minted IDs to keep campaigns practical; the separate full-collection test covers all 737 IDs. The deployed Sepolia token/NFT implementations and actual deployed router wiring are not fork-tested here. Callback-bearing, rebasing and fee-on-transfer tokens are outside the specified ordinary ERC-20/ERC-721 model.

With ETH as currency0 and ZTO as currency1, v4's price is ZTO per ETH, so a ZTO-only range sits **below** the opening tick; a range above the opening tick is ETH-only. The brief's "ZTO-only range above the opening price" is the same position described from ZTO's side (it sells ZTO at ZTO prices above the opening one). The liquidity tests prove both directions against the real PoolManager and liquidity router, and ETH-in swaps are shown to draw from that ZTO-only range. No mock AMM is substituted.
