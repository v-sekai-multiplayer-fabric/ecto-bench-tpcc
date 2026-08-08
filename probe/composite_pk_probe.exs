Mix.install([{:ecto_foundationdb, "~> 0.7"}])

defmodule R do
  use Ecto.Repo, otp_app: :probe, adapter: Ecto.Adapters.FoundationDB
  use EctoFoundationDB.Migrator
  def migrations, do: [{0, Mig}]
end

defmodule District do
  use Ecto.Schema
  @primary_key false
  schema "district" do
    field(:d_id, :integer, primary_key: true)
    field(:d_w_id, :integer, primary_key: true)
    field(:d_next_o_id, :integer)
  end
end

defmodule Warehouse do
  use Ecto.Schema
  @primary_key {:w_id, :integer, autogenerate: false}
  schema "warehouse" do
    field(:w_ytd, :integer)
  end
end

defmodule Mig do
  use EctoFoundationDB.Migration
  def change, do: []
end

defmodule Run do
  import Ecto.Query

  defp try_it(label, fun) do
    try do
      IO.puts("PROBE #{label}: #{inspect(fun.())}")
    rescue
      e -> IO.puts("PROBE #{label}: RAISED #{inspect(e.__struct__)} -- #{Exception.message(e)}")
    end
  end

  def go do
    {:ok, _} = Application.ensure_all_started(:ecto_foundationdb)
    Application.put_env(:probe, R, open_db: fn _ -> :erlfdb.open() end, storage_id: :tpcc_probe, migrator: Mig)
    {:ok, _} = R.start_link()
    t = EctoFoundationDB.Tenant.open!(R, "tpcc")
    IO.puts("PROBE tenant: opened")
    try_it("single-PK insert", fn -> R.insert(struct(Warehouse, %{w_id: 1, w_ytd: 300}), prefix: t) |> elem(0) end)
    try_it("composite-PK insert", fn -> R.insert(struct(District, %{d_id: 1, d_w_id: 1, d_next_o_id: 3001}), prefix: t) |> elem(0) end)
    try_it("composite-PK query", fn -> R.all(from(d in District, where: d.d_id == ^1 and d.d_w_id == ^1), prefix: t) |> length() end)
    try_it("single-PK get", fn -> R.get(Warehouse, 1, prefix: t) != nil end)
  end
end

Run.go()
