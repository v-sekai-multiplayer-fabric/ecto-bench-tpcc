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

      # Dev/test only: SQLite is the reference adapter this repo's own CI
      # exercises the harness against, since it needs no external server --
      # the whole point of splitting this out of ecto-fdb-relational is
      # that the harness/schema/workload are adapter-generic; SQLite is
      # just the cheapest real adapter to prove that in CI.
      {:ecto_sqlite3, "~> 0.17", only: :test},
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
