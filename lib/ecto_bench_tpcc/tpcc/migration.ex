defmodule EctoBenchTpcc.Tpcc.Migration do
  @moduledoc """
  The standard TPC-C schema (per `weftspun/scenario-tpcc-bench` PR #12's
  own `FdbRelSchemaBootstrap`, itself a type-mapped port of BenchBase's
  stock `benchmarks/tpcc/ddl-generic.sql`), as a portable `Ecto.Migration`.

  This is the whole point of splitting `ecto_bench_tpcc` out of
  `ecto-fdb-relational`: an Ecto adapter is inherently
  database-specific, but a `Repo.insert`/`Repo.update_all`/`Repo.all`-based
  TPC-C workload, and the `Ecto.Migration` that creates its schema, are
  not -- any real `Ecto.Adapters.SQL`-based adapter (Postgres, MySQL,
  `ecto_sqlite3`, `ecto_fdb_relational`, ...) translates the same
  `create table`/`add` calls into its own DDL dialect. Each adapter's own
  migration/DDL layer is responsible for whatever type mapping it needs
  (e.g. `ecto_fdb_relational`'s `EctoFdbRelational.Types.ddl_type/1`
  already maps `:float` -> `DOUBLE`, `:utc_datetime` -> `BIGINT`, etc.).

  One deliberate simplification from the standard TPC-C schema: `STOCK`'s
  ten `s_dist_01`..`s_dist_10` columns collapse to a single `s_dist_info`
  column here. The real schema carries ten because each is per-district
  shipping text picked by `ORDER_LINE.ol_dist_info`; the workload's actual
  transactional shape (contention/read-write ratios on `STOCK`) doesn't
  depend on which or how many per-district text columns exist, so this
  keeps the schema smaller without changing what's being measured.
  Documented here rather than silently ported as if it were the full
  schema.

  `HISTORY` has no natural primary key in the standard schema (it's an
  append-only log) -- `h_date` (per standard TPC-C, genuinely "date and
  time when the payment occurred," not an identifier) isn't unique
  enough to serve as one under real concurrency: an earlier version of
  this schema keyed `HISTORY` on all its columns plus `h_date` at
  millisecond precision, and two `Payment` calls for the same customer/
  district in the same millisecond reliably collided against a real
  SQLite database (which enforces the unique index that composite key
  creates, unlike some other backends that may not even notice). Some
  adapters (e.g. FRL, via `ecto_fdb_relational`) require every table to
  declare a primary key regardless, so `h_id` -- a real UUID
  (`Ecto.UUID.generate/0`, see
  `EctoBenchTpcc.Tpcc.Procedures.payment/1`) -- is the sole primary key
  here: a genuine surrogate key, not an overloaded timestamp, leaving
  `h_date` free to hold real civil time as the spec intends.

  ## Usage

  Not a real numbered migration file (no `up`/`down`/version) --
  `EctoBenchTpcc.Tpcc.Loader.bootstrap!/1` calls `change/0` directly via
  `Ecto.Migration.Runner`, matching how a caller would normally run
  `mix ecto.migrate` against their own migrations directory, except
  without needing this repo's callers to copy a migration file into
  their own `priv/repo/migrations/`.
  """
  use Ecto.Migration

  def change do
    create table(:warehouse, primary_key: false) do
      add(:w_id, :integer, primary_key: true)
      add(:w_name, :string)
      add(:w_tax, :float)
      add(:w_ytd, :float)
    end

    create table(:district, primary_key: false) do
      add(:d_w_id, :integer, primary_key: true)
      add(:d_id, :integer, primary_key: true)
      add(:d_name, :string)
      add(:d_tax, :float)
      add(:d_ytd, :float)
      add(:d_next_o_id, :integer)
    end

    create table(:customer, primary_key: false) do
      add(:c_w_id, :integer, primary_key: true)
      add(:c_d_id, :integer, primary_key: true)
      add(:c_id, :integer, primary_key: true)
      add(:c_first, :string)
      add(:c_last, :string)
      add(:c_credit, :string)
      add(:c_credit_lim, :float)
      add(:c_discount, :float)
      add(:c_balance, :float)
      add(:c_ytd_payment, :float)
    end

    create table(:history, primary_key: false) do
      add(:h_id, :string, primary_key: true)
      add(:h_c_id, :integer)
      add(:h_c_d_id, :integer)
      add(:h_c_w_id, :integer)
      add(:h_d_id, :integer)
      add(:h_w_id, :integer)
      add(:h_date, :naive_datetime_usec)
      add(:h_amount, :float)
      add(:h_data, :string)
    end

    create table(:oorder, primary_key: false) do
      add(:o_w_id, :integer, primary_key: true)
      add(:o_d_id, :integer, primary_key: true)
      add(:o_id, :integer, primary_key: true)
      add(:o_c_id, :integer)
      add(:o_entry_d, :integer)
      add(:o_carrier_id, :integer)
      add(:o_ol_cnt, :integer)
      add(:o_all_local, :integer)
    end

    create table(:new_order, primary_key: false) do
      add(:no_w_id, :integer, primary_key: true)
      add(:no_d_id, :integer, primary_key: true)
      add(:no_o_id, :integer, primary_key: true)
    end

    create table(:order_line, primary_key: false) do
      add(:ol_w_id, :integer, primary_key: true)
      add(:ol_d_id, :integer, primary_key: true)
      add(:ol_o_id, :integer, primary_key: true)
      add(:ol_number, :integer, primary_key: true)
      add(:ol_i_id, :integer)
      add(:ol_supply_w_id, :integer)
      add(:ol_delivery_d, :integer)
      add(:ol_quantity, :integer)
      add(:ol_amount, :float)
      add(:ol_dist_info, :string)
    end

    create table(:item, primary_key: false) do
      add(:i_id, :integer, primary_key: true)
      add(:i_im_id, :integer)
      add(:i_name, :string)
      add(:i_price, :float)
      add(:i_data, :string)
    end

    create table(:stock, primary_key: false) do
      add(:s_w_id, :integer, primary_key: true)
      add(:s_i_id, :integer, primary_key: true)
      add(:s_quantity, :integer)
      add(:s_dist_info, :string)
      add(:s_ytd, :float)
      add(:s_order_cnt, :integer)
      add(:s_remote_cnt, :integer)
      add(:s_data, :string)
    end
  end
end
