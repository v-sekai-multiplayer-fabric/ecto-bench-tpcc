defmodule EctoBenchTpcc.Tpcc.FdbMigrator do
  @moduledoc """
  `EctoFoundationDB.Migrator` for the TPC-C schemas.

  A Repo that uses `Ecto.Adapters.FoundationDB` names this module in its
  `:migrator` config, or does `use EctoFoundationDB.Migrator` itself and
  returns this list.

  Note the distinction the adapter draws, because getting it wrong fails
  quietly: a Migrator lists versions, and a Migration lists index
  operations. Passing a Migration where a Migrator belongs leaves every
  index uncreated, and the first query then reports that no index covers
  the fields.
  """
  use EctoFoundationDB.Migrator

  alias EctoBenchTpcc.Tpcc.FdbMigration

  @impl true
  def migrations, do: [{0, FdbMigration}]
end
