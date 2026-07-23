defmodule EctoBenchTpcc.Tpcc.Config do
  @moduledoc """
  Holds the warehouse count (W) and NURand run-constants for the current
  benchmark run -- both must stay fixed across load and every transaction
  for the rest of the run (TPC-C spec 2.1.6 for NURand's `C`; W drives
  every table's formula-based cardinality, see
  `rfd/0001-tpcc-scaling.md`). `Loader.load!/2` sets this once;
  `Procedures` reads it on every call instead of every caller having to
  thread warehouses/nurand through each function argument.
  """
  use Agent

  alias EctoBenchTpcc.Tpcc.NURand

  defstruct warehouses: 1, nurand: nil

  @doc false
  def start_link(_opts \\ []), do: Agent.start_link(fn -> %__MODULE__{} end, name: __MODULE__)

  @doc false
  @spec put(pos_integer(), NURand.t()) :: :ok
  def put(warehouses, %NURand{} = nurand) do
    ensure_started()
    Agent.update(__MODULE__, fn _ -> %__MODULE__{warehouses: warehouses, nurand: nurand} end)
  end

  @doc "The warehouse count (W) the last `Loader.load!/2` call seeded."
  @spec warehouses() :: pos_integer()
  def warehouses do
    ensure_started()
    Agent.get(__MODULE__, & &1.warehouses)
  end

  @doc "The NURand run-constants the last `Loader.load!/2` call generated."
  @spec nurand() :: NURand.t()
  def nurand do
    ensure_started()

    Agent.get(__MODULE__, & &1.nurand) ||
      raise "EctoBenchTpcc.Tpcc.Config has no NURand constants yet -- call Loader.load!/2 first"
  end

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> start_link()
      _pid -> :ok
    end
  end
end
