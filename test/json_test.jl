# Pure unit tests for the MongrelDB Julia client.
#
# No daemon is needed. These tests exercise the vendored JSON encoder/decoder
# behavior, the cell-flattening helper, and the condition alias
# normalization, so the wire-format contract stays covered offline.
#
#   julia --project=. test/json_test.jl

using MongrelDB
using Test

@testset "JSON encode/decode" begin
    # Scalars round-trip cleanly.
    @test JSON.decode(JSON.encode(42)) == 42
    @test JSON.decode(JSON.encode("hello")) == "hello"
    @test JSON.decode(JSON.encode(true)) === true
    @test JSON.decode(JSON.encode(false)) === false
    @test JSON.decode(JSON.encode(nothing)) === nothing

    # Floats keep their value.
    @test JSON.decode(JSON.encode(3.14)) == 3.14

    # Arrays and objects.
    @test JSON.decode(JSON.encode([1, 2, 3])) == Any[1, 2, 3]
    @test JSON.decode(JSON.encode(Dict("a" => 1, "b" => 2))) == Dict("a" => 1, "b" => 2)

    # UTF-8 strings survive the round-trip.
    @test JSON.decode(JSON.encode("mångrel")) == "mångrel"

    # Special characters are escaped and round-trip.
    @test JSON.decode(JSON.encode("a\"b\\c\nd")) == "a\"b\\c\nd"
end

@testset "JSON rejects non-finite" begin
    @test_throws ArgumentError JSON.encode([NaN])
    @test_throws ArgumentError JSON.encode([Inf])
    @test_throws ArgumentError JSON.encode([-Inf])
end

@testset "JSON decoder edge cases" begin
    @test JSON.decode("null") === nothing
    @test JSON.decode("true") === true
    @test JSON.decode("123") === 123
    @test JSON.decode("3.5") === 3.5
    @test JSON.decode("\"emoji: \\u00e9\"") == "emoji: é"
    @test JSON.decode("[1, 2, 3]") == Any[1, 2, 3]
    @test JSON.decode("  {  \"x\"  :  7  }  ") == Dict("x" => 7)
    @test JSON.decode("[]") == Any[]
    @test JSON.decode("{}") == Dict{String,Any}()
end

@testset "cell flattening" begin
    # Sorted ascending, interleaved [id, value, ...].
    @test MongrelDB.flatten_cells(Dict(3 => 99.5, 1 => 1, 2 => "Alice")) ==
        Any[1, 1, 2, "Alice", 3, 99.5]
    @test MongrelDB.flatten_cells(Dict{Int,Any}()) == Any[]
    @test MongrelDB.flatten_cells(Dict(1 => "x")) == Any[1, "x"]
end

@testset "condition aliases" begin
    @test MongrelDB.condition("range", Dict("column" => 3, "min" => 10.0, "max" => 100.0)) ==
        Dict("range" => Dict("column_id" => 3, "lo" => 10.0, "hi" => 100.0))
    @test MongrelDB.condition("pk", Dict("value" => 42)) ==
        Dict("pk" => Dict("value" => 42))
    @test MongrelDB.condition("fm_contains", Dict("column" => 2, "value" => "database")) ==
        Dict("fm_contains" => Dict("column_id" => 2, "pattern" => "database"))
    # Canonical wire keys pass through.
    @test MongrelDB.condition("range", Dict("column_id" => 3, "lo" => 1, "hi" => 9)) ==
        Dict("range" => Dict("column_id" => 3, "lo" => 1, "hi" => 9))
end

@testset "error object" begin
    e = MongrelDBError(:constraint, "dup", "UNIQUE_VIOLATION", 1, 409)
    @test e.kind == :constraint
    @test e.error_code == "UNIQUE_VIOLATION"
    @test e.op_index == 1
    @test occursin("constraint", sprint(showerror, e))
    @test occursin("UNIQUE_VIOLATION", sprint(showerror, e))
end

@testset "connect parses URL" begin
    c = MongrelDB.connect("http://127.0.0.1:8453")
    @test c.host == "127.0.0.1"
    @test c.port == 8453
    @test c.auth_header === nothing

    c2 = MongrelDB.connect("http://example.com"; token = "t")
    @test c2.host == "example.com"
    @test c2.port == 80
    @test c2.auth_header == "Bearer t"

    # Basic auth is base64-encoded.
    c3 = MongrelDB.connect("http://h:9"; username = "u", password = "p")
    @test startswith(c3.auth_header, "Basic ")
end

@testset "createTable wire shape" begin
    # Regression case: a column without enum_variants or default_value must
    # NOT carry those keys in the encoded JSON body. This catches an
    # accidental future change that would inject an empty/None key.
    T, F = true, false
    plain_columns = [
        Dict("id" => 1, "name" => "id",     "ty" => "int64",   "primary_key" => T, "nullable" => F),
        Dict("id" => 2, "name" => "label",  "ty" => "varchar", "primary_key" => F, "nullable" => F),
    ]
    plain_body = MongrelDB._create_table_body("orders", plain_columns)
    plain_json = JSON.encode(plain_body)
    @test occursin("\"name\":\"orders\"", plain_json)
    @test !occursin("enum_variants", plain_json)
    @test !occursin("default_value", plain_json)
    @test !occursin("default_expr", plain_json)

    # When a column declares `enum_variants` and `default_value`, both keys
    # must appear verbatim in the encoded JSON, with the variant list and
    # the default expression preserved exactly. The server reads
    # `enum_variants` for the enum type and accepts `default_value` as a
    # legacy alias for `default_expr`; the client must not mangle or drop
    # either.
    fancy_columns = [
        Dict("id" => 1, "name" => "id",         "ty" => "int64",          "primary_key" => T, "nullable" => F),
        Dict("id" => 2, "name" => "status",     "ty" => "enum",
             "enum_variants" => ["draft", "paid", "shipped"],
             "primary_key" => F, "nullable" => F),
        Dict("id" => 3, "name" => "created_at", "ty" => "timestamp_nanos",
             "default_value" => "now",
             "primary_key" => F, "nullable" => F),
    ]
    constraints = Dict("checks" => [Dict(
        "id" => 1,
        "name" => "id_present",
        "expr" => Dict("IsNotNull" => 1),
    )])
    body = MongrelDB._create_table_body("events", fancy_columns;
        constraints=constraints)
    json = JSON.encode(body)

    # Both keys present verbatim (as JSON object keys, not substrings of
    # values). The encoder quotes string keys, so the substring check
    # `"enum_variants":` is exact.
    @test occursin("\"enum_variants\":", json)
    @test occursin("\"default_value\":\"now\"", json)
    # Variant list is preserved in order.
    @test occursin("[\"draft\",\"paid\",\"shipped\"]", json)
    # The regression keys are still absent for the columns that did not set
    # them, so the body stays minimal.
    @test !occursin("default_expr", json)

    # Round-trip decode: both keys survive the wire format on the way back
    # too, so a server echoing the column would not lose them.
    decoded = JSON.decode(json)
    @test decoded["name"] == "events"
    @test length(decoded["columns"]) == 3
    status_col = decoded["columns"][2]
    @test status_col["enum_variants"] == ["draft", "paid", "shipped"]
    created_col = decoded["columns"][3]
    @test created_col["default_value"] == "now"
    @test decoded["constraints"]["checks"][1]["name"] == "id_present"
end
