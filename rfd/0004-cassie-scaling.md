# RFD 4: cassie scaling specification

**State:** discussion
**Source:** `weftspun/scenario-tpcc-bench` PR #10, `CassieBenchmark.java`,
`CassieLoader.java`, `CassieConstants.java` -- exact code quoted below,
not paraphrased. Note: this PR is currently PostgreSQL-only upstream (no
FRL integration there yet), and the PR itself calls this scenario "a
reasonable strawman, not a verified-accurate model" of the real cassie
stroke-beautification algorithm -- carry that caveat into any port.

## Summary

cassie models many concurrent collaborative-sketch sessions: users
append freehand stroke input, a beautification step smooths completed
strokes, and canvas state syncs out to subscribers. Scale factor =
**number of concurrent canvases**, matching zonefabric's own convention
("scale factor = zone count") by explicit comment in the source.

## Scale knob

```java
this.numCanvases = Math.max(1, Math.round(workConf.getScaleFactor()));
```

Sample config default (postgres only -- no sqlite variant in this PR):
`<scalefactor>5</scalefactor>`, `<terminals>1</terminals>` (comment:
`<!-- Scale factor is the number of concurrent canvases -->`).

## Scaling formula

| Table | Rows | Formula |
|---|---|---|
| `CANVAS` | numCanvases | one loader thread per canvas, `for (long c = 0; c < numCanvases; c++)` |
| `CANVAS_SUBSCRIBER` | numCanvases x 10 | `SUBSCRIBERS_PER_CANVAS = 10` per canvas |
| `STROKE` (seed) | numCanvases x 5 | `STROKES_PER_CANVAS_SEED = 5` per canvas |
| `STROKE_POINT` | numCanvases x 100 | `5 strokes x 20 points/stroke` per canvas (`POINTS_PER_SEED_STROKE = 20`) |
| `BEAUTIFIED_STROKE` | 0 at load | not seeded -- only produced at runtime by `BeautifyStroke` |

## Fixed (non-scaling) constants

From `CassieConstants.java`, quoted exactly:

```java
public static final int STROKES_PER_CANVAS_SEED = 5;
public static final int POINTS_PER_SEED_STROKE = 20;
public static final int SUBSCRIBERS_PER_CANVAS = 10;
public static final int POINTS_PER_APPENDED_STROKE = 30; // per-transaction (workload), not load
public static final double CANVAS_EXTENT = 4096.0;
```

`POINTS_PER_APPENDED_STROKE` governs `AppendStrokePoints`'s runtime
fanout insert size (30 points per newly-appended stroke during the
workload), distinct from the 20-point seed strokes generated at load.

## Randomization

**No RNG distribution class at all** -- every value is deterministic,
derived from IDs by simple arithmetic:

```java
owner = "owner-" + (canvasId % 500)
userId = canvasId * 1_000_000L + s          // per subscriber
x = (p * 13) % CANVAS_EXTENT                 // per stroke point
y = (p * 29) % CANVAS_EXTENT
```

No skewed/Zipfian selection of which canvas gets more activity, and
canvas ownership per generator thread is 1:1 (each thread owns exactly
one canvas ID) -- unlike zonefabric's `Flat` (uniform) RNG for
continuous attributes, cassie doesn't use any `RandomDistribution` class
whatsoever, even for uniform generation; it's pure modular-arithmetic
determinism.

## What this means for a cassie port

1. Loader needs one `canvases` (scale factor) input; `CANVAS`,
   `CANVAS_SUBSCRIBER` (x10), and seed `STROKE`/`STROKE_POINT` (x5, x100)
   all scale directly off it.
2. `BEAUTIFIED_STROKE` stays empty until the workload runs
   `BeautifyStroke` -- a faithful loader must not pre-seed it.
3. `POINTS_PER_APPENDED_STROKE = 30` (workload-time fanout size) is
   distinct from the loader's `POINTS_PER_SEED_STROKE = 20` -- don't
   conflate the two when porting `AppendStrokePoints`.
4. Deterministic point coordinates (`(p * 13) % 4096`, `(p * 29) % 4096`)
   are simple enough to reproduce exactly in Elixir if bit-for-bit
   matching the upstream loader's generated data matters for
   cross-implementation comparison; otherwise any deterministic or
   uniform-random scheme within `[0, CANVAS_EXTENT)` is faithful to the
   *intent* (the PR itself doesn't claim these specific coordinates are
   semantically meaningful).

## Open questions

* This is explicitly the least-verified of the three custom scenarios
  per the PR's own words ("a reasonable strawman, not a verified-accurate
  model") -- a port should carry that same caveat forward rather than
  implying more fidelity than upstream itself claims.
* The PR notes goodput plateaus past T=4 terminals, "plausibly
  BeautifyStroke/StrokeUndo contention on shared STROKE rows," but flags
  this as unverified -- worth re-checking once ported onto this
  adapter, given this adapter's own documented lack of cross-statement
  atomicity (see `lib/ecto_bench_tpcc/tpcc/procedures.ex`'s moduledoc for the pattern
  to follow when noting the same gap here).
* No FRL-specific facts have been verified for this schema (PostgreSQL-only
  upstream, same caveat as assetcdn in RFD 3).
