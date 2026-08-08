defmodule EctoBenchTpcc.Tpcc.FdbMigration do
  @moduledoc """
  `EctoFoundationDB.Migration` for the TPC-C schemas.

  `Ecto.Adapters.FoundationDB` accepts a query only when one Get or one
  GetRange satisfies it. Every table here keeps TPC-C's natural composite
  primary key, whose fields the adapter stores as separate elements of the
  FDB key tuple, in the order `EctoBenchTpcc.Tpcc.Schemas` declares them.
  FoundationDB keeps keys sorted, so a query constraining a *leading
  prefix* of the key is one GetRange and needs no index.

  That is why this declares one index rather than seven. The key fields
  lead with the warehouse id, matching TPC-C's own order (`ORDER-LINE` is
  `(OL_W_ID, OL_D_ID, OL_O_ID, OL_NUMBER)`), so `delivery/1` and
  `stock_level/1` scan by warehouse and district on the key alone.
  Reordering those fields in the schema would silently break those scans.
  `order_status/1` is the exception: it looks up `oorder` by customer, and
  `o_c_id` is not a key field.
  """
  use EctoFoundationDB.Migration

  alias EctoBenchTpcc.Tpcc.Oorder

  @impl true
  def change do
    [create(index(Oorder, [:o_w_id, :o_d_id, :o_c_id]))]
  end
end
