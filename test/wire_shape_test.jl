# test/wire_shape_test.jl - Offline wire-format conformance for /kit/create_table.
#
# Mirrors the structure of mongreldb_c/tests/test_wire_shape.c: three column
# cases (basic, with enum_variants, with default_value), each asserting both
# that the relevant keys are present verbatim and that the optional keys are
# absent when not set. No daemon is required; the internal
# `_create_table_body` helper builds the body that createTable would POST.
#
#   julia --project=. test/wire_shape_test.jl

using MongrelDB
using Test

@testset "wire shape: basic column" begin
    # A column without enum_variants or default_value must serialize with the
    # core keys (id, name, ty, primary_key, nullable) and must NOT carry the
    # optional keys, so the body stays minimal.
    T, F = true, false
    col = Dict{String,Any}(
        "id" => 1,
        "name" => "id",
        "ty" => "int64",
        "primary_key" => T,
        "nullable" => F,
    )
    body = MongrelDB._create_table_body("widgets", [col])
    json = JSON.encode(body)

    @test occursin("\"id\":1", json)
    @test occursin("\"name\":\"id\"", json)
    @test occursin("\"ty\":\"int64\"", json)
    @test occursin("\"primary_key\":true", json)
    @test occursin("\"nullable\":false", json)
    @test !occursin("enum_variants", json)
    @test !occursin("default_value", json)
    @test !occursin("default_expr", json)
end

@testset "wire shape: enum_variants column" begin
    # A column declaring enum_variants must serialize the variant list
    # verbatim, in order, while leaving default_value / default_expr off.
    col = Dict{String,Any}(
        "id" => 2,
        "name" => "status",
        "ty" => "varchar",
        "enum_variants" => ["active", "inactive", "pending"],
        "primary_key" => false,
        "nullable" => false,
    )
    body = MongrelDB._create_table_body("widgets", [col])
    json = JSON.encode(body)

    @test occursin("\"enum_variants\":[\"active\",\"inactive\",\"pending\"]", json)
    @test !occursin("default_value", json)
    @test !occursin("default_expr", json)

    # Round-trip: the variant list survives decode unchanged.
    decoded = JSON.decode(json)
    @test decoded["columns"][1]["enum_variants"] ==
        ["active", "inactive", "pending"]
end

@testset "wire shape: default_value column" begin
    # A column declaring default_value (the engine field; the server also
    # accepts default_expr as a legacy alias) must serialize it verbatim and
    # must NOT inject enum_variants when not set.
    col = Dict{String,Any}(
        "id" => 3,
        "name" => "score",
        "ty" => "float64",
        "default_value" => "0.0",
        "primary_key" => false,
        "nullable" => true,
    )
    body = MongrelDB._create_table_body("widgets", [col])
    json = JSON.encode(body)

    @test occursin("\"default_value\":\"0.0\"", json)
    @test !occursin("enum_variants", json)
    @test !occursin("default_expr", json)

    # Round-trip: default_value survives decode unchanged.
    decoded = JSON.decode(json)
    @test decoded["columns"][1]["default_value"] == "0.0"
end