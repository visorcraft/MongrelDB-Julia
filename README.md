<p align="center">
  <img src="assets/mongrel.png" alt="MongrelDB logo" width="250" />
</p>

<h1 align="center">MongrelDB Julia Client</h1>

<p align="center">
  <b>Pure Julia client for MongrelDB, embedded and server database with SQL, vector search, full-text search, and AI-native retrieval.</b>
</p>

<p align="center">
  <a href="https://juliahub.com/ui/Packages/MongrelDB"><img src="https://img.shields.io/badge/JuliaHub-MongrelDB-9558b2.svg" alt="JuliaHub" /></a>
  <a href="https://julialang.org/"><img src="https://img.shields.io/badge/Julia-%3E%3D1.9-9558b2.svg" alt="Julia" /></a>
  <a href="#license"><img src="https://img.shields.io/badge/license-MIT%20OR%20Apache--2.0-blue.svg" alt="License" /></a>
</p>

## Package

| Surface | Package | Install |
|---|---|---|
| Julia client | `MongrelDB` | `julia -e 'using Pkg; Pkg.develop(path=".")'` |

## Requirements

- **Julia 1.9 or newer** (Julia 1.10 and 1.11 supported)
- The standard library only (Sockets is part of Base; JSON is vendored)
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB) daemon

## What It Provides

- **Typed CRUD** over the Kit transaction endpoint: `put`, `upsert` (insert-or-update on PK conflict), `delete` by row id or primary key, with idempotency keys for safe retries.
- **Native query conditions** that push down to the engine's specialized indexes for sub-millisecond lookups: bitmap equality/IN, learned-range, null checks, FM-index full-text search, HNSW vector similarity (`ann`), and sparse vector match.
- **Idempotent batch transactions**, all operations staged in a vector and committed atomically, with the engine enforcing unique, foreign key, and check constraints at commit time. Idempotency keys return the original response on duplicate commits, even after a crash.
- **Full SQL access** through the DataFusion-backed `/sql` endpoint: recursive CTEs, window functions, `CREATE TABLE AS SELECT`, materialized views, multi-statement execution, and the `mongreldb_fts_rank` relevance-scoring UDF.
- **Schema management**: typed table creation, full schema catalog, and per-table descriptors.
- **Sockets transport** built on a standard-library module, so there are no external package dependencies to install.
- **Typed exception type** (`MongrelDBError`) with a `kind` field: `auth` (401/403), `not_found` (404), `constraint` (409, with error code and op index), `connection` (network), and `query` (everything else).
- **History retention control**: `setHistoryRetentionEpochs`, `historyRetentionEpochs`, and `earliestRetainedEpoch` expose the daemon's `GET`/`PUT /history/retention` contract.
- **Static column defaults**: scalar `default_value` (string, integer, boolean, explicit JSON `null`) and dynamic `default_expr` (`"now"`, `"uuid"`) are forwarded with their JSON types preserved.
- **Robust JSON handling**: NaN and Infinity raise a clear error instead of corrupting data; malformed UTF-8 is passed through so the daemon can substitute it.

## Examples

Runnable, commented examples live in [`examples/`](examples):

- [Basic CRUD](examples/basic_crud.jl), connect, create a table, insert, query, count.

## Quick Example

