defmodule EctoBenchTpcc.Tpcc.Loader do
  @moduledoc """
  Seeds the official TPC-C minimum dataset for scale factor `warehouses`
  (W) per `rfd/0001-tpcc-scaling.md`'s cardinality table: 10 districts/
  warehouse, 3,000 customers/district, 3,000 orders/district (the last
  900 undelivered), ~5-15 (loaded as a fixed 5, per spec 4.3.3.1) order
  lines/order, and a shared, W-independent 100,000-row `ITEM` catalog.
  `W = 1` alone is already ~600,000 rows -- see the moduledoc's "Timing"
  note below before running this against a fresh cluster.

  Every function here takes `repo` explicitly -- this library has no
  opinion on which `Ecto.Repo`/adapter it's driving.

  ## What's still approximate

  This matches the spec's table *cardinalities* and its NURand-driven
  `C_LAST`/`C_ID`/`OL_I_ID` selection (see `EctoBenchTpcc.Tpcc.NURand`),
  but not every population/runtime detail:

  * No "terminal-to-warehouse/district" binding (spec: each of the 10W
    terminals is pinned to one home warehouse/district for the whole
    run) -- `Procedures`/`Harness` still pick warehouse/district uniformly
    at random per call, same as before.
  * No by-name customer lookup (spec: 60% of Payment/OrderStatus customer
    lookups are by `C_LAST`, not `C_ID`) -- `Procedures` always looks up
    by `C_ID`.
  * No 1% "invalid item" NewOrder rollback simulation, no 1%
    remote-supplying-warehouse `OL_SUPPLY_W_ID` (only matters once
    `warehouses > 1` anyway).
  * `C_CREDIT` ("GC"/"BC") is drawn independently per customer with ~10%
    probability, not an exact 10%-of-rows selection.

  Stated here rather than silently assumed equivalent to a full BenchBase
  loader -- table shape and NURand distribution are the parts that
  actually affect the workload's contention pattern, which is this
  project's own point of existing.

  ## Timing

  Every row here is one `Repo.insert!/1` -- this adapter (like most real
  `Ecto.Adapters.SQL` adapters) has no bulk-insert path, but *does* have
  real `Repo.transaction/2` batching (see `ecto_fdb_relational`'s
  CHANGELOG), so `insert_batched!/2` chunks rows into transactions of
  `@batch_size` instead of one autocommit statement per row -- cutting
  *commit* round-trips by ~`@batch_size`x.

  `@batch_size` is also capped by FDB's own hard 5-second transaction
  lifetime (`"Transaction is too old to perform reads or be committed"`
  past that) -- 100 statements/transaction stays comfortably under that at
  this adapter's observed per-statement latency, but is still a
  real-world-measured margin, not a spec guarantee; a much slower cluster
  could still need a smaller batch.

  Batches for independent row ranges (chunks within one table, and whole
  districts within a warehouse -- districts don't share any rows) run
  concurrently via `Task.async_stream/3`, capped at `@load_concurrency`.
  This is the same "connection pooling"/statement-pipelining latitude
  real benchmark rules (e.g. TechEmpower's database test requirements)
  treat as ordinary, not a shortcut around what's being measured: it
  speeds up *loading* the fixed dataset, not the transactional workload
  itself, and every row still goes through its own real `Repo.insert!/1`
  and FDB commit -- nothing is coalesced, cached, or skipped. Needs
  `Repo`'s `:pool_size` to be at least `@load_concurrency` to actually
  achieve that concurrency (a smaller pool just queues checkouts, which
  works too, just slower). Sequential, this was measured at ~48
  rows/sec against a real cluster -- multiple hours for a full `W = 1`
  load; concurrent, low tens of minutes.
  """

  alias EctoBenchTpcc.Tpcc.Migration

  alias EctoBenchTpcc.Tpcc.{
    Config,
    Customer,
    District,
    History,
    Item,
    NewOrder,
    NURand,
    Oorder,
    OrderLine,
    Retry,
    Stock,
    Warehouse
  }

  @items 100_000
  @districts_per_warehouse 10
  @customers_per_district 3_000
  @orders_per_district 3_000
  @new_orders_per_district 900

  @batch_size 100
  @load_concurrency 16

  def warehouses, do: Config.warehouses()
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

  Call this against a `repo` with a **small** pool (`Ecto.Migrator.with_repo/3`
  itself defaults to `pool_size: 2` for exactly this reason, see its
  `@moduledoc`): several connections all establishing at once makes this
  adapter's DDL bootstrap noticeably more likely to hit a transient FDB
  conflict than one connection does (measured directly against a real
  cluster) -- a large pool belongs to `load!/2`'s concurrent inserts
  (plain DML, no DDL-bootstrap races), not to this step. See
  `test/tpcc_test.exs` for the two-pool-size pattern this implies:
  migrate with a small pool, stop, restart with a bigger one, load.
  """
  def migrate!(repo) do
    Ecto.Migrator.up(repo, 0, Migration)
    :ok
  end

  @doc """
  Seeds the dataset described in the moduledoc into `repo` at scale
  factor `warehouses` (`opts[:warehouses]`, default `1` -- the spec's own
  minimum). Generates one set of `EctoBenchTpcc.Tpcc.NURand` run-constants
  and stashes them (with `warehouses`) in `EctoBenchTpcc.Tpcc.Config`,
  which `Procedures` reads for the rest of the run -- both must stay
  fixed for the whole run per TPC-C spec 2.1.6.
  """
  def load!(repo, opts \\ []) do
    warehouses = Keyword.get(opts, :warehouses, 1)
    nurand = NURand.new()
    Config.put(warehouses, nurand)

    load_items!(repo)

    for w_id <- 1..warehouses do
      load_warehouse!(repo, w_id, nurand)
    end

    :ok
  end

  defp load_items!(repo) do
    1..@items
    |> Enum.map(fn i_id ->
      %Item{
        i_id: i_id,
        i_im_id: random(1, 10_000),
        i_name: random_astring(14, 24),
        i_price: random(100, 10_000) / 100.0,
        i_data: random_original_data(26, 50)
      }
    end)
    |> insert_batched!(repo)
  end

  defp load_warehouse!(repo, w_id, nurand) do
    repo.insert!(%Warehouse{
      w_id: w_id,
      w_name: random_astring(6, 10),
      w_tax: random(0, 2000) / 10_000.0,
      w_ytd: 300_000.0
    })

    1..@items
    |> Enum.map(fn i_id ->
      %Stock{
        s_i_id: i_id,
        s_w_id: w_id,
        s_quantity: random(10, 100),
        s_dist_info: random_astring(24, 24),
        s_ytd: 0.0,
        s_order_cnt: 0,
        s_remote_cnt: 0,
        s_data: random_original_data(26, 50)
      }
    end)
    |> insert_batched!(repo)

    # Districts are fully independent (no shared rows) -- see moduledoc's
    # "Timing" section for why this runs them concurrently.
    1..@districts_per_warehouse
    |> Task.async_stream(&load_district!(repo, w_id, &1, nurand),
      max_concurrency: min(@load_concurrency, @districts_per_warehouse),
      timeout: :infinity
    )
    |> Enum.each(fn {:ok, :ok} -> :ok end)
  end

  defp load_district!(repo, w_id, d_id, nurand) do
    repo.insert!(%District{
      d_id: d_id,
      d_w_id: w_id,
      d_name: random_astring(6, 10),
      d_tax: random(0, 2000) / 10_000.0,
      d_ytd: 30_000.0,
      d_next_o_id: @orders_per_district + 1
    })

    1..@customers_per_district
    |> Enum.map(fn c_id ->
      %Customer{
        c_id: c_id,
        c_d_id: d_id,
        c_w_id: w_id,
        c_first: random_astring(8, 16),
        c_last: NURand.last_name(nurand, c_id),
        c_credit: if(random(1, 10) == 1, do: "BC", else: "GC"),
        c_credit_lim: 50_000.0,
        c_discount: random(0, 5000) / 10_000.0,
        c_balance: -10.0,
        c_ytd_payment: 10.0
      }
    end)
    |> insert_batched!(repo)

    1..@customers_per_district
    |> Enum.map(fn c_id ->
      %History{
        h_id: Ecto.UUID.generate(),
        h_c_id: c_id,
        h_c_d_id: d_id,
        h_c_w_id: w_id,
        h_d_id: d_id,
        h_w_id: w_id,
        h_date: NaiveDateTime.utc_now(),
        h_amount: 10.0,
        h_data: random_astring(12, 24)
      }
    end)
    |> insert_batched!(repo)

    orders = build_orders(w_id, d_id)
    insert_batched!(orders, repo)

    orders
    |> Enum.filter(&undelivered?/1)
    |> Enum.map(fn %{o_id: o_id} -> %NewOrder{no_o_id: o_id, no_d_id: d_id, no_w_id: w_id} end)
    |> insert_batched!(repo)

    orders
    |> Enum.flat_map(&build_order_lines(&1, w_id, d_id))
    |> insert_batched!(repo)
  end

  # ORDER's O_C_ID is a random permutation of 1..customers_per_district
  # across the district's orders, not the identity o_id == c_id -- per
  # spec 4.3.3.1, so every customer gets exactly one order but not
  # necessarily the one matching their own id.
  defp build_orders(w_id, d_id) do
    now = System.system_time(:millisecond)
    delivered_cutoff = @orders_per_district - @new_orders_per_district

    1..@orders_per_district
    |> Enum.zip(Enum.shuffle(1..@customers_per_district))
    |> Enum.map(fn {o_id, c_id} ->
      %Oorder{
        o_id: o_id,
        o_d_id: d_id,
        o_w_id: w_id,
        o_c_id: c_id,
        o_entry_d: now,
        o_carrier_id: if(o_id <= delivered_cutoff, do: random(1, 10), else: nil),
        o_ol_cnt: random(5, 15),
        o_all_local: 1
      }
    end)
  end

  # The last @new_orders_per_district orders/district are undelivered
  # ("new") at load time -- build_orders/2 already encodes that as
  # o_carrier_id: nil, so this is just reading that back.
  defp undelivered?(%Oorder{o_carrier_id: nil}), do: true
  defp undelivered?(%Oorder{}), do: false

  defp build_order_lines(%Oorder{} = order, w_id, d_id) do
    delivered = order.o_carrier_id != nil

    for ol_number <- 1..order.o_ol_cnt do
      %OrderLine{
        ol_o_id: order.o_id,
        ol_d_id: d_id,
        ol_w_id: w_id,
        ol_number: ol_number,
        ol_i_id: random(1, @items),
        ol_supply_w_id: w_id,
        ol_delivery_d: if(delivered, do: order.o_entry_d, else: nil),
        # Fixed at load time per spec 4.3.3.1 -- only NewOrder transactions
        # during the run vary this 1..10.
        ol_quantity: 5,
        ol_amount: if(delivered, do: 0.0, else: random(1, 999_999) / 100.0),
        ol_dist_info: random_astring(24, 24)
      }
    end
  end

  # Batches `rows` into repo.transaction/2 chunks of @batch_size instead
  # of one autocommit statement per row, running independent chunks
  # concurrently -- see the moduledoc's "Timing" section. Retry.transaction/2
  # (not a bare repo.transaction/2) so a transient conflict during a long
  # load restarts just that one chunk, not the whole run.
  defp insert_batched!(rows, repo) do
    rows
    |> Enum.chunk_every(@batch_size)
    |> Task.async_stream(
      fn chunk ->
        {:ok, _} =
          Retry.transaction(repo, fn -> Enum.each(chunk, &repo.insert!/1) end, timeout: :infinity)
      end,
      max_concurrency: @load_concurrency,
      timeout: :infinity
    )
    |> Enum.each(fn {:ok, {:ok, _}} -> :ok end)

    :ok
  end

  defp random(min, max), do: :rand.uniform(max - min + 1) + min - 1

  @astring_chars Enum.to_list(?a..?z) ++ Enum.to_list(?A..?Z)

  defp random_astring(min_len, max_len) do
    len = random(min_len, max_len)
    for _ <- 1..len, into: "", do: <<Enum.random(@astring_chars)>>
  end

  # ~10% of ITEM/STOCK rows embed the literal "ORIGINAL" substring in
  # their _DATA field per spec 4.3.3.1 (a "brand item" marker some
  # implementations use for NewOrder's brand-generic pricing rule -- not
  # exercised by this repo's own Procedures yet, see moduledoc).
  defp random_original_data(min_len, max_len) do
    data = random_astring(min_len, max_len)

    if random(1, 10) == 1 do
      pos = random(0, byte_size(data) - 8)
      {before, rest} = String.split_at(data, pos)
      {_replaced, after_} = String.split_at(rest, 8)
      before <> "ORIGINAL" <> after_
    else
      data
    end
  end
end
