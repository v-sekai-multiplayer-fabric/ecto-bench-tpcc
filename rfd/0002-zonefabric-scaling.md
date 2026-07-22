# RFD 2: zonefabric scaling specification

**State:** discussion
**Source:** `weftspun/scenario-tpcc-bench` PR #2, `ZoneFabricBenchmark.java`,
`ZoneFabricLoader.java`, `ZoneFabricConstants.java` -- exact code quoted
below, not paraphrased.

## Summary

zonefabric models weft-warp-loop's PSO-style hub/instanced-zone game
server. Scale factor = **number of zones**. This RFD specifies the exact
row-count formulas so a faithful Elixir port's loader matches BenchBase's
own generator precisely, rather than an arbitrary small fixed dataset.

## Scale knob

```java
this.numZones = Math.max(1, Math.round(workConf.getScaleFactor()));
```

`scalefactor` = zone count directly (not multiplied by anything). Sample
config default: `<scalefactor>5</scalefactor>`, `<terminals>1</terminals>`
(comment: `<!-- Scale factor is the number of zones -->`).

## Scaling formula

| Table | Rows | Formula |
|---|---|---|
| `ZONE` | scalefactor | 1 zone loader thread per unit of scale factor (floor 1) |
| `ENTITY` | scalefactor x 200 | `ENTITIES_PER_ZONE = 200` (fixed) entities generated per zone |
| `EFFECT_ENTITY` | 0 at load | not seeded at load time -- only produced at runtime by the `CastSpell` transaction |
| `FANOUT_TARGET` | 0 at load | same -- runtime-only, produced alongside each `EFFECT_ENTITY` `CastSpell` writes |

## Fixed (non-scaling) constants

From `ZoneFabricConstants.java`, quoted exactly:

```java
public static final int ENTITIES_PER_ZONE = 200;
public static final double WORLD_EXTENT = 10000.0;
public static final double GHOST_RANGE = 150.0;
public static final int AUTHORITY_CAPACITY = 256;
public static final int INTEREST_CAPACITY = 512;
public static final double SPLIT_COST_THRESHOLD = 40000.0;
```

`AUTHORITY_CAPACITY`/`INTEREST_CAPACITY` are written verbatim into every
`ZONE` row's `z_authority_cap`/`z_interest_cap` columns regardless of
scale factor. `SPLIT_COST_THRESHOLD` gates `ZoneSplitMerge`: a zone's
`z_cost` (population^2, per the PR's own framing) must cross this before
a split is attempted -- see RFD 2's sibling schema notes in
`bench/zonefabric/` once that port exists.

## Randomization

Uses `com.oltpbenchmark.util.RandomDistribution.Flat` (**uniform**, not
Zipfian/skewed) for entity attributes only:

```java
randPos = new Flat(rng(), 0, WORLD_EXTENT)   // x/y position
randVel = new Flat(rng(), -10, 10)           // vx/vy velocity
randRtt = new Flat(rng(), 10, 200)           // e_rtt_ms
```

Zone assignment at load time is **not** randomized at all: each entity
is deterministically assigned to the zone its generator thread owns
(`stmtEntity.setLong(2, this.zoneId)`), and `z_region` is a deterministic
`"region-" + (zoneId % 4)`. There is no skewed "popular zone" access
pattern built into the *loader* -- any such skew would have to come from
the *workload* (`ZoneAuthorityHandoff`/`CastSpell`'s own random
zone/entity selection at runtime), which this repo's port already
implements as uniform random picks (see `lib/ecto_bench_tpcc/tpcc/procedures.ex`'s
`random/2` helper as the pattern to follow, or reconsider once this
scenario is actually ported).

## What this means for a zonefabric port

1. Loader needs one `zones` (scale factor) input, generating exactly
   `zones` `ZONE` rows and `zones * 200` `ENTITY` rows -- not
   independently-chosen small constants.
2. `EFFECT_ENTITY`/`FANOUT_TARGET` are correctly empty at load time in
   any faithful port; they only exist as a result of running
   `CastSpell` during the workload itself.
3. `AUTHORITY_CAPACITY`/`INTEREST_CAPACITY`/`SPLIT_COST_THRESHOLD` should
   be named constants in the port (matching FRL's actual DDL types --
   `z_authority_cap`/`z_interest_cap` as `BIGINT`, `SPLIT_COST_THRESHOLD`
   comparisons against `z_cost` as `DOUBLE`), not re-derived or guessed.
4. Uniform (`Flat`) random generation, not skewed, for position/velocity
   attributes -- reproducing BenchBase's own choice rather than
   introducing skew that changes the measured access pattern.

## Open questions

* `WORLD_EXTENT`/`GHOST_RANGE` govern `CastSpell`'s
  `e_x BETWEEN`/`e_y BETWEEN` range query bounds -- worth confirming
  against the actual procedure code (not yet extracted in this RFD)
  before porting `CastSpell`'s nearby-entity query.
* No terminal-to-zone binding is described in the loader; confirm
  whether `ZoneAuthorityHandoff`/`ZoneSplitMerge` pick zones uniformly
  across the *entire* scale factor or are meant to be worker-local
  (matching TPC-C's per-warehouse terminal binding convention from RFD 1)
  before assuming uniform-random-across-all-zones is spec-accurate here
  too.
