# RFD 3: assetcdn scaling specification

**State:** discussion
**Source:** `weftspun/scenario-tpcc-bench` PR #9, `AssetCdnBenchmark.java`,
`AssetCdnLoader.java`, `AssetCdnConstants.java` -- exact code quoted
below, not paraphrased. Note: this PR is currently PostgreSQL-only in
the upstream repo (no FRL integration there yet), unlike PR #12.

## Summary

assetcdn models zone-backend's 3D asset CDN: a catalog of versioned
assets, an edge cache fleet, and per-user entitlements. Scale factor =
**number of distinct assets**. Despite the "3D asset" framing, the
schema is entirely scalar metadata (`size_bytes BIGINT`,
`storage_uri VARCHAR(200)`, `content_hash VARCHAR(64)`) -- no BLOB or
vector columns to map for FRL.

## Scale knob

```java
this.numAssets = Math.max(1, Math.round(workConf.getScaleFactor()));
```

Sample config default: `<scalefactor>5</scalefactor>`, `<terminals>1</terminals>`
(comment: `<!-- Scale factor is the number of distinct assets -->`).

## Scaling formula

| Table | Rows | Formula |
|---|---|---|
| `ASSET` | numAssets | one `LoaderThread`/Generator per asset, `for (long a = 0; a < numAssets; a++)` |
| `ASSET_VERSION` | numAssets | exactly 1 seed version (`version=1`) per asset -- 1:1, no multiplier |
| `EDGE_CACHE_ENTRY` | numAssets | exactly 1 seed row per asset at load time, always on edge node `0` (`stmt.setInt(1, 0)`) -- **not** `numAssets * EDGE_NODE_COUNT`; the fixed 8-node fleet only gets populated across nodes at runtime, not at load |
| `USER_ENTITLEMENT` | numAssets x 50 | `for (int u = 0; u < ENTITLEMENTS_PER_ASSET; u++)` per asset |

## Fixed (non-scaling) constants

From `AssetCdnConstants.java`, quoted exactly:

```java
public static final int EDGE_NODE_COUNT = 8;
public static final int ENTITLEMENTS_PER_ASSET = 50;
public static final long DEFAULT_ASSET_SIZE_BYTES = 5_000_000L;
public static final long CACHE_STALE_TICKS = 10_000L;
```

The class's own comment states the intent directly: *"Fixed edge-node
fleet size, independent of scale factor: adding more assets doesn't add
more edge locations in the real system, it adds more objects those same
edge locations cache."* `EDGE_NODE_COUNT` is referenced by the workload
procedures (`AssetFetch`'s cache-population logic picks among the 8
nodes), not by the loader's row-count generation, which only seeds node
`0`.

## Sample config (work block)

```xml
<batchsize>128</batchsize>
<scalefactor>5</scalefactor>
<terminals>1</terminals>
```

Work block: `<time>60</time>`, `<rate>10000</rate>`, transaction weights
`40,15,30,3,12` for
AssetFetch/AssetUpload/EntitlementCheck/CacheEviction/EdgeSyncStatus --
**note this differs from the earlier general research's assumed
45/43/4/4/4-style TPC-C mix**; assetcdn has its own weighting, quoted
here precisely: AssetFetch 40%, AssetUpload 15%, EntitlementCheck 30%,
CacheEviction 3%, EdgeSyncStatus 12%.

## Randomization

No skewed/Zipfian distribution in the loader at all -- every value is
deterministic:

```java
owner = "owner-" + (assetId % 500)
contentHash = "hash-" + assetId + "-v1"
storageUri = "s3://assets/" + assetId + "/v1"
userId = assetId * 1_000_000L + u   // per entitlement
```

Every asset gets identically 1 version, 1 cache entry (on node 0), and
50 entitlements at load time -- zero per-asset variance built into the
loader. Any access-pattern skew (which assets are "popular" and get
fetched/cached more) would have to come from the *workload*
(`AssetFetch`'s asset selection at runtime), not the load phase.

## What this means for an assetcdn port

1. Loader needs one `assets` (scale factor) input; `ASSET`,
   `ASSET_VERSION`, and `EDGE_CACHE_ENTRY` (seeded on node 0 only) all
   scale 1:1 with it, while `USER_ENTITLEMENT` scales at 50x.
2. `EDGE_NODE_COUNT = 8` must be a named constant used by the *workload*
   procedures (`AssetFetch`/cache placement across nodes), not the
   loader.
3. Weight the mixed workload 40/15/30/3/12
   (AssetFetch/AssetUpload/EntitlementCheck/CacheEviction/EdgeSyncStatus),
   not TPC-C's 45/43/4/4/4 -- these are different specs with different
   transaction-mix intent (assetcdn is read-fetch-heavy at 40% + a
   30% pure-read entitlement check = 70% reads by weight, vs TPC-C's
   write-heavy NewOrder+Payment dominance).
4. This is the simplest of the three custom scenarios to port: no
   composite multi-row fanout inserts at load time, no BLOB/vector
   types, purely scalar columns throughout.

## Open questions

* PR #9 is PostgreSQL-only upstream (unlike PR #12's FRL work) -- no
  FRL-specific type mapping or DDL grammar limitations have been
  verified against a live server for this scenario yet. `lib/ecto_bench_tpcc/tpcc`'s
  own confirmed FRL facts (case-folding, `/__SYS` catalog routing,
  `java_sql_types_code` parameter binding) should transfer directly, but
  haven't been re-verified against *this* schema specifically.
* `CACHE_STALE_TICKS` isn't used in the loader excerpt reviewed here --
  confirm where it's consumed (likely `CacheEviction`'s staleness check)
  before porting that procedure.
