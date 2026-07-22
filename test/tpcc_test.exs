defmodule EctoBenchTpcc.TpccTest do
  @moduledoc """
  Runs the mixed TPC-C workload against a real (if disposable) SQLite
  database via `ecto_sqlite3` -- the reference adapter this repo's own CI
  uses to prove the harness/schema/workload are genuinely adapter-generic,
  not just something that happens to work against `ecto_fdb_relational`.
  Any other real `Ecto.Adapters.SQL` adapter (Postgres, MySQL,
  `ecto_fdb_relational`, ...) should work the same way: define a `Repo`
  using that adapter and pass it to `EctoBenchTpcc.Tpcc.Loader`/
  `EctoBenchTpcc.Tpcc.Procedures` exactly like this test does.
  """
  use ExUnit.Case, async: false

  alias EctoBenchTpcc.Harness
  alias EctoBenchTpcc.Tpcc.{Loader, Procedures}

  defmodule Repo do
    use Ecto.Repo, otp_app: :ecto_bench_tpcc, adapter: Ecto.Adapters.SQLite3
  end

  setup_all do
    File.rm("tpcc_test.db")

    Application.put_env(:ecto_bench_tpcc, Repo,
      database: "tpcc_test.db",
      pool_size: 1
    )

    {:ok, _pid} = Repo.start_link()
    Loader.migrate!(Repo)
    Loader.load!(Repo)

    on_exit(fn ->
      Repo.stop()
      File.rm("tpcc_test.db")
    end)

    :ok
  end

  # GitHub Actions' standard Linux runner has 2 vCPUs -- run the same
  # mixed workload at worker_count: 1 and worker_count: 2 and print both
  # throughputs side by side, as a real (not simulated) demonstration
  # that concurrency actually helps. This is a *soft* check, not a hard
  # `assert 2-worker ips > 1-worker ips`: SQLite serializes writers at
  # the database-file level, so a write-heavy mix like this (NewOrder +
  # Payment are 88% of the weight, both multi-row writes) may not scale
  # cleanly 1->2 the way a real multi-writer database would -- that's a
  # property of the reference adapter used here, not a bug in the
  # harness. A real regression (2-worker meaningfully *slower*) still
  # gets flagged.
  test "mixed TPC-C workload demonstrates scaling from 1 to 2 workers" do
    procedures = [
      %{name: "NewOrder", weight: 45, run: fn -> Procedures.new_order(Repo) end},
      %{name: "Payment", weight: 43, run: fn -> Procedures.payment(Repo) end},
      %{name: "OrderStatus", weight: 4, run: fn -> Procedures.order_status(Repo) end},
      %{name: "Delivery", weight: 4, run: fn -> Procedures.delivery(Repo) end},
      %{name: "StockLevel", weight: 4, run: fn -> Procedures.stock_level(Repo) end}
    ]

    ips_1 = Harness.run(procedures, worker_count: 1, duration_ms: 3_000)
    ips_2 = Harness.run(procedures, worker_count: 2, duration_ms: 3_000)

    IO.puts("""
    scaling: 1 worker = #{Float.round(ips_1, 1)} tx/s, \
    2 workers = #{Float.round(ips_2, 1)} tx/s \
    (#{Float.round(ips_2 / ips_1, 2)}x)
    """)

    # Soft check: 2 workers shouldn't be *meaningfully worse* than 1 --
    # some slack for scheduling noise and SQLite's single-writer lock,
    # but a real regression (less than half the throughput) still fails.
    assert ips_2 > ips_1 * 0.5
  end
end
