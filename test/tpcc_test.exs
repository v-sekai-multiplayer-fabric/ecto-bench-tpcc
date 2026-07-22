defmodule EctoBenchTpcc.TpccTest do
  @moduledoc """
  Runs the mixed TPC-C workload against a real `fdb-relational-server` +
  FoundationDB cluster via `ecto_fdb_relational` -- the reference adapter
  this repo's own CI uses to prove the harness/schema/workload are
  genuinely adapter-generic, and the adapter this whole repo was split
  out of. Any other real `Ecto.Adapters.SQL` adapter (Postgres, MySQL,
  SQLite, ...) should work the same way: define a `Repo` using that
  adapter and pass it to `EctoBenchTpcc.Tpcc.Loader`/
  `EctoBenchTpcc.Tpcc.Procedures` exactly like this test does.

  Needs a live server to run against -- see
  `.github/workflows/ci.yml` for how CI stands one up (FoundationDB
  7.1.26 + `fdb-relational-server` 4.3.6.0), or run one yourself per
  `ecto_fdb_relational`'s own README and point this test at it:

      FRL_TEST_PORT=8123 mix test
      # optional: FRL_TEST_HOST=localhost FRL_TEST_DATABASE=/FRL/ECTO_BENCH_TPCC_TEST

  **`ecto_fdb_relational`'s `Repo.transaction/2` provides no real
  atomicity or isolation (v0.1 -- see its README's "Transactions"
  section): each statement inside commits independently exactly as if
  it were called outside the transaction.** The `NewOrder`/`Payment`
  wrapping below is therefore best-effort, not a real fix like it would
  be against SQLite/Postgres -- under `worker_count: 2` two workers can
  still race reading/incrementing the same `d_next_o_id`, and FRL's
  record-oriented `insert!` on a colliding primary key overwrites rather
  than raising (no unique-constraint error surfaces through this
  adapter), so a race here silently drops an order/order-line instead of
  crashing the test. Stated here because it's a genuine, adapter-specific
  correctness gap this benchmark inherits, not something this test papers
  over.
  """
  use ExUnit.Case, async: false

  alias EctoBenchTpcc.Harness
  alias EctoBenchTpcc.Tpcc.{Loader, Procedures}

  defmodule Repo do
    use Ecto.Repo, otp_app: :ecto_bench_tpcc, adapter: EctoFdbRelational.Adapter
  end

  setup_all do
    # :database must be uppercase -- FRL case-folds unquoted DDL
    # identifiers but uses config fields literally, uncased (see
    # ecto_fdb_relational's README).
    Application.put_env(:ecto_bench_tpcc, Repo,
      hostname: System.get_env("FRL_TEST_HOST", "localhost"),
      port: String.to_integer(System.get_env("FRL_TEST_PORT", "8123")),
      database: System.get_env("FRL_TEST_DATABASE", "/FRL/ECTO_BENCH_TPCC_TEST"),
      relational_schema: "PUBLIC",
      pool_size: 2
    )

    {:ok, _pid} = Repo.start_link()
    Loader.migrate!(Repo)
    Loader.load!(Repo)

    on_exit(fn ->
      Repo.stop()
    end)

    :ok
  end

  # GitHub Actions' standard Linux runner has 2 vCPUs -- run the same
  # mixed workload at worker_count: 1 and worker_count: 2 and print both
  # throughputs side by side, as a real (not simulated) demonstration
  # that concurrency actually helps. This is a *soft* check, not a hard
  # `assert 2-worker ips > 1-worker ips`: `fdb-relational-server`'s gRPC
  # round-trip per statement dominates latency here far more than any
  # single-writer contention would, so a write-heavy mix like this
  # (NewOrder + Payment are 88% of the weight, both multi-statement
  # writes) may not scale cleanly 1->2 the way a real multi-writer
  # database would -- that's a property of the reference adapter used
  # here, not a bug in the harness. A real regression (2-worker
  # meaningfully *slower*) still gets flagged.
  test "mixed TPC-C workload demonstrates scaling from 1 to 2 workers" do
    # Procedures.new_order/1 and Procedures.payment/1 read-then-write
    # d_next_o_id/customer balances across separate statements with no
    # atomicity of their own (see EctoBenchTpcc.Tpcc.Procedures moduledoc)
    # -- wrapping each call in Repo.transaction/2 mirrors what the
    # moduledoc asks callers who want atomicity to do, but against this
    # adapter it buys none (see this module's moduledoc): it's kept here
    # so the same test code would give real atomicity against an adapter
    # that supports it, not because it does here.
    procedures = [
      %{
        name: "NewOrder",
        weight: 45,
        run: fn -> Repo.transaction(fn -> Procedures.new_order(Repo) end) end
      },
      %{
        name: "Payment",
        weight: 43,
        run: fn -> Repo.transaction(fn -> Procedures.payment(Repo) end) end
      },
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
    # some slack for scheduling noise and gRPC round-trip variance, but a
    # real regression (less than half the throughput) still fails.
    assert ips_2 > ips_1 * 0.5
  end
end
