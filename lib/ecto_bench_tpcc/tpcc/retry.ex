defmodule EctoBenchTpcc.Tpcc.Retry do
  @moduledoc """
  A bounded retry-with-backoff wrapper around `Repo.transaction/2`, for
  adapters built on optimistic concurrency control (OCC) -- FoundationDB
  (and `ecto_fdb_relational`) chief among them.

  This isn't a workaround for a bug: TPC-C's own spec mandates exactly
  this behavior -- a transaction that rolls back due to a conflict or
  deadlock must be resubmitted with the same inputs, not treated as a
  failed transaction. It's also the standard client-side pattern every
  real OCC database's own client library bakes directly into its
  transaction API for this reason (see e.g. FoundationDB's binding docs
  on retryable errors) -- one `ecto_fdb_relational`'s `Repo.transaction/2`
  does not provide on its own; it surfaces the raw conflict once, no
  retry.

  ## Why retrying here can't cause a double write

  FDB (and this heuristic) distinguishes two different commit failures,
  not one:

    * `not_committed` (FDB error 1020) -- "Transaction not committed due
      to conflict with another transaction." This is FDB's own guarantee
      that the transaction was **not** applied; "not committed" is the
      operative word. Retrying resubmits work that never happened.
    * `commit_unknown_result` (FDB error 1021) -- genuinely ambiguous
      (e.g. the commit was sent but the acknowledgment was lost); the
      transaction *may or may not* have applied. Blindly retrying this
      one could double-write, so it must not match here.

  `conflict?/1` therefore matches the specific `not_committed` phrasing
  ("not committed" + "conflict" both present), not a bare `/conflict/i`
  -- `commit_unknown_result`'s message doesn't contain "not committed", so
  it falls through and re-raises unretried, same as any other error.
  """

  @max_attempts 10
  @base_backoff_ms 5

  @doc """
  Runs `fun` inside `repo.transaction/2` (passing `opts` through, e.g.
  `timeout:`), retrying up to #{@max_attempts} times with jittered
  exponential backoff if it raises an error that looks like a transaction
  conflict. Re-raises the original error, unmodified, once retries are
  exhausted or the error doesn't look like a conflict.
  """
  def transaction(repo, fun, opts \\ []), do: do_transaction(repo, fun, opts, 1)

  defp do_transaction(repo, fun, opts, attempt) do
    repo.transaction(fun, opts)
  rescue
    e ->
      if attempt < @max_attempts and conflict?(e) do
        attempt |> backoff_ms() |> Process.sleep()
        do_transaction(repo, fun, opts, attempt + 1)
      else
        reraise e, __STACKTRACE__
      end
  end

  defp conflict?(e) do
    message = Exception.message(e)
    String.match?(message, ~r/not committed/i) and String.match?(message, ~r/conflict/i)
  end

  defp backoff_ms(attempt) do
    base = round(@base_backoff_ms * :math.pow(2, attempt - 1))
    base + :rand.uniform(base)
  end
end
