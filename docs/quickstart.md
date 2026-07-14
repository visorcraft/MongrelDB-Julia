# Quickstart

This guide walks through installing the MongrelDB Julia client, connecting to a
running `mongreldb-server`, and doing your first round-trip of CRUD and query.

## Prerequisites

- Julia 1.9 or newer.
- The standard library only (Sockets is part of Base, JSON is vendored).
- A running [`mongreldb-server`](https://github.com/visorcraft/MongrelDB)
  daemon. The simplest start is the prebuilt Linux binary:

  ```sh
  curl -L -o mongreldb-server \
    https://github.com/visorcraft/MongrelDB/releases/download/v0.53.3/mongreldb-server-linux-x64
  chmod +x mongreldb-server
  ./mongreldb-server ./data --port 8453
  ```

## Install

Add this package to your environment, or copy `src/` into your load path:

```sh
julia --project=. -e 'using Pkg; Pkg.develop(path=".")'
```

The client has no external package dependencies beyond Julia's standard
library, so there is nothing extra to install from the General registry.

## Connect

```julia
using MongrelDB

db = MongrelDB.connect("http://127.0.0.1:8453")
println(MongrelDB.health(db))   # true
```

## Create a table and insert rows

```julia
# The daemon requires JSON booleans for primary_key / nullable. Per-column
# extras like `enum_variants`, scalar `default_value`, and dynamic
# `default_expr` are passed through verbatim — the client does not
# interpret them, so any key the engine accepts lands on the wire unchanged.
T, F = true, false
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
    Dict("id" => 6, "name" => "optional",   "ty" => "varchar",
         "default_value" => nothing,
         "primary_key" => F, "nullable" => T),
])

# Cells map column id to value.
MongrelDB.put(db, "orders", Dict(1 => 1, 2 => "Alice", 3 => 99.50))
MongrelDB.put(db, "orders", Dict(1 => 2, 2 => "Bob",   3 => 150.00))

println(MongrelDB.count(db, "orders"))   # 2
```

## Run a query

```julia
rows, _ = MongrelDB.query(db, "orders", [
    MongrelDB.condition("pk", Dict("value" => 1)),
])
```

## History retention and time travel

Set how many epochs of history the daemon keeps, then query older snapshots
with `AS OF EPOCH`. Increasing the window cannot bring back history that has
already been garbage-collected.

```julia
MongrelDB.setHistoryRetentionEpochs(db, 1_000_000)

MongrelDB.historyRetentionEpochs(db)  # => 1000000
MongrelDB.earliestRetainedEpoch(db)   # => oldest readable epoch

# Read the table as it existed at epoch 42.
MongrelDB.sql(db, "SELECT * FROM orders AS OF EPOCH 42 WHERE id = 1")
```

## Next steps

- [Transactions](transactions.md) for atomic multi-op commits.
- [Queries](queries.md) for the native index condition API.
- [SQL](sql.md) for DataFusion-backed ad-hoc SQL.
- [Auth](auth.md) for Bearer and Basic authentication.
- [Errors](errors.md) for the exception hierarchy.
