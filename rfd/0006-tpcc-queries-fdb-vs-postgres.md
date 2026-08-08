# ADR 0006: every TPC-C query, on ecto_foundationdb against PostgreSQL

## Status

Accepted. Reference for [ADR 0005](0005-ecto-foundationdb-composite-keys.md).

## The short version

**The Ecto code is identical on both.** Not one line of
`procedures.ex` changed.

What differs is what has to exist for that code to run. PostgreSQL
takes a composite primary key and lets the planner work out the access
path. `ecto_foundationdb` takes one synthetic primary key, and requires
an index whose field order matches the query, because it refuses any
query that one Get or one GetRange cannot answer.

## Query by query

### NewOrder

| Query | PostgreSQL needs | ecto_foundationdb needs |
| --- | --- | --- |
| `get_by!(District, d_id:, d_w_id:)` | composite PK | `index(District, [:d_w_id, :d_id])` |
| `from(d in District, where: d.d_id == ^d and d.d_w_id == ^w) \|> update_all(...)` | composite PK | same index |
| `insert!(%Oorder{...})`, `insert!(%NewOrder{...})` | nothing | nothing |
| `get_by!(Stock, s_i_id:, s_w_id:)` | composite PK | `index(Stock, [:s_w_id, :s_i_id])` |
| `from(s in Stock, where: ...) \|> update_all(...)` | composite PK | same index |

### Payment

| Query | PostgreSQL needs | ecto_foundationdb needs |
| --- | --- | --- |
| `from(w in Warehouse, where: w.w_id == ^w) \|> update_all(...)` | PK | **nothing**: `w_id` is the primary key |
| `get_by!(District, ...)`, `update_all` | composite PK | `index(District, [:d_w_id, :d_id])` |
| `get_by!(Customer, c_id:, c_d_id:, c_w_id:)` | composite PK | `index(Customer, [:c_w_id, :c_d_id, :c_id])` |
| `insert!(%History{...})` | nothing | nothing |

### OrderStatus

| Query | PostgreSQL needs | ecto_foundationdb needs |
| --- | --- | --- |
| `get_by!(Customer, ...)` | composite PK | `index(Customer, [:c_w_id, :c_d_id, :c_id])` |
| `from(o in Oorder, where: o.o_c_id == ^c and o.o_d_id == ^d and o.o_w_id == ^w)` | index on those fields | `index(Oorder, [:o_w_id, :o_d_id, :o_c_id])` |
| `from(ol in OrderLine, where: ol.ol_o_id == ^o and ol.ol_d_id == ^d and ol.ol_w_id == ^w)` | composite PK prefix | `index(OrderLine, [:ol_w_id, :ol_d_id, :ol_o_id])` |

### Delivery

| Query | PostgreSQL needs | ecto_foundationdb needs |
| --- | --- | --- |
| `from(no in NewOrder, where: no.no_d_id == ^d and no.no_w_id == ^w)` | PK prefix | `index(NewOrder, [:no_w_id, :no_d_id, :no_o_id])`, used as a **prefix** |
| `... where: no_o_id, no_d_id, no_w_id \|> delete_all()` | composite PK | the same index, fully specified |
| `from(o in Oorder, where: o.o_id == ^o and ...) \|> update_all(...)` | composite PK | `index(Oorder, [:o_w_id, :o_d_id, :o_id])`, a **second** index |
| `from(ol in OrderLine, where: ...) \|> update_all(...)` | composite PK prefix | `index(OrderLine, [:ol_w_id, :ol_d_id, :ol_o_id])` |

### StockLevel

| Query | PostgreSQL needs | ecto_foundationdb needs |
| --- | --- | --- |
| `from(ol in OrderLine, where: ol.ol_d_id == ^d and ol.ol_w_id == ^w)` | PK prefix | the OrderLine index, used as a prefix |
| `get_by(Stock, s_i_id:, s_w_id:)` | composite PK | `index(Stock, [:s_w_id, :s_i_id])` |

## Three rules that decide the index list

**Warehouse id leads every index.** FoundationDB sorts keys, so an
index on `[:ol_w_id, :ol_d_id, :ol_o_id]` also answers a query that
constrains only `ol_w_id` and `ol_d_id`. `StockLevel` and `Delivery`
share one OrderLine index because of this.

**A different third field needs a different index.** `Oorder` is looked
up by customer in `OrderStatus` and by order id in `Delivery`. Prefixes
cannot cover both, so `oorder` carries two indexes.

**A single-field primary key needs no index.** `Warehouse`, `History`
and `Item` were already keyed on one field, so their lookups go
straight to the primary key.

## What PostgreSQL does that this cannot

Nothing in this workload, which is the point. TPC-C as written here
already avoids the features `ecto_foundationdb` rejects: no joins, no
`or`, no `order_by`, no `limit`, no database-side aggregation.

Where TPC-C needs an aggregate, `procedures.ex` already computes it in
Elixir:

```elixir
|> Enum.map(& &1.ol_i_id) |> Enum.uniq()          # StockLevel
|> Enum.count(&(&1.s_quantity < threshold))        # StockLevel
|> Enum.min_by(& &1.no_o_id, fn -> nil end)        # Delivery
|> List.last()                                      # OrderStatus
```

A port that had to move aggregation out of SQL would be a much larger
change. This one did not.

## One semantic difference worth stating

`OrderStatus` does `repo.all() |> List.last()` with no `order_by`. SQL
leaves that order undefined, so PostgreSQL may return any row.
`ecto_foundationdb` returns index order, which is `o_w_id`, `o_d_id`,
then `o_c_id`.

Both are valid. They are not the same row. Any comparison of results
between the two backends has to account for that, and this is not a
bug in either.

## Measured

FoundationDB 7.3.43, `ecto_foundationdb` 0.7.6, `erlfdb` 1.2.1.

```
indexed query (new txn)     median 0.558 ms  p99 0.8 ms
read-modify-write (1 txn)   median 3.548 ms  p99 5.022 ms
```

Same machine, for scale: PostgreSQL 16 point read 0.084 ms, raw
FoundationDB point read 0.405 ms.

FoundationDB 7.3 or newer is required. See ADR 0005.