```julia
using MongrelDB

# Connect to a running mongreldb-server daemon.
db = MongrelDB.connect("http://127.0.0.1:8453")

# The daemon requires JSON booleans for primary_key / nullable.
T, F = true, false

# Create a table.
checks = Dict("checks" => [Dict(
    "id" => 1,
    "name" => "id_present",
    "expr" => Dict("IsNotNull" => 1),
)])

MongrelDB.createTable(db, "orders", [
    Dict("id" => 1, "name" => "id",         "ty" => "int64",          "primary_key" => T, "nullable" => F),
    Dict("id" => 2, "name" => "customer",   "ty" => "varchar",        "primary_key" => F, "nullable" => F),
    Dict("id" => 3, "name" => "amount",     "ty" => "float64",        "primary_key" => F, "nullable" => F),
    Dict("id" => 4, "name" => "status",     "ty" => "enum",
         "enum_variants" => ["draft", "paid", "shipped"],
         "default_value" => "draft",
         "primary_key" => F, "nullable" => F),
    Dict("id" => 5, "name" => "created_at", "ty" => "timestamp_nanos",
         "default_expr" => "now",
         "primary_key" => F, "nullable" => F),
]; constraints=checks)

# Insert rows. Cells map column id to value.
MongrelDB.put(db, "orders", Dict(1 => 1, 2 => "Alice", 3 => 99.50))
MongrelDB.put(db, "orders", Dict(1 => 2, 2 => "Bob",   3 => 150.00))

# Upsert (insert or update on PK conflict).
MongrelDB.upsert(db, "orders", Dict(1 => 1, 2 => "Alice", 3 => 120.00), Dict(3 => 120.00))

# Query with a native index condition (learned-range index).
rows, _ = MongrelDB.query(db, "orders", [
    MongrelDB.condition("range", Dict("column" => 3, "min" => 100.0)),
]; projection = [1, 2], limit = 100)

println(MongrelDB.count(db, "orders"))   # 2

# Run SQL.
MongrelDB.sql(db, "UPDATE orders SET amount = 200.0 WHERE customer = 'Bob'")
```

## History retention

Control how many epochs of history the daemon keeps for time-travel queries.
Setting a larger window cannot restore history that has already been pruned.

```julia
# Keep one million epochs of history.
MongrelDB.setHistoryRetentionEpochs(db, 1_000_000)

MongrelDB.historyRetentionEpochs(db)  # current window size
MongrelDB.earliestRetainedEpoch(db)   # oldest epoch still readable

# Read a table as it existed at an earlier epoch.
MongrelDB.sql(db, "SELECT amount FROM orders AS OF EPOCH 42 WHERE id = 1")
```

## Auth

```julia
# Bearer token (--auth-token mode).
db = MongrelDB.connect("http://127.0.0.1:8453"; token = "my-secret-token")

# HTTP Basic (--auth-users mode).
db = MongrelDB.connect("http://127.0.0.1:8453";
    username = "admin", password = "s3cret")
```

## Transactions

Operations are staged in a vector and committed atomically. The engine enforces
unique, foreign key, and check constraints at commit time.

```julia
ops = [
    Dict("put"          => Dict("table" => "orders", "cells" => Any[1, 10, 2, "Dave", 3, 50.0])),
    Dict("put"          => Dict("table" => "orders", "cells" => Any[1, 11, 2, "Eve",  3, 75.0])),
    Dict("delete_by_pk" => Dict("table" => "orders", "pk" => 2)),
]

try
    MongrelDB.transaction(db, ops)    # atomic, all or nothing
catch e
    if e isa MongrelDB.MongrelDBError && e.kind == :constraint
        @warn "Constraint violated" e.error_code e.message
    end
end

# Idempotent commit, safe to retry; daemon returns the original response.
MongrelDB.transaction(db, ops2, "order-20-create")
```

## Query builder

Conditions push down to the engine's specialized indexes. `MongrelDB.condition`
accepts friendly aliases that are translated to the server's on-wire keys:
`column` (to `column_id`), `min`/`max` (to `lo`/`hi`). The canonical keys are
also accepted directly.

```julia
# Bitmap equality (low-cardinality columns).
MongrelDB.query(db, "orders", [ MongrelDB.condition("bitmap_eq", Dict("column" => 2, "value" => "Alice")) ])

# Range query (learned-range index).
MongrelDB.query(db, "orders", [
    MongrelDB.condition("range", Dict("column" => 3, "min" => 50.0, "max" => 150.0)),
]; limit = 100)

# Full-text search (FM-index).
MongrelDB.query(db, "documents", [
    MongrelDB.condition("fm_contains", Dict("column" => 2, "pattern" => "database performance")),
]; limit = 10)

# Vector similarity search (HNSW).
MongrelDB.query(db, "embeddings", [
    MongrelDB.condition("ann", Dict("column" => 2, "query" => [0.1, 0.2, 0.3], "k" => 10)),
])

# Check whether a result was capped by the limit.
rows, truncated = MongrelDB.query(db, "orders",
    [ MongrelDB.condition("range", Dict("column" => 3, "min" => 0)) ];
    limit = 100)
if truncated
    # result set hit the limit; more matches exist on the server.
end
```

## SQL

