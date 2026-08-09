defmodule EctoBenchTpcc.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/weftspun/ecto_bench_tpcc"

  def project do
    [
      app: :ecto_bench_tpcc,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      name: "EctoBenchTpcc",
      source_url: @source_url
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      # The only real dependencies: this library only builds Ecto.Query/
      # Ecto.Migration-shaped work and a Benchee-based load runner. It does
      # NOT depend on any specific Ecto adapter -- callers bring their own
      # Repo (any `Ecto.Adapters.SQL`-based adapter: Postgres, MySQL,
      # SQLite3, ecto_fdb_relational, ...).
      {:ecto, "~> 3.11"},
      {:ecto_sql, "~> 3.11"},
      {:benchee, "~> 1.3"},

      # ecto_foundationdb reaches FoundationDB through erlfdb. No JVM, no
      # JDK, no separate server process, and no Rust toolchain -- which is
      # why it replaced `ecto_fdb_relational` as this repo's reference
      # adapter. Requires FoundationDB 7.3 or newer: on a 7.1.26 client,
      # erlfdb_transaction_get_mapped_range raises ArgumentError.
      #
      # Pinned to a fork branch, not Hex, because released
      # `ecto_foundationdb` (0.7.6) supports a single primary key field
      # only -- `Fields.get_pk_field!/1` matches `[pk_field]` and raises
      # `MatchError` on a composite key. TPC-C identifies its tables by
      # compound natural attributes, so on Hex the only option is a
      # synthetic key plus covering indexes, which changes the physical
      # layout and with it the contention being measured. The branch adds
      # composite primary key support, keeping single-key encoding
      # byte-identical. Tracks the `vsk` branch rather than the feature
      # branch, so anything else V-Sekai lands arrives here too. Move back
      # to Hex once it lands upstream at foundationdb-beam/ecto_foundationdb
      # (PR 104).
      {:ecto_foundationdb,
       github: "v-sekai-multiplayer-fabric/ecto_foundationdb", branch: "vsk", only: [:dev, :test]},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "A generic TPC-C-style benchmark harness for any Ecto adapter -- schema, " <>
      "workload, and load runner are adapter-agnostic; bring your own Repo."
  end

  defp package do
    [
      name: "ecto_bench_tpcc",
      files: ~w(lib rfd mix.exs README.md LICENSE),
      licenses: ["Apache-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
