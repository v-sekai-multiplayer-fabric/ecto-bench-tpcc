# EctoBenchTpcc

A generic TPC-C-style benchmark harness for **any** [`Ecto`](https://hexdocs.pm/ecto)
adapter -- schema (as a portable `Ecto.Migration`), workload
(`Ecto.Query`/`Repo` calls), and load runner are all adapter-agnostic.
Bring your own `Repo`.

## Why this is a separate repo

This started as `bench/` inside
[`ecto-fdb-relational`](https://github.com/weftspun/ecto-fdb-relational)
(an Ecto adapter for FoundationDB Record Layer's Relational Layer), built
to exercise that adapter under a real mixed transaction workload. But an
Ecto *adapter* is inherently database-specific, while a TPC-C-style
stress test built purely on `Ecto.Query`/`Ecto.Migration` is not -- it
works against any real `Ecto.Adapters.SQL` adapter (Postgres, MySQL,
SQLite, `ecto_fdb_relational`, ...). Splitting it out keeps each repo's
concern single: `ecto-fdb-relational` is the adapter, this is the
benchmark.

## Origin

Ported from [`weftspun/scenario-tpcc-bench`](https://github.com/weftspun/scenario-tpcc-bench)'s
Java/BenchBase-based `tpcc` scenario (PR #12) -- see [`rfd/`](rfd/) for
the exact scaling formulas transcribed from that project's loader source,
covering all four of its scenarios (tpcc, zonefabric, assetcdn, cassie),
not just the one implemented here so far.

## Usage

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.Postgres # or any other adapter
end
```

```elixir
alias EctoBenchTpcc.Tpcc.{Loader, Procedures}
alias EctoBenchTpcc.Harness

Loader.migrate!(MyApp.Repo)
Loader.load!(MyApp.Repo)

procedures = [
  %{name: "NewOrder", weight: 45, run: fn -> Procedures.new_order(MyApp.Repo) end},
  %{name: "Payment", weight: 43, run: fn -> Procedures.payment(MyApp.Repo) end},
  %{name: "OrderStatus", weight: 4, run: fn -> Procedures.order_status(MyApp.Repo) end},
  %{name: "Delivery", weight: 4, run: fn -> Procedures.delivery(MyApp.Repo) end},
  %{name: "StockLevel", weight: 4, run: fn -> Procedures.stock_level(MyApp.Repo) end}
]

Harness.run(procedures, worker_count: 4, duration_ms: 10_000)
```

See `test/tpcc_test.exs` for a complete, running example against SQLite
(this repo's own CI reference adapter -- no external services needed).

## Status / honest gaps

- **Not yet scale-factor-accurate** (see `rfd/0001-tpcc-scaling.md`):
  `Loader.load!/1` seeds a small, fixed dataset, not BenchBase's real
  proportional-to-warehouse-count generation or its mandated NURand
  skewed-random distribution. Matching that faithfully is the eventual
  point of this project, not yet done.
- Only the standard `tpcc` scenario is implemented so far. `rfd/0002`-`0004`
  document the scaling specs for zonefabric/assetcdn/cassie, ported from
  the same upstream repo, as a specification for future scenarios --
  not yet implemented here.
- No cross-statement transaction atomicity is assumed or provided by this
  library -- see `EctoBenchTpcc.Tpcc.Procedures`'s moduledoc. Wrap calls
  in `Repo.transaction/2` yourself if your adapter supports real
  transactions and you want them.
- `StockLevel`'s `COUNT` is computed client-side (`Enum.count/2` over a
  plain `Repo.all/1`), not as a database aggregate, so it works against
  adapters that don't support `GROUP BY`/aggregates yet.

## License

Apache-2.0
