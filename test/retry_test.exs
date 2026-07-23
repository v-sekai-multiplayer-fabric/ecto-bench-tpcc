defmodule EctoBenchTpcc.Tpcc.RetryTest do
  @moduledoc """
  Unit tests for `EctoBenchTpcc.Tpcc.Retry` -- no live server needed. Uses
  a fake "repo" (just a module implementing `transaction/1`) so the
  retry/backoff/re-raise logic is exercised in isolation from any real
  adapter.
  """
  use ExUnit.Case, async: true

  alias EctoBenchTpcc.Tpcc.Retry

  defmodule ConflictError do
    defexception message: "Transaction not committed due to conflict with another transaction"
  end

  defmodule UnknownResultError do
    defexception message: "Commit result is unknown and could not be determined"
  end

  defmodule FakeRepo do
    @moduledoc false
    def transaction(fun), do: fun.()
  end

  setup do
    {:ok, counter} = Agent.start_link(fn -> 0 end)
    {:ok, counter: counter}
  end

  defp count!(counter) do
    Agent.get_and_update(counter, fn n -> {n + 1, n + 1} end)
  end

  test "succeeds immediately when the transaction doesn't raise", %{counter: counter} do
    result = Retry.transaction(FakeRepo, fn -> count!(counter) end)
    assert result == 1
    assert Agent.get(counter, & &1) == 1
  end

  test "retries on a not_committed conflict and eventually succeeds", %{counter: counter} do
    result =
      Retry.transaction(FakeRepo, fn ->
        if count!(counter) < 3, do: raise(ConflictError), else: :ok
      end)

    assert result == :ok
    # 2 failed attempts + 1 successful attempt.
    assert Agent.get(counter, & &1) == 3
  end

  test "gives up and re-raises after exhausting retries on a persistent conflict", %{
    counter: counter
  } do
    assert_raise ConflictError, fn ->
      Retry.transaction(FakeRepo, fn ->
        count!(counter)
        raise(ConflictError)
      end)
    end

    # Capped at the module's max attempts, not retried forever.
    assert Agent.get(counter, & &1) == 10
  end

  # The critical safety property: commit_unknown_result is genuinely
  # ambiguous (the transaction may or may not have applied) -- retrying it
  # could double-write, so it must NOT be treated as retryable even though
  # it's also a commit failure.
  test "does not retry commit_unknown_result (would risk a double write)", %{counter: counter} do
    assert_raise UnknownResultError, fn ->
      Retry.transaction(FakeRepo, fn ->
        count!(counter)
        raise(UnknownResultError)
      end)
    end

    assert Agent.get(counter, & &1) == 1
  end

  test "does not retry an unrelated error" do
    assert_raise ArgumentError, fn ->
      Retry.transaction(FakeRepo, fn -> raise ArgumentError, "boom" end)
    end
  end
end
