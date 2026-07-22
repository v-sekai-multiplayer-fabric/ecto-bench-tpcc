# Scaling RFDs

Request-for-Discussion-style documents (format inspired by
[Oxide Computer Company's RFD process](https://rfd.shared.oxide.computer/))
specifying exactly how each ported benchmark scenario's data volume scales
with its BenchBase `scalefactor` parameter, transcribed precisely from
`weftspun/scenario-tpcc-bench`'s actual loader/constants source -- not
guessed or approximated -- so `bench/*` ports can match upstream's
generated data volumes and access patterns exactly.

| RFD | Scenario | Source PR | Scale knob |
|---|---|---|---|
| [0001](0001-tpcc-scaling.md) | tpcc (standard TPC-C) | #12 | warehouses (W) |
| [0002](0002-zonefabric-scaling.md) | zonefabric | #2 | zones |
| [0003](0003-assetcdn-scaling.md) | assetcdn | #9 | distinct assets |
| [0004](0004-cassie-scaling.md) | cassie | #10 | concurrent canvases |

Each RFD documents: the exact per-table row-count formula, fixed
(non-scaling) constants, sample-config defaults, and randomization/skew
behavior (or lack thereof) -- plus open questions where the port and the
upstream spec might reasonably diverge. `lib/ecto_bench_tpcc/tpcc/loader.ex`'s own
moduledoc already flags that today's Elixir loaders use small fixed
datasets, not yet these formulas -- these RFDs are what a
scale-factor-accurate follow-up should implement against.
