# Transactions

The MongrelDB daemon commits batched operations atomically. The Julia client
mirrors that with a `transaction()` function: you build a vector of ops (each a
`Dict("put" => ...)`, `Dict("upsert" => ...)`, `Dict("delete" => ...)`, or
`Dict("delete_by_pk" => ...)`) and pass it to `transaction()`, which flushes
the whole batch in a single `/kit/txn` request. Unique, foreign key, and check
constraints are enforced by the engine at commit time, so either every
operation lands or none.

## Basic commit

```julia
ops = [
    Dict("put"          => Dict("table" => "orders", "cells" => Any[1, 10, 2, "Dave", 3, 50.0])),
    Dict("put"          => Dict("table" => "orders", "cells" => Any[1, 11, 2, "Eve",  3, 75.0])),
    Dict("delete_by_pk" => Dict("table" => "orders", "pk" => 2)),
]
results = MongrelDB.transaction(db, ops)    # atomic: all or nothing
```

`transaction()` returns a vector of per-operation result dicts. Each entry
reflects the `kind` the engine took (`put`, `deleted`, `not_found`, etc.).

The `cells` field is a flat array of `[col_id, value, col_id, value, ...]` to
match the on-wire shape for batch ops. When you use `put()` directly, the
client flattens a `Dict(col_id => value)` for you.

Note: a row inserted in one transaction is not visible to a `delete_by_pk` in
the *same* transaction. Commit the inserts first, then delete in a follow-up
batch.

## Idempotent commits

Pass an idempotency key as the second argument to make a commit safe to retry.
If the daemon sees the same key again (even after a crash), it returns the
original response instead of replaying the work:

```julia
MongrelDB.transaction(db, ops, "order-20-create")
```

Keys are opaque, caller-supplied strings. The client does not derive or store
them.

## Constraint handling

If a staged operation violates a constraint, the engine rejects the whole batch
and the client throws a `MongrelDBError` whose `kind` is `:constraint`, with
the server's `error_code` (for example, `UNIQUE_VIOLATION`) and, when reported,
the `op_index` of the offending operation:

```julia
try
    MongrelDB.transaction(db, ops)
catch e
    if e isa MongrelDB.MongrelDBError && e.kind == :constraint
        @warn "Constraint violated" e.error_code e.op_index
    end
end
```

See [Errors](errors.md) for the full hierarchy.
