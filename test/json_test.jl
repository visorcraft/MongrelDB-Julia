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