```julia
MongrelDB.sql(db, "INSERT INTO orders (id, customer, amount) VALUES (99, 'Zoe', 999.0)")
MongrelDB.sql(db, "CREATE TABLE archive AS SELECT * FROM orders WHERE amount > 500")

# Recursive CTEs and window functions.
MongrelDB.sql(db, "WITH RECURSIVE r(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM r WHERE n<10) SELECT n FROM r")
MongrelDB.sql(db, "SELECT id, ROW_NUMBER() OVER (PARTITION BY customer ORDER BY amount DESC) FROM orders")
```

## User and role management

User and role administration is done through SQL against the `/sql` endpoint.
Quote identifiers and escape literals so caller-supplied names are safe to
interpolate.

```julia
MongrelDB.sql(db, "CREATE USER \"admin\" WITH PASSWORD 's3cret-pw'")
MongrelDB.sql(db, "ALTER USER \"admin\" ADMIN")

MongrelDB.sql(db, "CREATE ROLE \"analyst\"")
MongrelDB.sql(db, "GRANT SELECT ON orders TO \"analyst\"")
MongrelDB.sql(db, "GRANT \"analyst\" TO \"alice\"")
```

## Error handling

```julia
using MongrelDB

db = MongrelDB.connect("http://127.0.0.1:8453")

try
    MongrelDB.put(db, "orders", Dict(1 => 1))    # duplicate PK
catch e
    if !(e isa MongrelDB.MongrelDBError)
        rethrow(e)
    elseif e.kind == :constraint
        @warn "Constraint: $(e.error_code)"      # UNIQUE_VIOLATION
    elseif e.kind == :auth
        @warn "Not authorized: $(e.message)"
    elseif e.kind == :not_found
        @warn "Not found: $(e.message)"
    elseif e.kind == :connection
        @warn "Can't reach daemon: $(e.message)"
    else
        @warn "Error: $(e.message)"
    end
end
```

## API reference

### `MongrelDB` module

| Function | Description |
|---|---|
| `MongrelDB.connect(url; token, username, password)` | Connect to a daemon |
| `MongrelDB.condition(type, params)` | Build a normalized condition |

### Client object (from `connect`)

| Function | Description |
|---|---|
| `health(client)` | Check daemon health |
| `tables(client)` | List table names |
| `createTable(client, name, columns; constraints=nothing)` | Create a table, optionally attach engine constraints; returns table id |
| `dropTable(client, name)` | Drop a table |
| `count(client, table)` | Row count |
| `put(client, table, cells)` | Insert a row |
| `upsert(client, table, cells, update)` | Upsert a row |
| `delete(client, table, rowId)` | Delete by row ID |
| `deleteByPk(client, table, pk)` | Delete by primary key |
| `query(client, table, conditions; projection, limit, offset)` | Run a paged native query |
| `sql(client, statement)` | Execute SQL |
| `historyRetention(client)` | Get both retention values as a named tuple |
| `setHistoryRetentionEpochs(client, epochs)` | Set the history retention window |
| `historyRetentionEpochs(client)` | Current retention window size |
| `earliestRetainedEpoch(client)` | Oldest readable epoch |
| `schema(client)` | Full schema catalog |
| `schemaFor(client, table)` | Single table schema |
| `transaction(client, ops, idempotency_key)` | Commit a batch atomically |

## Building and testing

The test suite is split into a pure unit suite (no daemon needed) and a live
integration suite.

```sh
julia --project=. -e 'using Pkg; Pkg.develop(path="."); Pkg.test()'
# or run the unit suite directly:
julia --project=. test/json_test.jl
```

For the live round-trip suite, start a daemon and point the tests at it:

```sh
MONGRELDB_URL=http://127.0.0.1:8453 julia --project=. test/live_test.jl
```

## Contributing

Contributions are welcome. Please:

1. Open an issue first for non-trivial changes.
2. Add focused tests near your change, the suite must stay green.
3. Keep Julia 1.9 as the minimum supported version.
4. Match the existing style: four-space indent, and standard library only (no
   new external package dependencies, the zero-dependency story is a feature).

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the full guide.

## License

Dual-licensed under the **MIT License** or the **Apache License, Version 2.0**,
at your option. See [MIT](LICENSE-MIT) OR [Apache-2.0](LICENSE-APACHE) for the full text.

`SPDX-License-Identifier: MIT OR Apache-2.0`
