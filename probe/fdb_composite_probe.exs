# Probe: run the real TPC-C procedures against ecto_foundationdb using
# TPC-C's own composite natural primary keys, with no synthetic key.
# Released 0.7.6 raises MatchError on those, so mix.exs pins a fork.
#
#     MIX_ENV=dev mix run probe/fdb_composite_probe.exs

alias EctoBenchTpcc.Tpcc.Loader
alias EctoBenchTpcc.Tpcc.Procedures

defmodule Probe.Repo do
  use Ecto.Repo, otp_app: :ecto_bench_tpcc, adapter: Ecto.Adapters.FoundationDB
  use EctoFoundationDB.Migrator

  def migrations, do: [{0, EctoBenchTpcc.Tpcc.FdbMigration}]
end

defmodule Probe do
  def go do
    {:ok, _} = Application.ensure_all_started(:ecto_foundationdb)

    # tenant_id makes the Repo single-tenant, so Procedures needs no `prefix:`.
    Application.put_env(:ecto_bench_tpcc, Probe.Repo,
      open_db: &EctoFoundationDB.Sandbox.open_db/1,
      storage_id: EctoFoundationDB.Sandbox,
      tenant_id: "tpcc",
      migrator: Probe.Repo
    )

    {:ok, _} = Probe.Repo.start_link()

    # No Loader.migrate!/1: FoundationDB has no DDL.
    Probe.Repo.delete_all(EctoBenchTpcc.Tpcc.OrderLine)
    Probe.Repo.delete_all(EctoBenchTpcc.Tpcc.NewOrder)
    Probe.Repo.delete_all(EctoBenchTpcc.Tpcc.Oorder)
    Probe.Repo.delete_all(EctoBenchTpcc.Tpcc.Customer)
    Probe.Repo.delete_all(EctoBenchTpcc.Tpcc.Stock)
    Probe.Repo.delete_all(EctoBenchTpcc.Tpcc.District)
    Probe.Repo.delete_all(EctoBenchTpcc.Tpcc.Warehouse)
    Probe.Repo.delete_all(EctoBenchTpcc.Tpcc.Item)
    Probe.Repo.delete_all(EctoBenchTpcc.Tpcc.History)

    Loader.load!(Probe.Repo)
    IO.puts("PROBE load: ok")

    for {name, fun} <- [
          {"NewOrder", &Procedures.new_order/1},
          {"Payment", &Procedures.payment/1},
          {"OrderStatus", &Procedures.order_status/1},
          {"Delivery", &Procedures.delivery/1},
          {"StockLevel", &Procedures.stock_level/1}
        ] do
      try do
        Enum.each(1..20, fn _ -> fun.(Probe.Repo) end)
        IO.puts("PROBE #{name}: ok (20 iterations)")
      rescue
        e -> IO.puts("PROBE #{name}: RAISED #{inspect(e.__struct__)} -- #{Exception.message(e)}")
      end
    end

    # "No exception" is not "found the rows": a prefix scan matching nothing
    # would look identical above. Count what the workload actually wrote.
    import Ecto.Query

    counts =
      for {label, queryable} <- [
            {"warehouse", EctoBenchTpcc.Tpcc.Warehouse},
            {"district", EctoBenchTpcc.Tpcc.District},
            {"customer", EctoBenchTpcc.Tpcc.Customer},
            {"stock", EctoBenchTpcc.Tpcc.Stock},
            {"oorder", EctoBenchTpcc.Tpcc.Oorder},
            {"order_line", EctoBenchTpcc.Tpcc.OrderLine}
          ] do
        {label, Probe.Repo.all(queryable) |> length()}
      end

    IO.puts("PROBE rows: #{inspect(counts)}")

    # The leading-prefix scan stock_level/1 and delivery/1 depend on.
    w1 =
      from(ol in EctoBenchTpcc.Tpcc.OrderLine, where: ol.ol_w_id == ^1 and ol.ol_d_id == ^1)
      |> Probe.Repo.all()

    IO.puts(
      "PROBE prefix scan order_line(w=1,d=1): #{length(w1)} rows, " <>
        "all match: #{Enum.all?(w1, &(&1.ol_w_id == 1 and &1.ol_d_id == 1))}"
    )
  end
end

Probe.go()
