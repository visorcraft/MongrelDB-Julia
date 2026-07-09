# Queries

The Kit `/kit/query` endpoint pushes conditions down to the engine's
specialized indexes for sub-millisecond lookups. The Julia client exposes those
condition types through `MongrelDB.condition()` plus the `MongrelDB.query()`
runner.

## Building a query

```julia
rows, truncated = MongrelDB.query(db, "orders", [
    MongrelDB.condition("bitmap_eq", Dict("column" => 2, "value" => "Alice")),
    MongrelDB.condition("range",     Dict("column" => 3, "min"  => 100.0)),
]; projection = [1, 2], limit = 100)
```

Pass a vector of conditions (they are AND-ed together), plus optional keyword
arguments `projection` (vector of column ids) and `limit` (row cap). `query()`
returns the rows and a boolean indicating whether the result was truncated by
the limit.

## Friendly aliases

`MongrelDB.condition()` accepts readable parameter names and translates them to
the server's exact on-wire keys before sending:

| Alias | Wire key |
|---|---|
| `column` | `column_id` |
| `min` | `lo` |
| `max` | `hi` |
| `min_inclusive` | `lo_inclusive` |
| `max_inclusive` | `hi_inclusive` |

For full-text conditions (`fm_contains`, `fm_contains_all`), the alias `value`
maps to the wire key `pattern`. The server's canonical keys are also accepted
directly, so you can pass the exact wire shape when that is clearer.

## Condition types

| Type | Use | Example parameters |
|---|---|---|
| `pk` | Exact primary key match | `Dict("value" => 1)` |
| `bitmap_eq` | Equality on a bitmap-indexed column | `Dict("column" => 2, "value" => "Alice")` |
| `bitmap_in` | IN predicate on a bitmap column | `Dict("column" => 2, "values" => ["Alice","Bob"])` |
| `range` | Integer range predicate | `Dict("column" => 3, "min" => 10, "max" => 100)` |
| `range_f64` | Float range predicate | `Dict("column" => 3, "min" => 10.0, "max" => 100.0)` |
| `is_null` | Null check | `Dict("column" => 2)` |
| `is_not_null` | Not-null check | `Dict("column" => 2)` |
| `fm_contains` | Full-text substring (FM-index) | `Dict("column" => 2, "pattern" => "database")` |
| `fm_contains_all` | All patterns must match | `Dict("column" => 2, "patterns" => ["database","index"])` |
| `ann` | Dense vector similarity (HNSW) | `Dict("column" => 2, "query" => [0.1,0.2,0.3], "k" => 10)` |
| `sparse_match` | Sparse vector match | `Dict("column" => 2, "query" => [...])` |
| `min_hash_similar` | MinHash similarity search | `Dict("column" => 2, "query" => [...])` |

## Truncation check

The second return value of `query()` tells you whether the result set was
capped by the limit:

```julia
rows, truncated = MongrelDB.query(db, "orders",
    [MongrelDB.condition("range", Dict("column" => 3, "min" => 0))];
    limit = 100)
if truncated
    # result set hit the limit; more matches exist on the server.
end
```
