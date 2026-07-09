# Live integration tests for the MongrelDB Julia client.
#
# These tests round-trip data through every public method against a real
# mongreldb-server. They skip automatically when no daemon is reachable at
# the URL in MONGRELDB_URL (default http://127.0.0.1:8453), so the suite
# still passes offline.
#
#   MONGRELDB_URL=http://127.0.0.1:8453 julia --project=. test/live_test.jl

using MongrelDB
using Test

const SERVER_URL = get(ENV, "MONGRELDB_URL", "http://127.0.0.1:8453")

# Probe the daemon once. If it is not up, skip every live test.
function server_reachable()
    db = MongrelDB.connect(SERVER_URL)
    try
        return MongrelDB.health(db)
    catch
        return false
    end
end

if !server_reachable()
    @info "Skipping live tests: MONGRELDB_URL not reachable at $SERVER_URL"
else
    # `time()` returns a Float64 (e.g. 1.78e9); stringify it as an integer so
    # the table name has no '.' — a dot breaks the SQL parser in the
    # `INSERT INTO <table>` round-trip test below.
    unique_suffix = string(round(Int, time()))

    T = true
    F = false
    function make_columns()
        return [
            Dict("id" => 1, "name" => "id",     "ty" => "int64",   "primary_key" => T, "nullable" => F),
            Dict("id" => 2, "name" => "label",  "ty" => "varchar", "primary_key" => F, "nullable" => F),
            Dict("id" => 3, "name" => "amount", "ty" => "float64", "primary_key" => F, "nullable" => F),
        ]
    end

    @testset "live: health" begin
        db = MongrelDB.connect(SERVER_URL)
        @test MongrelDB.health(db) == true
    end

    @testset "live: createTable, put, count, query" begin
        db = MongrelDB.connect(SERVER_URL)
        table = "julia_items_" * unique_suffix
        MongrelDB.createTable(db, table, make_columns())
        MongrelDB.put(db, table, Dict(1 => 1, 2 => "alpha", 3 => 10.0))
        MongrelDB.put(db, table, Dict(1 => 2, 2 => "beta",  3 => 25.0))
        @test MongrelDB.count(db, table) == 2
        rows, _ = MongrelDB.query(db, table,
            [MongrelDB.condition("pk", Dict("value" => 2))])
        @test length(rows) >= 1
    end

    @testset "live: upsert updates on PK conflict" begin
        db = MongrelDB.connect(SERVER_URL)
        table = "julia_upsert_" * unique_suffix
        MongrelDB.createTable(db, table, make_columns())
        MongrelDB.put(db, table, Dict(1 => 1, 2 => "alpha", 3 => 10.0))
        MongrelDB.upsert(db, table, Dict(1 => 1, 2 => "alpha", 3 => 99.0), Dict(3 => 99.0))
        @test MongrelDB.count(db, table) == 1
    end

    @testset "live: transaction commits multiple ops atomically" begin
        db = MongrelDB.connect(SERVER_URL)
        table = "julia_txn_" * unique_suffix
        MongrelDB.createTable(db, table, make_columns())
        MongrelDB.transaction(db, [
            Dict("put" => Dict("table" => table, "cells" => Any[1, 10, 2, "dave", 3, 50.0])),
            Dict("put" => Dict("table" => table, "cells" => Any[1, 11, 2, "eve",  3, 75.0])),
        ])
        @test MongrelDB.count(db, table) == 2
        # delete_by_pk in a follow-up txn removes the row.
        MongrelDB.transaction(db, [
            Dict("delete_by_pk" => Dict("table" => table, "pk" => 10)),
        ])
        @test MongrelDB.count(db, table) == 1
    end

    @testset "live: sql round-trips" begin
        db = MongrelDB.connect(SERVER_URL)
        table = "julia_sql_" * unique_suffix
        MongrelDB.createTable(db, table, make_columns())
        MongrelDB.put(db, table, Dict(1 => 1, 2 => "alpha", 3 => 1.0))
        MongrelDB.sql(db, "INSERT INTO $table (id, label, amount) VALUES (2, 'beta', 2.0)")
        @test MongrelDB.count(db, table) == 2
    end

    @testset "live: schema lists the created table" begin
        db = MongrelDB.connect(SERVER_URL)
        table = "julia_schema_" * unique_suffix
        MongrelDB.createTable(db, table, make_columns())
        names = MongrelDB.tables(db)
        @test table in names
        desc = MongrelDB.schemaFor(db, table)
        @test !isempty(desc)
    end
end
