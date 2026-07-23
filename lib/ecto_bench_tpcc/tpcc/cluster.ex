defmodule EctoBenchTpcc.Tpcc.Cluster do
  @moduledoc """
  Starts sibling BEAM nodes (via `:peer`, OTP 25+'s non-deprecated
  replacement for `:slave`) so `Loader.load!/2` can distribute work across
  genuinely independent OS processes.

  ## Why this exists

  `ecto_fdb_relational` (v0.2+) embeds FRL via a Rustler NIF that creates
  exactly one JVM per OS process (`JNI_CreateJavaVM` can only be called
  once per process). Every `DBConnection` pool worker is a lightweight
  BEAM process, not an OS process, so no matter how high `Repo`'s
  `:pool_size` or `Loader`'s own `@load_concurrency` go, all connections
  in one node share that one embedded JVM / one `libfdb_c` / one FDB
  network thread. Pushing pool_size: 20 onto that single shared reactor
  is exactly what crashed the embedded JVM with a SIGSEGV in `libfdb_c.so`
  (measured directly -- the crash log showed only one thread named
  `"fdb-network-thread"` across all 20 pooled connections, proof they
  shared one JVM instead of getting one each).

  Real independence needs real OS processes: each node `start_nodes/1`
  spawns is a full separate BEAM VM, so each gets its own fresh embedded
  JVM when `EctoFdbRelational.Native` loads there -- confirmed directly
  (a `:peer` node successfully ran `EctoFdbRelational.Native.connect/1`
  and opened its own independent connection to the same FDB cluster).

  ## `connection: :standard_io`

  Peer nodes here don't join distributed Erlang (`Node.connect/1`, epmd,
  a shared cookie) -- `:peer`'s alternative `:standard_io` connection
  tunnels calls over the spawned process's own stdin/stdout instead, which
  needs no distribution setup on the calling node at all (this project's
  own `mix test` run isn't itself a named/distributed node). `peer.call/4`
  works the same either way.

  ## Code path

  A freshly spawned peer node has nothing on its code path by default --
  neither this project's compiled modules nor Elixir's own standard
  library (`Code`, `Enum`, `String`, ...). `start_nodes/1` passes both:
  this project's `_build/#{Mix.env()}/lib/*/ebin` directories, and every
  path already on the calling node's own `:code.get_path/0` (which is
  where Elixir/Mix/Logger/etc.'s ebin directories live).
  """

  @doc """
  Starts `count` sibling nodes, each with this project's full code path
  and `env` (e.g. `JAVA_HOME`/`ECTO_FDB_RELATIONAL_CLASSPATH`/
  `LD_LIBRARY_PATH` -- required for `EctoFdbRelational.Native`'s embedded
  JVM to start on each one, same as the calling node needs them).

  Returns `[{pid, node}]` -- `pid` is what `stop_nodes/1` and `:peer.call/4`
  need; `node` is the node name (only useful for logging/`:erlang.node/1`
  comparisons, `:peer.call/4` doesn't take it).
  """
  @spec start_nodes(pos_integer(), keyword()) :: [{pid(), node()}]
  def start_nodes(count, opts \\ []) do
    env = Keyword.get(opts, :env, [])
    args = peer_args()

    for i <- 1..count do
      name = String.to_atom("ecto_bench_tpcc_worker_#{i}_#{System.unique_integer([:positive])}")

      {:ok, pid, node} =
        :peer.start_link(%{
          name: name,
          args: args,
          env: env,
          connection: :standard_io
        })

      {pid, node}
    end
  end

  @doc "Stops every node `start_nodes/2` returned."
  @spec stop_nodes([{pid(), node()}]) :: :ok
  def stop_nodes(nodes) do
    Enum.each(nodes, fn {pid, _node} -> :peer.stop(pid) end)
  end

  defp peer_args do
    project_ebins = Path.wildcard(Path.join(File.cwd!(), "_build/#{Mix.env()}/lib/*/ebin"))
    elixir_ebins = :code.get_path() |> Enum.map(&to_string/1)

    (project_ebins ++ elixir_ebins)
    |> Enum.uniq()
    |> Enum.flat_map(&[~c"-pa", String.to_charlist(&1)])
  end
end
