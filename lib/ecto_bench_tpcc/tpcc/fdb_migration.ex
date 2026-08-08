defmodule EctoBenchTpcc.Tpcc.FdbMigration do
  @moduledoc """
  `EctoFoundationDB.Migration` for the TPC-C schemas.

  `Ecto.Adapters.FoundationDB` accepts a query only when one Get or one
  GetRange satisfies it. A `where` clause therefore has to constrain
  either the primary key or a set of fields that an index covers.

  TPC-C originally keyed every table on a composite primary key.
  `EctoBenchTpcc.Tpcc.Schemas` now gives those tables one synthetic
  `:binary_id` primary key, and the former key fields carry their
  meaning through the indexes below.

  Field order is load-bearing. FoundationDB stores keys in sorted
  order, so an index on `[:d_w_id, :d_id]` also answers a query that
  constrains `:d_w_id` alone. That prefix property is why the warehouse
  id leads every index here: `stock_level/1` queries `order_line` by
  warehouse and district, while `delivery/1` queries the same table by
  warehouse, district and order.

  `oorder` needs two indexes rather than one. `order_status/1` looks up
  by customer, and `delivery/1` looks up by order id, so the third field
  differs and one index cannot serve both.
  """
  use EctoFoundationDB.Migration

  alias EctoBenchTpcc.Tpcc.Schemas.Customer
  alias EctoBenchTpcc.Tpcc.Schemas.District
  alias EctoBenchTpcc.Tpcc.Schemas.NewOrder
  alias EctoBenchTpcc.Tpcc.Schemas.Oorder
  alias EctoBenchTpcc.Tpcc.Schemas.OrderLine
  alias EctoBenchTpcc.Tpcc.Schemas.Stock

  @impl true
  def change do
    [
      # new_order/1 and payment/1: one district of one warehouse
      create(index(District, [:d_w_id, :d_id])),

      # new_order/1 and stock_level/1: one item's stock in one warehouse
      create(index(Stock, [:s_w_id, :s_i_id])),

      # payment/1: one customer
      create(index(Customer, [:c_w_id, :c_d_id, :c_id])),

      # order_status/1 reads by customer, delivery/1 reads by order id
      create(index(Oorder, [:o_w_id, :o_d_id, :o_c_id])),
      create(index(Oorder, [:o_w_id, :o_d_id, :o_id])),

      # delivery/1 scans a district for the oldest, then deletes by id.
      # The prefix property serves both from one index.
      create(index(NewOrder, [:no_w_id, :no_d_id, :no_o_id])),

      # stock_level/1 scans by district, delivery/1 updates by order.
      # Prefix property again.
      create(index(OrderLine, [:ol_w_id, :ol_d_id, :ol_o_id]))
    ]
  end
end
