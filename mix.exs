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

      # Dev/test only: `ecto_fdb_relational` (an Ecto adapter for
      # FoundationDB Record Layer's Relational Layer) is the reference
      # adapter this repo's own CI exercises the harness against -- this
      # repo was split out of that project specifically to prove the
      # harness/schema/workload are adapter-generic, so testing against
      # the adapter it was split from is the point. Not on Hex yet, so
      # pulled straight from GitHub (unpinned -- always the latest on
      # `main`). As of v0.2 it embeds FRL in-process via a Rustler NIF +
      # JNI (no separate `fdb-relational-server` process at runtime), so
      # compiling this repo's :test env needs a JDK + Rust toolchain and
      # `ECTO_FDB_RELATIONAL_CLASSPATH` set -- see `test/tpcc_test.exs`
      # and `.github/workflows/ci.yml`. Still needs a live FoundationDB
      # cluster to run against.
      {:ecto_fdb_relational, github: "weftspun/ecto-fdb-relational", only: :test},
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
