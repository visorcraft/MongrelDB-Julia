# Error handling

The Julia client reports errors as `MongrelDBError` objects. Every error has a
`kind::Symbol` field (the category) and a `message::String`, and pretty-prints
as `MongrelDBError(kind): message [code=..., op_index=...]`. You match on
`kind` to react to the specific category.

## Error kinds

| `kind` | Meaning |
|---|---|
| `:auth` | HTTP 401 / 403 |
| `:not_found` | HTTP 404 |
| `:constraint` | HTTP 409, constraint violation at commit |
| `:connection` | Network-level failure (refused, DNS, timeout) |
| `:query` | HTTP 400 / 500, malformed payloads, JSON failures |

The client throws these with the normal Julia exception mechanism; wrap calls
in `try`/`catch` to catch them.

## Catching by category

```julia
using MongrelDB

db = MongrelDB.connect("http://127.0.0.1:8453")

try
    MongrelDB.put(db, "orders", Dict(1 => 1))    # duplicate PK
catch e
    if !(e isa MongrelDB.MongrelDBError)
        rethrow(e)
    elseif e.kind == :constraint
        @warn "Constraint" e.error_code          # UNIQUE_VIOLATION
    elseif e.kind == :auth
        @warn "Not authorized" e.message
    elseif e.kind == :not_found
        @warn "Not found" e.message
    elseif e.kind == :connection
        @warn "Can't reach daemon" e.message
    else
        @warn "Error" e.message
    end
end
```

## Constraint fields

A `:constraint` error carries extra fields:

- `error_code` - the server's error code string, e.g. `UNIQUE_VIOLATION`.
- `op_index` - when reported, the index of the offending operation within the
  batch (useful when a [transaction](transactions.md) commit fails).
- `status` - the HTTP status code.

## Connection failures

A `:connection` error is thrown for any network-level problem: connection
refused, DNS lookup failure, or a timeout. The `health()` helper swallows these
and returns `false` instead, which is handy for startup checks:

```julia
if !MongrelDB.health(db)
    # daemon not reachable; degrade gracefully
end
```

## JSON edge cases

The client refuses to send values that have no valid JSON representation:
infinity and NaN. These throw a `MongrelDBError(:query)` at the client boundary
rather than corrupting data on the server. Malformed UTF-8 is passed through so
the daemon can substitute it.
