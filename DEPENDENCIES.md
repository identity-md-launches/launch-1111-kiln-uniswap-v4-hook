# Vendored dependencies

- Uniswap/v4-core at `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` (required source/test subset and upstream licenses).
- Uniswap/v4-periphery at `9969eec44cfdf07e24b41de47f40276a58401976` (required source/test subset and upstream licenses).
- foundry-rs/forge-std at `0258fe875e1d8e207c1eb7175e542ea32356773c` (required source/test subset and upstream licenses).
- transmissions11/solmate at `4b47a19038b798b4a33d9749d25e570443520647` (required source subset and upstream licenses).

Only the transitive source closure used by this project is retained. No upstream source is modified. `DEPENDENCY_HASHES.json` records SHA-256 hashes of every retained vendored file. Uniswap core supplies the real PoolManager and PoolSwapTest/PoolModifyLiquidityTest routers; periphery supplies MockV4Router and its routing dependencies. Solmate is pinned to the revision referenced by this v4-core commit. Upstream license files are retained beside their respective sources.
