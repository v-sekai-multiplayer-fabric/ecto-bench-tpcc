# ADR 0007: measured scaling of ecto_foundationdb under the TPC-C shape

## Status

Accepted. Results for [ADR 0005](0005-ecto-foundationdb-composite-keys.md).

## Method

Each worker reads one district through its index, increments
`d_next_o_id`, and writes it back inside one `Repo.transactional/2`.
That is TPC-C's contended path.

1000 districts spread over 100 warehouses. Ten seconds per level.
FoundationDB 7.3.43, `ecto_foundationdb` 0.7.6, `erlfdb` 1.2.1, single
node, ssd engine.

Source: `probe/fly/scaling.exs`.

## Results

| Concurrency | Fly ops/s | Fly factor | Local ops/s | Local factor |
| --- | --- | --- | --- | --- |
| 1 | 401.3 | 1.00x | 277.4 | 1.00x |
| 2 | 883.8 | 2.20x | 632.4 | 2.28x |
| 4 | 1448.1 | 3.61x | 1243.1 | 4.48x |
| 8 | 1607.1 | 4.00x | 2158.8 | 7.78x |
| 16 | 1761.4 | 4.39x | 4457.0 | 16.07x |
| 32 | 2159.1 | 5.38x | 6089.5 | 21.95x |

Fly is `shared-cpu-1x` with 1 GB. Local is a 16-core workstation.

**Zero aborts at every level, on both.** Not one write conflict.

## What this shows

**The adapter does not serialize.** Local throughput scales 16.07 times
at 16 workers, which is close to linear on 16 cores. So nothing inside
`ecto_foundationdb` or `erlfdb` forces requests through one path.

**Fly flattens at 4 workers because it has one shared vCPU.** 3.61
times at 4 workers, then 4.00, 4.39 and 5.38. That is CPU saturation
rather than lock contention, and the zero abort count is what separates
those two explanations.

**Contention was not exercised.** 1000 districts and at most 32 workers
makes collisions rare. A run with few warehouses and many workers would
measure FoundationDB's optimistic concurrency instead, and it would
abort. That is a different experiment, and it is not done.

## Answering the question

`ecto_foundationdb` is usable for this OLTP shape.

401.3 operations per second on one `shared-cpu-1x` machine, for a
read-modify-write in a serializable transaction, covers the workloads
in `rfd/0102` of multiplayer-fabric-manuals. Uro at 39 concurrent users
needs about 6.5 requests per second.

Throughput is bounded by CPU on that machine shape, not by the adapter.
Scaling out means more machines against one FoundationDB cluster, and
that is untested here.

## Caveats

Both runs put `fdbserver` and the load generator on the same host, so
the numbers include no network hop. A real deployment separates them.

Single-node FoundationDB has no replication. A `double` or `triple`
cluster commits slower.

Only the read-modify-write shape ran. The other four TPC-C transactions
are not measured.

## Open

Multi-machine scaling against one shared cluster over Fly's 6PN. That
path measured 880 us median between two machines in `iad`, so a hop is
affordable, and the throughput curve is unknown.
