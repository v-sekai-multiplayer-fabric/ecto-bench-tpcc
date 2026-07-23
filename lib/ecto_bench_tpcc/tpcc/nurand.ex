defmodule EctoBenchTpcc.Tpcc.NURand do
  @moduledoc """
  TPC-C's specified non-uniform random distribution (spec section 2.1.6),
  used for C_LAST (customer surname) generation and C_ID/OL_I_ID
  selection. Picking these uniformly at random (as this repo did before --
  see `rfd/0001-tpcc-scaling.md`) understates real contention on hot rows
  (a specific customer, a specific popular item), which is the whole
  point of the spec mandating a skewed distribution instead of plain
  `:rand.uniform/1`.

      NURand(A, x, y) = (((random(0, A) bor random(x, y)) + C) rem (y - x + 1)) + x

  `C` is chosen once per run (not once per call) and held fixed for the
  whole run -- both while loading data (`C_LAST`) and while running
  transactions (`C_ID`/`OL_I_ID`) -- per spec 2.1.6: the same `C` "must be
  used for the whole ... test". `new/0` generates one `C` per
  NURand-using column (independent constants for `C_LAST`/`C_ID`/
  `OL_I_ID`, each within its own spec-mandated range) --
  `EctoBenchTpcc.Tpcc.Config` stores the result so `Loader` and
  `Procedures` share the same one for a given run.
  """

  import Bitwise

  @c_last_a 255
  @c_id_a 1023
  @ol_i_id_a 8191

  @enforce_keys [:c_last, :c_id, :ol_i_id]
  defstruct [:c_last, :c_id, :ol_i_id]

  @type t :: %__MODULE__{
          c_last: non_neg_integer(),
          c_id: non_neg_integer(),
          ol_i_id: non_neg_integer()
        }

  @doc "Generates one fresh set of run-constants, one per NURand-using column."
  @spec new() :: t()
  def new do
    %__MODULE__{
      c_last: :rand.uniform(@c_last_a + 1) - 1,
      c_id: :rand.uniform(@c_id_a + 1) - 1,
      ol_i_id: :rand.uniform(@ol_i_id_a + 1) - 1
    }
  end

  @doc "NURand-picks a customer id in [1, customers_per_district]."
  @spec customer_id(t(), pos_integer()) :: pos_integer()
  def customer_id(%__MODULE__{c_id: c}, customers_per_district) do
    nurand(@c_id_a, c, 1, customers_per_district)
  end

  @doc "NURand-picks an item id in [1, items] (drawn from the shared ITEM catalog)."
  @spec item_id(t(), pos_integer()) :: pos_integer()
  def item_id(%__MODULE__{ol_i_id: c}, items) do
    nurand(@ol_i_id_a, c, 1, items)
  end

  @doc """
  The customer last name (C_LAST) for position `c_id` (1-based) within a
  district, per spec 4.3.3.1: the first 1,000 customers get deterministic,
  sequential names (`syllables(c_id - 1)`, covering all 1,000 possible
  surnames exactly once, in order); the remaining customers (1,001+) get
  NURand-random names, so most districts' surnames repeat -- real
  contention on "customers sharing a last name", which TPC-C's
  by-name Payment/OrderStatus lookup is designed to exercise (this repo's
  `Procedures` doesn't implement that by-name lookup yet -- see its
  moduledoc).
  """
  @spec last_name(t(), pos_integer()) :: String.t()
  def last_name(%__MODULE__{} = _nurand, c_id) when c_id <= 1000 do
    syllables(c_id - 1)
  end

  def last_name(%__MODULE__{c_last: c}, _c_id) do
    @c_last_a |> nurand(c, 0, 999) |> syllables()
  end

  @doc false
  @spec nurand(non_neg_integer(), non_neg_integer(), integer(), integer()) :: integer()
  def nurand(a, c, x, y) do
    r1 = :rand.uniform(a + 1) - 1
    r2 = :rand.uniform(y - x + 1) - 1 + x
    rem(bor(r1, r2) + c, y - x + 1) + x
  end

  @syllables {"BAR", "OU", "ABLE", "PRI", "PRES", "ESE", "ANTI", "CALLY", "ATION", "EING"}

  @doc "Renders `num` (0..999) as a C_LAST-style name via the spec's syllable table."
  @spec syllables(0..999) :: String.t()
  def syllables(num) when num in 0..999 do
    d1 = div(num, 100)
    d2 = num |> rem(100) |> div(10)
    d3 = rem(num, 10)
    elem(@syllables, d1) <> elem(@syllables, d2) <> elem(@syllables, d3)
  end
end
