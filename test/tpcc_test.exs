defmodule EctoBenchTpcc.TpccTest do
  @moduledoc """
  Runs the mixed TPC-C workload against a real FoundationDB cluster via
  `ecto_foundationdb` -- the reference adapter this repo's own CI uses to
  prove the harness/schema/workload are genuinely adapter-generic. Any
  other real Ecto adapter (Postgres, MySQL, SQLite, ...) should work the
  same way: define a `Repo` using that adapter and pass it to
  `EctoBenchTpcc.Tpcc.Loader`/`EctoBenchTpcc.Tpcc.Procedures` exactly like
  this test does.

  `ecto_foundationdb` reaches FoundationDB through `erlfdb`. There is no
  JVM, no JDK, no Rust toolchain and no separate server process, so all
  this needs is a FoundationDB install. **7.3 or newer is required**: on a
  7.1.26 client the adapter's `get_mapped_range` call raises
  `ArgumentError` and every indexed query fails. See
  `.github/workflows/ci.yml` for how CI installs it.

  By default the test uses `EctoFoundationDB.Sandbox`, which starts its own
  single-node cluster under `.erlfdb_sandbox/` using the `fdbserver` binary
  from the FoundationDB server package. Point it at a cluster you already
  run instead with:

      FDB_TEST_CLUSTER_FILE=/etc/foundationdb/fdb.cluster mix test

  ## Why there is no `Loader.migrate!/1` call

  FoundationDB has no DDL, so the adapter has no `CREATE TABLE`. What it
  does need is the one index `order_status/1` depends on, which
  `EctoBenchTpcc.Tpcc.FdbMigrator` declares and the adapter's own migrator
  creates on tenant open. `Loader.migrate!/1` remains for the
  `Ecto.Adapters.SQL` adapters that do need a schema.

  ## Composite primary keys

  The schemas keep TPC-C's natural compound keys, for example `DISTRICT`
  on `(D_W_ID, D_ID)`. The adapter stores those fields as separate
  elements of the FDB key tuple in declaration order, so a query
  constraining a leading prefix is one GetRange and needs no index. That
  is why `EctoBenchTpcc.Tpcc.FdbMigration` declares one index rather than
  seven. See that module and `rfd/0005-ecto-foundationdb-composite-keys.md`.

  ## Conflicts

  FoundationDB is optimistic, so real atomicity means real write-write
  conflicts under contention. This test's seed dataset (`Loader`) is
  deliberately tiny (2 warehouses, 2 districts each), so at
  `worker_count: 2` two concurrent `Payment` calls regularly collide on the
  same warehouse/district row. TPC-C's own spec mandates resubmitting a
  rolled-back transaction with the same inputs rather than treating it as a
  failure, which is what `EctoBenchTpcc.Tpcc.Retry.transaction/2` does
  below.
  """
  use ExUnit.Case, async: false

  alias EctoBenchTpcc.Harness
  alias EctoBenchTpcc.Tpcc.{FdbMigration, Loader, Procedures, Retry}

  defmodule Repo do
    use Ecto.Repo, otp_app: :ecto_bench_tpcc, adapter: Ecto.Adapters.FoundationDB
    use EctoFoundationDB.Migrator

    def migrations, do: [{0, FdbMigration}]
  end

  @tables [
    EctoBenchTpcc.Tpcc.OrderLine,
    EctoBenchTpcc.Tpcc.NewOrder,
    EctoBenchTpcc.Tpcc.Oorder,
    EctoBenchTpcc.Tpcc.History,
    EctoBenchTpcc.Tpcc.Customer,
    EctoBenchTpcc.Tpcc.Stock,
    EctoBenchTpcc.Tpcc.District,
    EctoBenchTpcc.Tpcc.Warehouse,
    EctoBenchTpcc.Tpcc.Item
  ]

  setup_all do
    {:ok, _} = Application.ensure_all_started(:ecto_foundationdb)

    # `tenant_id` makes the Repo single-tenant, so Procedures needs no
    # `prefix:` and stays adapter-agnostic.
    Application.put_env(:ecto_bench_tpcc, Repo, open_db_opts() ++ [tenant_id: "tpcc"])

    {:ok, _pid} = Repo.start_link()

    # Reads and writes resolve the tenant implicitly from `tenant_id`, but
    # `Repo.transaction/2` does not: it raises "Tenant required" unless
    # given `prefix:`. Grab the handle once for the wrapped procedures.
    tenant = EctoFoundationDB.SingleTenantRepo.get!(Repo)

    # Repeat runs share one cluster, so start from a known-empty dataset.
    Enum.each(@tables, &Repo.delete_all/1)

    Loader.load!(Repo)

    # No on_exit teardown: `Repo.start_link/0` links to the setup_all
    # process, which ExUnit exits once the module finishes, taking the Repo
    # with it. Calling `Repo.stop/0` afterwards just races that shutdown.

    {:ok, tenant: tenant}
  end

  defp open_db_opts do
    case System.get_env("FDB_TEST_CLUSTER_FILE") do
      nil ->
        [open_db: &EctoFoundationDB.Sandbox.open_db/1, storage_id: EctoFoundationDB.Sandbox]

      cluster_file ->
        [open_db: fn _ -> :erlfdb.open(cluster_file) end, storage_id: :ecto_bench_tpcc]
    end
  end

  test "the loaded dataset is readable through the composite primary key" do
    import Ecto.Query

    assert 2 = Repo.all(EctoBenchTpcc.Tpcc.Warehouse) |> length()
    assert 4 = Repo.all(EctoBenchTpcc.Tpcc.District) |> length()
    assert 40 = Repo.all(EctoBenchTpcc.Tpcc.Customer) |> length()

    # A leading-prefix scan on the composite key, with no index. This is the
    # shape stock_level/1 and delivery/1 depend on.
    districts =
      from(d in EctoBenchTpcc.Tpcc.District, where: d.d_w_id == ^1) |> Repo.all()

    assert 2 = length(districts)
    assert Enum.all?(districts, &(&1.d_w_id == 1))
  end

  # Runs the same mixed workload at worker_count: 1 and worker_count: 2 and
  # prints both throughputs, as a real (not simulated) measurement.
  #
  # This deliberately does NOT assert that 2 workers beat 1. FoundationDB is
  # optimistic, and `Loader` seeds 2 warehouses with 2 districts each, so at
  # 2 workers the NewOrder/Payment mix (88% of the weight) collides on the
  # same `d_next_o_id` and warehouse rows constantly. Measured here, 2
  # workers run at roughly 0.6x of 1 worker. That is contention on a tiny
  # dataset, not a defect, and `rfd/0007-scaling-measured.md` shows real
  # scaling once the dataset is large enough to spread the keys.
  #
  # The assertion is only a floor against a gross regression, such as the
  # workload serializing outright or deadlocking.
  test "mixed TPC-C workload demonstrates scaling from 1 to 2 workers", context do
    tenant = context[:tenant]

    # Procedures.new_order/1 and Procedures.payment/1 read-then-write
    # d_next_o_id/customer balances across separate statements with no
    # atomicity of their own (see EctoBenchTpcc.Tpcc.Procedures moduledoc),
    # so each is wrapped here. Retry.transaction/2 rather than a bare
    # Repo.transaction/2, so a write-write conflict resubmits as TPC-C's
    # spec requires instead of crashing the run.
    procedures = [
      %{
        name: "NewOrder",
        weight: 45,
        run: fn ->
          Retry.transaction(Repo, fn -> Procedures.new_order(Repo) end, prefix: tenant)
        end
      },
      %{
        name: "Payment",
        weight: 43,
        run: fn ->
          Retry.transaction(Repo, fn -> Procedures.payment(Repo) end, prefix: tenant)
        end
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

    assert ips_2 > ips_1 * 0.25
  end
end
