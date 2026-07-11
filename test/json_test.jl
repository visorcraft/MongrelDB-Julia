# Pure unit tests for the MongrelDB Julia client.
#
# No daemon is needed. These tests exercise the vendored JSON encoder/decoder
# behavior, the cell-flattening helper, and the condition alias
# normalization, so the wire-format contract stays covered offline.
#
#   julia --project=. test/json_test.jl

using MongrelDB
using Sockets
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

@testset "createTable static default matrix" begin
    # Full scalar matrix: string, integer, boolean, explicit null, literal
    # "now" string, and dynamic default_expr "now"/"uuid". Decoded request
    # JSON must preserve each type and keep default_expr separate from
    # default_value.
    columns = [
        Dict{String,Any}("id" => 1, "name" => "status",      "ty" => "varchar",         "default_value" => "draft"),
        Dict{String,Any}("id" => 2, "name" => "score",       "ty" => "int64",           "default_value" => 7),
        Dict{String,Any}("id" => 3, "name" => "active",      "ty" => "bool",            "default_value" => true),
        Dict{String,Any}("id" => 4, "name" => "optional",    "ty" => "varchar",         "default_value" => nothing),
        Dict{String,Any}("id" => 5, "name" => "literal_now", "ty" => "varchar",         "default_value" => "now"),
        Dict{String,Any}("id" => 6, "name" => "created_at",  "ty" => "timestamp_nanos", "default_expr" => "now"),
        Dict{String,Any}("id" => 7, "name" => "gen_uuid",    "ty" => "uuid",            "default_expr" => "uuid"),
    ]
    body = MongrelDB._create_table_body("defaults", columns)
    decoded = JSON.decode(JSON.encode(body))
    by_name = Dict(col["name"] => col for col in decoded["columns"])

    @test by_name["status"]["default_value"] == "draft"
    @test by_name["score"]["default_value"] == 7
    @test by_name["active"]["default_value"] === true
    @test by_name["optional"]["default_value"] === nothing
    @test by_name["literal_now"]["default_value"] == "now"
    @test by_name["created_at"]["default_expr"] == "now"
    @test by_name["gen_uuid"]["default_expr"] == "uuid"

    @test !haskey(by_name["created_at"], "default_value")
    @test !haskey(by_name["gen_uuid"], "default_value")
end

# ---------------------------------------------------------------------------
# Mock HTTP server helpers for transport tests (uses only stdlib Sockets).
# ---------------------------------------------------------------------------

# Read one HTTP request from a socket. Returns (method, path, body).
function read_mock_request(sock)
    status_line = chomp(readline(sock, keep=true))
    parts = split(status_line)
    method = String(parts[1])
    path = String(parts[2])
    content_length = 0
    while true
        h = chomp(readline(sock, keep=true))
        isempty(h) && break
        if startswith(lowercase(h), "content-length:")
            content_length = parse(Int, strip(h[length("content-length:") + 1:end]))
        end
    end
    body = content_length > 0 ? String(read(sock, content_length)) : ""
    return method, path, body
end

# Run `handler(client)` against a one-shot HTTP server that returns the given
# response. Returns (captured_request, handler_result). If the handler throws,
# the exception is rethrown after the server shuts down.
function run_mock_server(handler, response_status::Int, response_body::String)
    server = Sockets.listen(Sockets.localhost, 0)
    port = Int(Sockets.getsockname(server)[2])
    captured = Ref{Any}(nothing)
    client_task = @async begin
        client = MongrelDB.connect("http://127.0.0.1:$port")
        handler(client)
    end
    client_sock = Sockets.accept(server)
    try
        method, path, body = read_mock_request(client_sock)
        captured[] = (method=method, path=path, body=body)
        resp = "HTTP/1.1 $(response_status) OK\r\nContent-Type: application/json\r\nContent-Length: $(length(response_body))\r\nConnection: close\r\n\r\n" * response_body
        write(client_sock, resp)
    finally
        close(client_sock)
        close(server)
    end
    result = try
        fetch(client_task)
    catch e
        # Julia wraps task failures in TaskFailedException; unwrap so callers
        # see the original MongrelDBError (or other handler exception).
        e isa TaskFailedException ? rethrow(e.task.exception) : rethrow(e)
    end
    return captured[], result
end

@testset "history retention transport: GET parses response keys" begin
    response = JSON.encode(Dict("history_retention_epochs" => 7, "earliest_retained_epoch" => 3))
    captured, result = run_mock_server(db -> MongrelDB.historyRetention(db), 200, response)
    @test captured.method == "GET"
    @test captured.path == "/history/retention"
    @test captured.body == ""
    @test result.history_retention_epochs == 7
    @test result.earliest_retained_epoch == 3
end

@testset "history retention transport: getter convenience methods" begin
    response = JSON.encode(Dict("history_retention_epochs" => 7, "earliest_retained_epoch" => 3))
    _, epochs = run_mock_server(db -> MongrelDB.historyRetentionEpochs(db), 200, response)
    @test epochs == 7
    _, earliest = run_mock_server(db -> MongrelDB.earliestRetainedEpoch(db), 200, response)
    @test earliest == 3
end

@testset "history retention transport: PUT body and response keys" begin
    response = JSON.encode(Dict("history_retention_epochs" => 42, "earliest_retained_epoch" => 1))
    captured, result = run_mock_server(db -> MongrelDB.setHistoryRetentionEpochs(db, 42), 200, response)
    @test captured.method == "PUT"
    @test captured.path == "/history/retention"
    body = JSON.decode(captured.body)
    @test body == Dict("history_retention_epochs" => 42)
    @test result.history_retention_epochs == 42
    @test result.earliest_retained_epoch == 1
end

@testset "history retention transport: non-2xx propagates" begin
    err_body = JSON.encode(Dict("error" => Dict("message" => "unavailable", "code" => "UNAVAILABLE")))
    for fn in (
        db -> MongrelDB.historyRetentionEpochs(db),
        db -> MongrelDB.earliestRetainedEpoch(db),
        db -> MongrelDB.setHistoryRetentionEpochs(db, 7),
    )
        err = try
            run_mock_server(fn, 503, err_body)
            nothing
        catch e
            e
        end
        @test err isa MongrelDB.MongrelDBError
        @test err.status == 503
    end
end
