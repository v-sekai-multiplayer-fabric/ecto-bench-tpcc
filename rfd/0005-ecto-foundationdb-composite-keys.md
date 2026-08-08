# ADR 0005: port the harness to ecto_foundationdb with synthetic keys and indexes

## Status

Accepted.

## Context

The harness targets any Ecto adapter. `ecto_foundationdb` reaches
FoundationDB through `erlfdb`, with no JVM, no JDK and no separate
server process.

The question was whether this TPC-C workload runs on it.

## The workload already fits

`lib/ecto_bench_tpcc/tpcc/procedures.ex` has **zero joins**, no
`order_by`, no `limit`, no `or`, no `select:`, no `fragment` and no
`Repo.query`. Every predicate is equality on key fields, and
aggregation happens in Elixir:

```elixir
|> Enum.count(&(&1.s_quantity < threshold))
```

`ecto_foundationdb` accepts a query only when one Get or one GetRange
satisfies it. This workload already obeys that, so **no procedure
changed**.

`update_all` and `delete_all` are supported, so `delivery/1` needed no
rewrite. The adapter's `Unsupported` on `update_all` applies only to
changing a `partition_by:` field.

## Decision

Give each composite-keyed schema one synthetic `:binary_id` primary
key, and cover the former key fields with multi-field indexes. That is
the adapter's intended design, not a workaround.

Six schemas changed: `district`, `customer`, `oorder`, `new_order`,
`order_line` and `stock`. `warehouse`, `history` and `item` already had
single keys.

`lib/ecto_bench_tpcc/tpcc/fdb_migration.ex` carries the indexes.

## FoundationDB 7.3 or newer is required

This is the finding that cost the most time, so it leads the
consequences.

On a **7.1.26** client, every indexed query fails:

```
** (ArgumentError) argument error
    (erlfdb 1.2.1) :erlfdb_nif.erlfdb_transaction_get_mapped_range(...)
```

The adapter resolves an index through `get_mapped_range`, and the 7.1
client rejects the call. On **7.3.43** the same code works unchanged.

An earlier revision of this ADR blamed composite primary keys for a
failure that the client version caused. Composite keys are genuinely
unsupported, and they raise a clear `MatchError`. They were not what
broke the indexed queries.

## Measured

FoundationDB 7.3.43, `ecto_foundationdb` 0.7.6, `erlfdb` 1.2.1, single
node, ssd engine. 1000 district rows.

```
OLTP2 loaded 1000 rows in 615 ms (10 rows per transaction)
OLTP2 query w only:  10 rows
OLTP2 query w and d:  1 rows
OLTP2 query d and w:  1 rows
OLTP2 indexed query (new txn)    median=0.558 ms  p99=0.8 ms
OLTP2 read-modify-write (1 txn)  median=3.548 ms  p99=5.022 ms
```

Field order in the query does not matter. Index field order does.

For context, on the same machine: PostgreSQL 16 point read 0.084 ms,
raw FoundationDB point read 0.405 ms. The adapter adds roughly 0.15 ms
over raw FoundationDB.

## Two configuration traps

A **Migrator** lists versions. A **Migration** lists index operations.
Passing a Migration where a Migrator belongs leaves every index
uncreated, and the first query then reports that no index covers the
fields. Nothing warns you.

Repo options go through `Application.put_env(otp_app, Repo, ...)`.
Passing them to `start_link/1` leaves the adapter on its defaults.

## Consequence, stated plainly

This changes what the benchmark measures.

TPC-C specifies composite keys, and they are part of its access
pattern. A synthetic key changes the physical layout in FoundationDB,
and with it the contention that `NewOrder` and `Payment` produce.

A result from this port is "`ecto_foundationdb` under a TPC-C-shaped
workload". It is not TPC-C, and any published number must say so.

## Also relevant

- Transactions run under FoundationDB's 5 second limit, may re-execute
  on conflict, and must have no side effects.
- Migrations cannot rename, delete fields, drop indexes or roll back,
  and the standard `mix ecto.*` tasks do not apply.
- Tenants are mandatory, and omitting one raises at run time.

## Open

Scaling is untested. The plan is one Fly app with machines scaled 1, 2
and 4, measuring throughput against machine count.
