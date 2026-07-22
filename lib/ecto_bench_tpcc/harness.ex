defmodule EctoBenchTpcc.Harness do
  @moduledoc """
  Runs a mixed, weighted-random transaction workload -- the shape TPC-C-style
  BenchBase benchmarks use (a terminal/worker picks one of several
  transactions per iteration, weighted like TPC-C's classic 45/43/4/4/4
  NewOrder/Payment/OrderStatus/Delivery/StockLevel mix) -- on top of
  `benchee` instead of a hand-rolled worker pool. `Benchee.run/2`'s
  `:parallel` option already provides concurrent workers, wall-clock-bounded
  runs, and latency percentiles; this module only adds the weighted-random
  dispatch a single Benchee job needs to reproduce a *mixed* workload
  (Benchee itself measures one job at a time, not several interleaved).

  Adapter-agnostic: this module and the rest of `ecto_bench_tpcc` know
  nothing about which `Ecto.Repo`/adapter they're driving -- callers pass
  in `run` functions closing over their own configured `Repo`.
  """

  @type procedure :: %{name: String.t(), weight: pos_integer(), run: (-> any())}

  @doc """
  Runs `procedures` (each `%{name:, weight:, run:}`) as one mixed-workload
  Benchee job for `duration_ms` wall-clock milliseconds across
  `worker_count` parallel processes, printing Benchee's own console report
  (latency percentiles, ips) plus a per-procedure call tally this
  workload's dispatcher tracked along the way. Returns the measured
  throughput in iterations/sec (Benchee's `ips` statistic), so callers can
  compare runs at different `:worker_count` values (e.g. to demonstrate
  scaling across available cores).
  """
  @spec run([procedure()], keyword()) :: float()
  def run(procedures, opts \\ []) do
    worker_count = Keyword.get(opts, :worker_count, 4)
    duration_ms = Keyword.get(opts, :duration_ms, 10_000)

    picker = weighted_picker(procedures)
    tally = :counters.new(length(procedures), [:atomics])
    index_by_name = procedures |> Enum.with_index() |> Map.new(fn {p, i} -> {p.name, i} end)

    %Benchee.Suite{scenarios: [scenario]} =
      Benchee.run(
        %{
          "mixed workload" => fn ->
            %{name: name, run: run} = picker.()
            :counters.add(tally, Map.fetch!(index_by_name, name) + 1, 1)
            run.()
          end
        },
        time: duration_ms / 1000,
        warmup: 0,
        parallel: worker_count,
        print: [benchmarking: false, configuration: false, fast_warning: false]
      )

    report_tally(procedures, tally)
    scenario.run_time_data.statistics.ips
  end

  defp weighted_picker(procedures) do
    total_weight = Enum.sum(Enum.map(procedures, & &1.weight))
    fn -> pick_weighted(procedures, :rand.uniform(total_weight)) end
  end

  defp pick_weighted([%{weight: weight} = p | _rest], pick) when pick <= weight, do: p
  defp pick_weighted([%{weight: weight} | rest], pick), do: pick_weighted(rest, pick - weight)

  defp report_tally(procedures, tally) do
    IO.puts("by procedure:")

    procedures
    |> Enum.with_index()
    |> Enum.each(fn {%{name: name}, i} ->
      IO.puts("  #{name}: #{:counters.get(tally, i + 1)}")
    end)
  end
end
