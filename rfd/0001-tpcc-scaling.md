# RFD 1: TPC-C scaling specification for the `lib/ecto_bench_tpcc/tpcc` port

**State:** discussion
**Source:** `weftspun/scenario-tpcc-bench` PR #12 ("Add FDBRELATIONAL as a
BenchBase database target, prove it out with tpcc first"), which reuses
BenchBase's own stock, unmodified TPC-C loader/procedures -- so this RFD
transcribes the official TPC-C specification and BenchBase's own
implementation of it, not anything scenario-specific PR #12 invented.

## Summary

`lib/ecto_bench_tpcc/tpcc/loader.ex` currently seeds a small, fixed dataset (2
warehouses, 2 districts/warehouse, 10 customers/district, 20 items) --
explicitly documented in that module as *not yet* scale-factor-accurate
(see its moduledoc). This RFD specifies exactly what "scale-factor-accurate"
means for TPC-C, so a follow-up implementation can match it precisely
instead of guessing.

## Background

TPC-C's scale factor is a single integer, **W** (warehouse count). Every
other table's cardinality is a fixed function of W (or, for `ITEM`, fixed
regardless of W). This is the official TPC-C specification's load
requirement, which BenchBase's generic `tpcc` benchmark (the thing PR #12
points its FRL driver at, unmodified) implements as-is.

## Scaling formula

| Table | Rows | Formula |
|---|---|---|
| `WAREHOUSE` | W | 1 per warehouse |
| `DISTRICT` | 10W | exactly 10 districts per warehouse, always -- not itself scaled by a separate factor |
| `CUSTOMER` | 30,000W | 3,000 customers per district (10 districts/warehouse x 3,000) |
| `HISTORY` | 30,000W initially | one row per customer at load time; grows continuously via `Payment` transactions during the run |
| `OORDER` | 30,000W initially | one order per customer at load time (matches `CUSTOMER` 1:1 at load); grows via `NewOrder` during the run |
| `NEW_ORDER` | 9,000W initially | the last 900 of each district's 3,000 loaded orders are undelivered ("new") at load time -- 900 x 10 districts/warehouse |
| `ORDER_LINE` | ~300,000W initially | 5-15 lines per order (uniform random, mean ~10) x 30,000W orders |
| `ITEM` | 100,000 | **fixed, not scaled by W** -- the same 100,000-row item catalog is shared across every warehouse |
| `STOCK` | 100,000W | one stock row per item **per warehouse** (100,000 items x W) |

`ORDER_LINE.ol_i_id` is drawn from the shared 100,000-row `ITEM` catalog
(not per-warehouse), with TPC-C's specified "hot"/non-uniform random
distribution for realistic contention (NURand -- see the spec's exact
constants below), not pure uniform random.

## NURand (non-uniform random) distribution

TPC-C mandates a specific skewed-random function, not uniform random, for
picking customer/item IDs, to produce realistic access-pattern
contention:

```
NURand(A, x, y) = (((random(0, A) | random(x, y)) + C) % (y - x + 1)) + x
```

where `|` is bitwise OR, `C` is a per-run constant chosen once (within a
spec-defined range) and held fixed for the run, and `A` is 255 for
`C_LAST` (customer surname generation), 1023 for `C_ID`, and 8191 for
`OL_I_ID`. `lib/ecto_bench_tpcc/tpcc/loader.ex`/`procedures.ex` currently use plain
`:rand.uniform/1` throughout -- **not yet NURand-accurate**. This matters
for benchmark fidelity: uniform random access produces a flatter,
less-contended load profile than TPC-C's specified skew, which
understates real contention on hot rows (a specific customer, a specific
popular item).

## Terminals / concurrency

The official spec ties terminal (worker) count to warehouse count: 10
terminals per warehouse, each terminal bound to one specific
warehouse/district pair for the duration of a run (not roaming freely
across all warehouses). BenchBase's own harness allows configuring
terminal count independently of warehouse count for practical CI/dev
runs; `bench/harness.ex`'s `:worker_count` option should be documented as
this same practical relaxation, not silently assumed to be spec-accurate.

## Transaction mix (weights)

Official TPC-C minimums (BenchBase, and this repo's own
`test/bench_tpcc_test.exs`, already use this exact mix):

| Transaction | Weight |
|---|---|
| NewOrder | 45% |
| Payment | 43% |
| OrderStatus | 4% |
| Delivery | 4% |
| StockLevel | 4% |

`NewOrder`'s throughput (tpmC -- transactions-per-minute-C) is TPC-C's
official reported metric; the other four exist to produce a realistic
mixed load, not because their own throughput is the number anyone
reports.

## What this means for `lib/ecto_bench_tpcc/tpcc`

To be scale-factor-accurate, `lib/ecto_bench_tpcc/tpcc/loader.ex` needs:
1. A single `warehouses` (W) input driving every table's row count per
   the formula table above, not independently-chosen small constants.
2. NURand for `C_LAST`/`C_ID`/`OL_I_ID` generation, not
   `:rand.uniform/1`.
3. `ITEM` generated once (100,000 rows), never re-scaled per warehouse.
4. Terminal-to-warehouse/district binding if spec-accurate contention
   modeling matters for what's being measured (vs. today's fully random
   warehouse/district pick per transaction in `procedures.ex`).

## Open questions

* Full W=1 already means 30,000 customers / 300,000 order lines -- is a
  full scale-factor-1 run practical for a CI smoke test, or does CI stay
  intentionally small/non-spec-accurate (today's approach) while a
  separate, manually-triggered job runs spec-accurate scale?
* NURand's per-run constant `C` must be chosen once and reported
  alongside results per spec (it affects reproducibility comparisons
  across runs) -- worth exposing in `Harness.report/1`'s output.
