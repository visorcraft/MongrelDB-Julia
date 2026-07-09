# Basic CRUD example for the MongrelDB Julia client.
#
# Connects to a running mongreldb-server, creates a table, inserts rows,
# queries them back, and prints the count.
#
#   julia --project=. examples/basic_crud.jl

using MongrelDB

const url = get(ENV, "MONGRELDB_URL", "http://127.0.0.1:8453")
const db = MongrelDB.connect(url)

println("health: ", MongrelDB.health(db))

# Per-run unique suffix so concurrent/CI runs never collide on a table name.
table = "julia_orders_example_$(time_ns())"

# The daemon requires JSON booleans for primary_key / nullable.
T, F = true, false
columns = [
    Dict("id" => 1, "name" => "id",       "ty" => "int64",   "primary_key" => T, "nullable" => F),
    Dict("id" => 2, "name" => "customer", "ty" => "varchar", "primary_key" => F, "nullable" => F),
    Dict("id" => 3, "name" => "amount",   "ty" => "float64", "primary_key" => F, "nullable" => F),
]

try
    MongrelDB.createTable(db, table, columns)

    # Cells map column id to value.
    MongrelDB.put(db, table, Dict(1 => 1, 2 => "Alice", 3 => 99.50))
    MongrelDB.put(db, table, Dict(1 => 2, 2 => "Bob",   3 => 150.00))

    # Upsert updates on PK conflict.
    MongrelDB.upsert(db, table, Dict(1 => 1, 2 => "Alice", 3 => 120.00), Dict(3 => 120.00))

    println("count: ", MongrelDB.count(db, table))

    # Query with a native index condition (primary key match).
    rows, _ = MongrelDB.query(db, table, [MongrelDB.condition("pk", Dict("value" => 1))])
    for r in rows
        println("row: ", join(map(string, r["cells"]), ", "))
    end

    # Run SQL.
    MongrelDB.sql(db, "UPDATE $table SET amount = 200.0 WHERE customer = 'Bob'")
    println("count after sql: ", MongrelDB.count(db, table))
finally
    # Guaranteed cleanup: ALWAYS drop the table, even on error, so CI runs
    # never leave an orphan table behind.
    MongrelDB.dropTable(db, table)
    println("dropped: ", table)
end
