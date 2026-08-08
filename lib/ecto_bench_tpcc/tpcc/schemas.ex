defmodule EctoBenchTpcc.Tpcc.Warehouse do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:w_id, :integer, autogenerate: false}
  schema "warehouse" do
    field(:w_name, :string)
    field(:w_tax, :float)
    field(:w_ytd, :float)
  end
end

defmodule EctoBenchTpcc.Tpcc.District do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "district" do
    field(:d_w_id, :integer, primary_key: true)
    field(:d_id, :integer, primary_key: true)
    field(:d_name, :string)
    field(:d_tax, :float)
    field(:d_ytd, :float)
    field(:d_next_o_id, :integer)
  end
end

defmodule EctoBenchTpcc.Tpcc.Customer do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "customer" do
    field(:c_w_id, :integer, primary_key: true)
    field(:c_d_id, :integer, primary_key: true)
    field(:c_id, :integer, primary_key: true)
    field(:c_first, :string)
    field(:c_last, :string)
    field(:c_credit, :string)
    field(:c_credit_lim, :float)
    field(:c_discount, :float)
    field(:c_balance, :float)
    field(:c_ytd_payment, :float)
  end
end

defmodule EctoBenchTpcc.Tpcc.History do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:h_id, :string, autogenerate: false}
  schema "history" do
    field(:h_c_id, :integer)
    field(:h_c_d_id, :integer)
    field(:h_c_w_id, :integer)
    field(:h_d_id, :integer)
    field(:h_w_id, :integer)
    field(:h_date, :naive_datetime_usec)
    field(:h_amount, :float)
    field(:h_data, :string)
  end
end

defmodule EctoBenchTpcc.Tpcc.Oorder do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "oorder" do
    field(:o_w_id, :integer, primary_key: true)
    field(:o_d_id, :integer, primary_key: true)
    field(:o_id, :integer, primary_key: true)
    field(:o_c_id, :integer)
    field(:o_entry_d, :integer)
    field(:o_carrier_id, :integer)
    field(:o_ol_cnt, :integer)
    field(:o_all_local, :integer)
  end
end

defmodule EctoBenchTpcc.Tpcc.NewOrder do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "new_order" do
    field(:no_w_id, :integer, primary_key: true)
    field(:no_d_id, :integer, primary_key: true)
    field(:no_o_id, :integer, primary_key: true)
  end
end

defmodule EctoBenchTpcc.Tpcc.OrderLine do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "order_line" do
    field(:ol_w_id, :integer, primary_key: true)
    field(:ol_d_id, :integer, primary_key: true)
    field(:ol_o_id, :integer, primary_key: true)
    field(:ol_number, :integer, primary_key: true)
    field(:ol_i_id, :integer)
    field(:ol_supply_w_id, :integer)
    field(:ol_delivery_d, :integer)
    field(:ol_quantity, :integer)
    field(:ol_amount, :float)
    field(:ol_dist_info, :string)
  end
end

defmodule EctoBenchTpcc.Tpcc.Item do
  @moduledoc false
  use Ecto.Schema

  @primary_key {:i_id, :integer, autogenerate: false}
  schema "item" do
    field(:i_im_id, :integer)
    field(:i_name, :string)
    field(:i_price, :float)
    field(:i_data, :string)
  end
end

defmodule EctoBenchTpcc.Tpcc.Stock do
  @moduledoc false
  use Ecto.Schema

  @primary_key false
  schema "stock" do
    field(:s_w_id, :integer, primary_key: true)
    field(:s_i_id, :integer, primary_key: true)
    field(:s_quantity, :integer)
    field(:s_dist_info, :string)
    field(:s_ytd, :float)
    field(:s_order_cnt, :integer)
    field(:s_remote_cnt, :integer)
    field(:s_data, :string)
  end
end
