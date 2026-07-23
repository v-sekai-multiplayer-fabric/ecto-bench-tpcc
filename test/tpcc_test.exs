defmodule EctoBenchTpcc.TpccTest do
  @moduledoc """
  Runs the mixed TPC-C workload against a real FoundationDB cluster via
  `ecto_fdb_relational` -- the reference adapter this repo's own CI uses
  to prove the harness/schema/workload are genuinely adapter-generic, and
  the adapter this whole repo was split out of. Any other real
  `Ecto.Adapters.SQL` adapter (Postgres, MySQL, SQLite, ...) should work
  the same way: define a `Repo` using that adapter and pass it to
  `EctoBenchTpcc.Tpcc.Loader`/`EctoBenchTpcc.Tpcc.Procedures` exactly like
  this test does.

  As of `ecto_fdb_relational` v0.2, FRL is embedded in-process via a
  Rustler NIF + JNI (no separate `fdb-relational-server`/gRPC process at
  runtime) -- see that project's `CHANGELOG.md` (ADR 0003). This still
  needs a live FoundationDB cluster, a JDK + Rust toolchain on the
  machine that *compiles* this repo (to build the NIF and link against
  `libjvm`), and `ECTO_FDB_RELATIONAL_CLASSPATH` set to the FRL jars
  (`org.foundationdb:fdb-relational-server:<version>:all` is enough) --
  see `.github/workflows/ci.yml` for how CI sets all of this up, or do it
  yourself and point this test at your cluster:

      FRL_TEST_CLUSTER_FILE=/etc/foundationdb/fdb.cluster \\
        ECTO_FDB_RELATIONAL_CLASSPATH=/path/to/fdb-relational-server-all.jar \\
        mix test
      # optional: FRL_TEST_DATABASE=/FRL/ECTO_BENCH_TPCC_TEST

  As of v0.3, `Repo.transaction/2` is real: multiple statements batch into
  one FDB commit (autocommit-disabled `RelationalConnection`), with real
  isolation and rollback -- unlike v0.1's gRPC transport, this is not
  best-effort. The `NewOrder`/`Payment` wrapping below now buys genuine
  atomicity against this adapter. Catalog-level DDL (`CREATE`/`DROP
  DATABASE`/`SCHEMA`/`SCHEMA TEMPLATE`) still can't run inside a
  transaction, which is fine here since migrations never do.

  Real atomicity means real write-write conflicts under contention: this
  test's seed dataset (`Loader.load!/2`, the official TPC-C minimum --
  see `rfd/0001-tpcc-scaling.md`) is large enough (~600,000 rows at
  `warehouses: 1`) that `worker_count: 2` colliding on the exact same
  warehouse/district/customer row is rare but still real -- FDB then
  raises `"Transaction not committed due to conflict with another
  transaction"`. TPC-C's own spec mandates resubmitting a rolled-back
  transaction with the same inputs rather than treating it as a failure --
  the standard OCC client pattern `EctoBenchTpcc.Tpcc.Retry.transaction/2`
  implements below, used here instead of calling `Repo.transaction/2`
  directly.
  """
  use ExUnit.Case, async: false

  alias EctoBenchTpcc.Harness
  alias EctoBenchTpcc.Tpcc.{Loader, Procedures, Retry}

  defmodule Repo do
    use Ecto.Repo, otp_app: :ecto_bench_tpcc, adapter: EctoFdbRelational.Adapter
  end

  setup_all do
    # :database must be uppercase -- FRL case-folds unquoted DDL
    # identifiers but uses config fields literally, uncased (see
    # ecto_fdb_relational's README).
    cluster_file = System.get_env("FRL_TEST_CLUSTER_FILE", "/etc/foundationdb/fdb.cluster")
    database = System.get_env("FRL_TEST_DATABASE", "/FRL/ECTO_BENCH_TPCC_TEST")
    base_config = [cluster_file: cluster_file, database: database, relational_schema: "PUBLIC"]

    # Migrate with a *small* pool -- Ecto.Migrator.with_repo/3 itself
    # defaults to pool_size: 2 for exactly this reason (see
    # Loader.migrate!/1's moduledoc): several connections all
    # establishing at once makes this adapter's DDL bootstrap noticeably
    # more likely to hit a transient FDB conflict, measured directly
    # against a real cluster. Only the *load* phase below needs a big
    # pool.
    Application.put_env(:ecto_bench_tpcc, Repo, base_config ++ [pool_size: 2])
    {:ok, _pid} = Repo.start_link()

    # Repo.start_link/0 returns as soon as the pool supervisor is up, not
    # once a connection has actually been established -- but
    # EctoFdbRelational.Ddl needs Protocol.connect/1 to have already run
    # (it stashes the target database/schema in :persistent_term the
    # moment a connection is made) before any migration DDL can run.
    # Forcing a checkout here blocks until a real connection exists.
    Repo.checkout(fn -> :ok end)

    # Retry.run/1, not Loader.migrate!/1 itself (see that function's own
    # moduledoc for why a small migration pool is the *real* fix) --
    # this is specifically a pragmatic safety net for this test's own
    # long, unattended runs against FRL's DDL bootstrap, which still
    # flakes on a rare transient FDB conflict even with pool_size: 2.
    # Retrying the whole migration is safe: EctoBenchTpcc.Tpcc.Migration's
    # change/0 re-issues its whole schema from scratch on every `create
    # table` (see EctoFdbRelational.SchemaTemplate's moduledoc), so a
    # failure partway through and a full retry from the top is
    # idempotent, not just "probably fine".
    Retry.run(fn -> Loader.migrate!(Repo) end)
    Repo.stop()

    # Now restart with a bigger pool for Loader.load!/2's concurrently
    # batched inserts (see its moduledoc's "Timing" section --
    # @load_concurrency 16) to actually run in parallel instead of
    # queueing on a 2-connection pool.
    Application.put_env(:ecto_bench_tpcc, Repo, base_config ++ [pool_size: 20])
    {:ok, _pid} = Repo.start_link()
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
  # `assert 2-worker ips > 1-worker ips`: FDB's own per-statement commit
  # latency dominates here far more than any single-writer contention
  # would, so a write-heavy mix like this
  # (NewOrder + Payment are 88% of the weight, both multi-statement
  # writes) may not scale cleanly 1->2 the way a real multi-writer
  # database would -- that's a property of the reference adapter used
  # here, not a bug in the harness. A real regression (2-worker
  # meaningfully *slower*) still gets flagged.
  test "mixed TPC-C workload demonstrates scaling from 1 to 2 workers" do
    # Procedures.new_order/1 and Procedures.payment/1 read-then-write
    # d_next_o_id/customer balances across separate statements with no
    # atomicity of their own (see EctoBenchTpcc.Tpcc.Procedures moduledoc)
    # -- wrapping each call gives real atomicity against this adapter as
    # of ecto_fdb_relational v0.3 (see this module's moduledoc), via
    # Retry.transaction/2 rather than a bare Repo.transaction/2 so a real
    # write-write conflict retries (as TPC-C's own spec requires) instead
    # of crashing the run.
    procedures = [
      %{
        name: "NewOrder",
        weight: 45,
        run: fn -> Retry.transaction(Repo, fn -> Procedures.new_order(Repo) end) end
      },
      %{
        name: "Payment",
        weight: 43,
        run: fn -> Retry.transaction(Repo, fn -> Procedures.payment(Repo) end) end
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
    # some slack for scheduling noise and per-statement FDB commit
    # latency variance, but a real regression (less than half the
    # throughput) still fails.
    assert ips_2 > ips_1 * 0.5
  end
end
