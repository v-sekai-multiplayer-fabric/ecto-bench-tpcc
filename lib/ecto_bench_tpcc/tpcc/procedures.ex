defmodule EctoBenchTpcc.Tpcc.Procedures do
  @moduledoc """
  The five standard TPC-C transactions, translated onto a portable subset
  of `Ecto.Query`/`Repo` that works against any real `Ecto.Adapters.SQL`
  adapter. Every function takes `repo` explicitly as its first argument --
  this library has no opinion on which `Ecto.Repo`/adapter it's driving.

  **The TPC-C spec requires NewOrder, Payment, and Delivery to each run as
  a single atomic database transaction** -- e.g. NewOrder's read-then-
  increment of `D_NEXT_O_ID` is only race-free because the whole
  transaction is serialized against other transactions touching the same
  district row. `new_order/1`, `payment/1`, and `delivery/1` each wrap
  their body in `repo.transaction/1` to match that; without it, two
  concurrent `new_order/1` calls for the same district can both read the
  same `d_next_o_id` before either writes back the increment, producing a
  duplicate `o_id` and a unique-constraint violation on OORDER (this is a
  real bug this benchmark hit under real concurrency, not a theoretical
  concern).

  This still depends on `repo`'s adapter actually providing real
  transactions -- if your adapter's `handle_begin/commit/rollback` are
  no-ops (some are; check its own docs), `repo.transaction/1` won't
  protect you, and that gap is the adapter's, not something this module
  can paper over.

  **Concurrent writers can make a transaction fail for reasons that have
  nothing to do with the data** -- e.g. SQLite (this repo's own reference
  adapter, see `test/tpcc_test.exs`) can raise `database is locked` /
  `database busy` when two connections race to become the writer, even
  with a busy-timeout configured, because that's a lock-upgrade conflict
  rather than a plain wait-your-turn lock. The real TPC-C spec expects
  exactly this: a transaction that aborts for contention reasons is meant
  to be retried by the driver, not treated as a workload failure. `retry/1`
  below does that (bounded, so a genuine bug still surfaces as an error
  instead of retrying forever).

  **`stock_level/2` needs `COUNT(DISTINCT s_i_id) ... WHERE s_quantity <
  ?`, which not every `Ecto` adapter's query builder supports** (no
  `GROUP BY`/aggregates is a real gap in some adapters -- e.g.
  `ecto_fdb_relational` as of this writing). Adapted here to a plain
  `Repo.all` fetch of the relevant rows followed by client-side `Enum`
  counting, which works against *any* adapter regardless of aggregate
  support -- a real behavior change from a true database-side aggregate
  (the count happens in the BEAM process, not the database), stated here
  rather than silently assumed equivalent.
  """

  import Ecto.Query

  alias EctoBenchTpcc.Tpcc.Loader

  alias EctoBenchTpcc.Tpcc.{
    Customer,
    District,
    History,
    Item,
    NewOrder,
    Oorder,
    OrderLine,
    Stock,
    Warehouse
  }

  @doc "TPC-C NewOrder: place an order for a random basket of items."
  def new_order(repo) do
    w_id = random(1, Loader.warehouses())
    d_id = random(1, Loader.districts_per_warehouse())
    c_id = random(1, Loader.customers_per_district())
    ol_cnt = random(5, 10)
    now = System.system_time(:millisecond)

    {:ok, :ok} =
      retry(fn ->
        repo.transaction(fn ->
          district = repo.get_by!(District, d_id: d_id, d_w_id: w_id)
          o_id = district.d_next_o_id

          from(d in District, where: d.d_id == ^d_id and d.d_w_id == ^w_id)
          |> repo.update_all(set: [d_next_o_id: o_id + 1])

          repo.insert!(%Oorder{
            o_id: o_id,
            o_d_id: d_id,
            o_w_id: w_id,
            o_c_id: c_id,
            o_entry_d: now,
            o_carrier_id: nil,
            o_ol_cnt: ol_cnt,
            o_all_local: 1
          })

          repo.insert!(%NewOrder{no_o_id: o_id, no_d_id: d_id, no_w_id: w_id})

          for ol_number <- 1..ol_cnt do
            i_id = random(1, Loader.items())
            item = repo.get!(Item, i_id)
            quantity = random(1, 10)

            stock = repo.get_by!(Stock, s_i_id: i_id, s_w_id: w_id)

            new_quantity =
              if stock.s_quantity > quantity,
                do: stock.s_quantity - quantity,
                else: stock.s_quantity + 91

            from(s in Stock, where: s.s_i_id == ^i_id and s.s_w_id == ^w_id)
            |> repo.update_all(set: [s_quantity: new_quantity, s_ytd: stock.s_ytd + quantity])

            repo.insert!(%OrderLine{
              ol_o_id: o_id,
              ol_d_id: d_id,
              ol_w_id: w_id,
              ol_number: ol_number,
              ol_i_id: i_id,
              ol_supply_w_id: w_id,
              ol_delivery_d: nil,
              ol_quantity: quantity,
              ol_amount: quantity * item.i_price,
              ol_dist_info: stock.s_dist_info
            })
          end

          :ok
        end)
      end)

    :ok
  end

  @doc "TPC-C Payment: post a payment, updating warehouse/district/customer YTD and logging it."
  def payment(repo) do
    w_id = random(1, Loader.warehouses())
    d_id = random(1, Loader.districts_per_warehouse())
    c_id = random(1, Loader.customers_per_district())
    amount = random(1, 500) / 1 * 1.0
    now = NaiveDateTime.utc_now()

    {:ok, :ok} =
      retry(fn ->
        repo.transaction(fn ->
          warehouse = repo.get!(Warehouse, w_id)

          from(w in Warehouse, where: w.w_id == ^w_id)
          |> repo.update_all(set: [w_ytd: warehouse.w_ytd + amount])

          district = repo.get_by!(District, d_id: d_id, d_w_id: w_id)

          from(d in District, where: d.d_id == ^d_id and d.d_w_id == ^w_id)
          |> repo.update_all(set: [d_ytd: district.d_ytd + amount])

          customer = repo.get_by!(Customer, c_id: c_id, c_d_id: d_id, c_w_id: w_id)

          from(c in Customer, where: c.c_id == ^c_id and c.c_d_id == ^d_id and c.c_w_id == ^w_id)
          |> repo.update_all(
            set: [
              c_balance: customer.c_balance - amount,
              c_ytd_payment: customer.c_ytd_payment + amount
            ]
          )

          repo.insert!(%History{
            # h_id is HISTORY's real primary key (a UUID surrogate -- see
            # EctoBenchTpcc.Tpcc.Migration's moduledoc for why h_date, real
            # civil time, isn't unique enough to serve as one under real
            # concurrency).
            h_id: Ecto.UUID.generate(),
            h_c_id: c_id,
            h_c_d_id: d_id,
            h_c_w_id: w_id,
            h_d_id: d_id,
            h_w_id: w_id,
            h_date: now,
            h_amount: amount,
            h_data: "payment"
          })

          :ok
        end)
      end)

    :ok
  end

  @doc "TPC-C OrderStatus: read-only lookup of a customer's most recent order and its lines."
  def order_status(repo) do
    w_id = random(1, Loader.warehouses())
    d_id = random(1, Loader.districts_per_warehouse())
    c_id = random(1, Loader.customers_per_district())

    _customer = repo.get_by!(Customer, c_id: c_id, c_d_id: d_id, c_w_id: w_id)

    order =
      from(o in Oorder, where: o.o_c_id == ^c_id and o.o_d_id == ^d_id and o.o_w_id == ^w_id)
      |> repo.all()
      |> List.last()

    if order do
      from(ol in OrderLine,
        where: ol.ol_o_id == ^order.o_id and ol.ol_d_id == ^d_id and ol.ol_w_id == ^w_id
      )
      |> repo.all()
    end

    :ok
  end

  @doc "TPC-C Delivery: deliver the oldest pending new-order in one district of one warehouse."
  def delivery(repo) do
    w_id = random(1, Loader.warehouses())
    d_id = random(1, Loader.districts_per_warehouse())
    now = System.system_time(:millisecond)

    oldest =
      from(no in NewOrder, where: no.no_d_id == ^d_id and no.no_w_id == ^w_id)
      |> repo.all()
      |> Enum.min_by(& &1.no_o_id, fn -> nil end)

    case oldest do
      nil ->
        :ok

      %{no_o_id: o_id} ->
        {:ok, :ok} =
          retry(fn ->
            repo.transaction(fn ->
              from(no in NewOrder,
                where: no.no_o_id == ^o_id and no.no_d_id == ^d_id and no.no_w_id == ^w_id
              )
              |> repo.delete_all()

              from(o in Oorder,
                where: o.o_id == ^o_id and o.o_d_id == ^d_id and o.o_w_id == ^w_id
              )
              |> repo.update_all(set: [o_carrier_id: random(1, 10)])

              from(ol in OrderLine,
                where: ol.ol_o_id == ^o_id and ol.ol_d_id == ^d_id and ol.ol_w_id == ^w_id
              )
              |> repo.update_all(set: [ol_delivery_d: now])

              :ok
            end)
          end)

        :ok
    end
  end

  @doc """
  TPC-C StockLevel: count distinct items in a district's most recent
  orders whose stock has fallen below a threshold. See the moduledoc --
  this counts client-side, not via a database aggregate, so it works
  against any adapter regardless of `GROUP BY`/`COUNT` support.
  """
  def stock_level(repo) do
    w_id = random(1, Loader.warehouses())
    d_id = random(1, Loader.districts_per_warehouse())
    threshold = 50

    item_ids =
      from(ol in OrderLine, where: ol.ol_d_id == ^d_id and ol.ol_w_id == ^w_id)
      |> repo.all()
      |> Enum.map(& &1.ol_i_id)
      |> Enum.uniq()

    low_stock_count =
      item_ids
      |> Enum.map(fn i_id -> repo.get_by(Stock, s_i_id: i_id, s_w_id: w_id) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.count(&(&1.s_quantity < threshold))

    low_stock_count
  end

  defp random(min, max), do: :rand.uniform(max - min + 1) + min - 1

  # Retries `fun` (a 0-arity `repo.transaction/1` call) when it fails for a
  # contention reason (lock/busy conflicts between concurrent writers) --
  # see the moduledoc. Ecto/`ecto_sql` raise on a driver-level SQL error by
  # design (there's no tagged-tuple form to pattern-match on instead), so
  # a `rescue` at the boundary is unavoidable -- but it's confined to
  # `attempt/1` alone, which converts the outcome to a plain tagged tuple
  # immediately. `retry/2`'s own loop is then ordinary `case`-based control
  # flow, not a chain of rescues deciding whether to recurse.
  @max_retries 10
  @never_retry [Ecto.NoResultsError, Ecto.ConstraintError, Ecto.QueryError, ArgumentError]

  defp retry(fun, attempts_left \\ @max_retries)

  defp retry(fun, attempts_left) when attempts_left > 0 do
    case attempt(fun) do
      {:ok, result} -> result
      {:retry, _exception} -> retry(fun, attempts_left - 1)
    end
  end

  defp retry(fun, 0) do
    {:ok, result} = attempt(fun)
    result
  end

  defp attempt(fun) do
    {:ok, fun.()}
  rescue
    e in @never_retry -> reraise e, __STACKTRACE__
    e -> if contention_error?(e), do: {:retry, e}, else: reraise(e, __STACKTRACE__)
  end

  defp contention_error?(exception) do
    message = Exception.message(exception)
    String.contains?(message, "locked") or String.contains?(message, "busy")
  end
end
