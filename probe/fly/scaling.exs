# Scaling probe: throughput of the TPC-C read-modify-write shape against
# one FoundationDB cluster, with concurrency as the independent variable.
#
# Each worker runs the NewOrder-shaped operation: read one district
# through its index, bump d_next_o_id, write it back, all in one
# Repo.transactional/2. That is the contended path in TPC-C, so it is
# the one that shows whether throughput scales or collapses.
#
# Districts are spread over WAREHOUSES so workers mostly touch
# different keys. FoundationDB aborts a transaction on write conflict,
# and the retry is counted, so contention is visible rather than hidden.
Mix.install([{:ecto_foundationdb, "~> 0.7"}])

defmodule R do
  use Ecto.Repo, otp_app: :probe, adapter: Ecto.Adapters.FoundationDB
  use EctoFoundationDB.Migrator
  def migrations, do: [{0, Mig}]
end

defmodule District do
  use Ecto.Schema
  @primary_key {:id, :binary_id, autogenerate: true}
  schema "district" do
    field(:d_id, :integer)
    field(:d_w_id, :integer)
    field(:d_next_o_id, :integer)
  end
end

defmodule Mig do
  use EctoFoundationDB.Migration
  def change, do: [create(index(District, [:d_w_id, :d_id]))]
end

defmodule Probe do
  import Ecto.Query

  @warehouses 100
  @districts 10
  @seconds 10

  def go do
    {:ok, _} = Application.ensure_all_started(:ecto_foundationdb)
    cluster = System.get_env("FDB_CLUSTER_FILE", "/etc/foundationdb/fdb.cluster")
    Application.put_env(:probe, R, open_db: fn _ -> :erlfdb.open(cluster) end, storage_id: :tpcc_scale)
    {:ok, _} = R.start_link()
    tn = EctoFoundationDB.Tenant.open!(R, "scale")

    load(tn)

    IO.puts("concurrency,ops,aborts,seconds,ops_per_sec")
    for c <- [1, 2, 4, 8, 16, 32] do
      {ops, aborts, secs} = run(tn, c)
      IO.puts("#{c},#{ops},#{aborts},#{Float.round(secs, 2)},#{Float.round(ops / secs, 1)}")
    end
  end

  defp load(tn) do
    existing = R.all(from(d in District, where: d.d_w_id == ^1), prefix: tn)

    if existing == [] do
      for w <- 1..@warehouses do
        R.transactional(tn, fn ->
          for d <- 1..@districts do
            R.insert!(struct(District, %{d_id: d, d_w_id: w, d_next_o_id: 3001}))
          end
        end)
      end
    end
  end

  defp run(tn, concurrency) do
    t0 = System.monotonic_time(:millisecond)
    deadline = t0 + @seconds * 1000

    results =
      1..concurrency
      |> Task.async_stream(fn _ -> worker(tn, deadline, 0, 0) end,
           max_concurrency: concurrency, timeout: :infinity)
      |> Enum.map(fn {:ok, r} -> r end)

    secs = (System.monotonic_time(:millisecond) - t0) / 1000
    {Enum.sum(Enum.map(results, &elem(&1, 0))), Enum.sum(Enum.map(results, &elem(&1, 1))), secs}
  end

  defp worker(tn, deadline, ops, aborts) do
    if System.monotonic_time(:millisecond) >= deadline do
      {ops, aborts}
    else
      w = :rand.uniform(@warehouses)
      d = :rand.uniform(@districts)

      try do
        R.transactional(tn, fn ->
          [x] = R.all(from(y in District, where: y.d_w_id == ^w and y.d_id == ^d))
          R.update!(Ecto.Changeset.change(x, d_next_o_id: x.d_next_o_id + 1))
        end)

        worker(tn, deadline, ops + 1, aborts)
      rescue
        _ -> worker(tn, deadline, ops, aborts + 1)
      end
    end
  end
end

Probe.go()
