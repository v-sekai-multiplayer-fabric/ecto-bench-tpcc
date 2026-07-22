defmodule EctoBenchTpcc.Tpcc.Loader do
  @moduledoc """
  Seeds a small, fixed TPC-C dataset -- enough for the workload in
  `EctoBenchTpcc.Tpcc.Procedures` to have real rows to contend over. This
  is **not yet** a scale-factor-accurate TPC-C dataset generator matching
  BenchBase's own loader (proportional warehouses/districts/customers/
  items driven by a configurable scale factor, skewed random selection,
  etc. -- see `rfd/0001-tpcc-scaling.md`) -- reproducing that faithfully
  *is* the eventual point of this port, just not done in this first cut.
  Proving the workload executes correctly came first; matching
  BenchBase's real load-generation fidelity is follow-up work, not
  something dismissed as out of scope.

  Every function here takes `repo` explicitly -- this library has no
  opinion on which `Ecto.Repo`/adapter it's driving.
  """

  alias EctoBenchTpcc.Tpcc.Migration
  alias EctoBenchTpcc.Tpcc.{Customer, District, Item, Stock, Warehouse}

  @warehouses 2
  @districts_per_warehouse 2
  @customers_per_district 10
  @items 20

  def warehouses, do: @warehouses
  def districts_per_warehouse, do: @districts_per_warehouse
  def customers_per_district, do: @customers_per_district
  def items, do: @items

  @doc """
  Runs `EctoBenchTpcc.Tpcc.Migration` against `repo` -- via
  `Ecto.Migrator.up/4`, which accepts a migration module directly, so
  callers don't need to copy a migration file into their own
  `priv/repo/migrations/`. Safe to call repeatedly: `Ecto.Migrator`
  tracks applied versions in its own `schema_migrations` table and skips
  already-applied ones (version `0` here, since this isn't meant to
  compose with a caller's own real migration history).
  """
  def migrate!(repo) do
    Ecto.Migrator.up(repo, 0, Migration)
    :ok
  end

  @doc "Seeds the fixed-size dataset described in the moduledoc into `repo`."
  def load!(repo) do
    Enum.each(1..@items, fn i_id ->
      repo.insert!(%Item{
        i_id: i_id,
        i_im_id: i_id,
        i_name: "item#{i_id}",
        i_price: 9.99,
        i_data: "data"
      })
    end)

    for w_id <- 1..@warehouses do
      repo.insert!(%Warehouse{w_id: w_id, w_name: "W#{w_id}", w_tax: 0.05, w_ytd: 0.0})

      for i_id <- 1..@items do
        repo.insert!(%Stock{
          s_i_id: i_id,
          s_w_id: w_id,
          s_quantity: 100,
          s_dist_info: "dist",
          s_ytd: 0.0,
          s_order_cnt: 0,
          s_remote_cnt: 0,
          s_data: "data"
        })
      end

      for d_id <- 1..@districts_per_warehouse do
        repo.insert!(%District{
          d_id: d_id,
          d_w_id: w_id,
          d_name: "D#{d_id}",
          d_tax: 0.04,
          d_ytd: 0.0,
          d_next_o_id: 1
        })

        for c_id <- 1..@customers_per_district do
          repo.insert!(%Customer{
            c_id: c_id,
            c_d_id: d_id,
            c_w_id: w_id,
            c_first: "First#{c_id}",
            c_last: "Last#{c_id}",
            c_credit: "GC",
            c_credit_lim: 50_000.0,
            c_discount: 0.1,
            c_balance: -10.0,
            c_ytd_payment: 10.0
          })
        end
      end
    end

    :ok
  end
end
