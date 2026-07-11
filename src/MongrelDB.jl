# MongrelDB Julia client.
#
# Pure Julia HTTP client for mongreldb-server. Talks JSON over the Kit
# transaction, query, and SQL endpoints, with a small typed exception
# hierarchy and a native query builder.
#
# Depends only on the standard library (Sockets, which ships with Base). JSON
# is vendored in JSON.jl alongside this file, so there are no external package
# dependencies to install.
#
# Usage:
#   using MongrelDB
#   db = MongrelDB.connect("http://127.0.0.1:8453")
#   MongrelDB.createTable(db, "orders", columns)
#   MongrelDB.put(db, "orders", Dict(1 => 1, 2 => "Alice", 3 => 99.5))

module MongrelDB

import Sockets

# The vendored JSON encoder/decoder lives in src/JSON.jl as a submodule.
# Include it (defining `module JSON`) before importing the name so the
# binding is declared at import time; otherwise precompilation fails with
# "Imported binding MongrelDB.JSON was undeclared at import time".
include("JSON.jl")
import .JSON

export Client, MongrelDBError, connect, condition, health, tables, createTable, dropTable,
       count, put, upsert, delete, deleteByPk, sql, query, schema, schemaFor,
       transaction, setHistoryRetentionEpochs, historyRetention,
       historyRetentionEpochs, earliestRetainedEpoch, JSON

# ---------------------------------------------------------------------------
# URL helpers
# ---------------------------------------------------------------------------

# Percent-encode a single path segment so table names containing '/', '?',
# '#', or spaces cannot inject extra segments or break routing. Only RFC
# 3986 unreserved characters pass through unencoded.
function _encode_segment(seg::AbstractString)::String
    out = IOBuffer()
    for c in seg
        if (c in 'A':'Z') || (c in 'a':'z') || (c in '0':'9') ||
           c == '-' || c == '_' || c == '.' || c == '~'
            write(out, c)
        else
            # Encode every byte of the character's UTF-8 representation.
            # `String(c)` does not exist (it rejects a Char); `string(c)`
            # produces the single-character String whose codeunits are the
            # raw UTF-8 bytes, so each byte is percent-encoded correctly.
            for b in codeunits(string(c))
                write(out, '%', uppercase(string(b, base=16, pad=2)))
            end
        end
    end
    return String(take!(out))
end

# Reject CR/LF in a string to prevent CRLF injection into HTTP headers.
function _reject_crlf(value::AbstractString, field::AbstractString)
    if occursin('\r', value) || occursin('\n', value)
        throw(MongrelDBError(:query,
            "illegal CR/LF in $field value"))
    end
end

# ---------------------------------------------------------------------------
# Exception type
# ---------------------------------------------------------------------------

# A MongrelDBError carries a `kind` category so callers can match by category
# in a try/catch. `kind` is one of: :auth, :not_found, :constraint,
# :connection, :query.
struct MongrelDBError <: Exception
    kind::Symbol
    message::String
    error_code::Union{String, Nothing}
    op_index::Union{Int, Nothing}
    status::Union{Int, Nothing}
end

# Convenience constructor for the common shape.
MongrelDBError(kind::Symbol, message::AbstractString) =
    MongrelDBError(kind, String(message), nothing, nothing, nothing)

# Pretty-print so `showerror` reads cleanly.
function Base.showerror(io::IO, e::MongrelDBError)
    print(io, "MongrelDBError($(e.kind)): $(e.message)")
    if e.error_code !== nothing
        print(io, " [code=$(e.error_code)")
        if e.op_index !== nothing
            print(io, ", op_index=$(e.op_index)")
        end
        print(io, "]")
    end
end

# Map an HTTP status code to the right error category.
function kind_for_status(status::Int)::Symbol
    status == 401 && return :auth
    status == 403 && return :auth
    status == 404 && return :not_found
    status == 409 && return :constraint
    return :query
end

# ---------------------------------------------------------------------------
# Aliases for condition parameters (friendly names -> wire keys)
# ---------------------------------------------------------------------------

const ALIAS = Dict{String,String}(
    "column"         => "column_id",
    "min"            => "lo",
    "max"            => "hi",
    "min_inclusive"  => "lo_inclusive",
    "max_inclusive"  => "hi_inclusive",
)

# Translate friendly aliases for one condition into wire keys.
function normalize_condition(cond_type::String, params::Dict)
    out = Dict{String,Any}()
    for (k, v) in params
        key = k
        if (cond_type == "fm_contains" || cond_type == "fm_contains_all") && k == "value"
            key = "pattern"
        end
        out[get(ALIAS, key, key)] = v
    end
    return out
end

"""
    condition(type, params)

Build a normalized condition for `query`. Friendly aliases (`column`, `min`,
`max`) are translated to the server's on-wire keys (`column_id`, `lo`, `hi`).
"""
function condition(cond_type::String, params::Dict)
    return Dict(cond_type => normalize_condition(cond_type, params))
end

# ---------------------------------------------------------------------------
# Client struct and connection
# ---------------------------------------------------------------------------

"""
    Client

A connection to a running mongreldb-server daemon. Construct one with
[`connect`](@ref).
"""
struct Client
    url::String
    host::String
    port::UInt16
    auth_header::Union{String, Nothing}
end

# Parse a "http://host:port" URL into (host, port). Plain HTTP only; TLS must
# terminate in a reverse proxy in front of the daemon.
function parse_url(url::AbstractString)::Tuple{String,UInt16}
    rest = url
    if startswith(rest, "http://")
        # "http://" is 7 characters; skip past the full scheme (index 8 onward)
        # so the leading "/" of the authority is not retained.
        rest = rest[8:end]
    elseif startswith(rest, "https://")
        throw(MongrelDBError(:connection,
            "HTTPS is not supported by the built-in transport; terminate TLS in a reverse proxy"))
    end
    # Strip any trailing path.
    slash = findfirst('/', rest)
    if slash !== nothing
        rest = rest[1:slash - 1]
    end
    colon = findlast(':', rest)
    if colon !== nothing
        host = String(rest[1:colon - 1])
        port = parse(UInt16, rest[colon + 1:end])
    else
        host = String(rest)
        port = UInt16(80)
    end
    return host, port
end

"""
    connect(url; token=nothing, username=nothing, password=nothing)

Connect to a running mongreldb-server daemon. Credentials (when supplied) are
sent only in the `Authorization` header.
"""
function connect(url::String; token::Union{String,Nothing}=nothing,
                 username::Union{String,Nothing}=nothing,
                 password::Union{String,Nothing}=nothing)::Client
    host, port = parse_url(rstrip(url, '/'))
    auth_header = nothing
    if token !== nothing
        _reject_crlf(token, "token")
        auth_header = "Bearer " * token
    elseif username !== nothing
        _reject_crlf(username, "username")
        password !== nothing && _reject_crlf(password, "password")
        creds = username * ":" * (password === nothing ? "" : password)
        auth_header = "Basic " * base64encode(creds)
    end
    return Client(rstrip(url, '/'), host, port, auth_header)
end

# ---------------------------------------------------------------------------
# Transport (stdlib Sockets)
# ---------------------------------------------------------------------------

# Perform a single HTTP/1.1 request over a fresh TCP connection. Returns
# (status, body). Throws a MongrelDBError(:connection) on network failure.
function http_request(client::Client, method::String, path::String,
                      payload::Union{Dict,Nothing})
    headers = Pair{String,String}[
        "Host" => "$(client.host):$(client.port)",
        "Connection" => "close",
        "Accept" => "application/json",
    ]
    if client.auth_header !== nothing
        push!(headers, "Authorization" => client.auth_header)
    end

    content = nothing
    if payload !== nothing
        try
            content = JSON.encode(payload)
        catch e
            throw(MongrelDBError(:query,
                "request payload cannot be JSON-encoded: $(e)"))
        end
        push!(headers, "Content-Type" => "application/json")
        push!(headers, "Content-Length" => string(sizeof(content)))
    end

    # Assemble the raw request.
    req = IOBuffer()
    write(req, method, " /", path, " HTTP/1.1\r\n")
    for (k, v) in headers
        write(req, k, ": ", v, "\r\n")
    end
    write(req, "\r\n")
    if content !== nothing
        write(req, content)
    end

    sock = try
        Sockets.connect(client.host, client.port)
    catch e
        throw(MongrelDBError(:connection,
            "cannot connect to $(client.host):$(client.port): $(e)"))
    end
    raw = try
        sockio = IOContext(sock)
        write(sockio, take!(req))
        flush(sockio)
        # Read the full response (Connection: close means read until EOF).
        read(sock, String)
    catch e
        throw(MongrelDBError(:connection,
            "I/O error talking to $(client.host):$(client.port): $(e)"))
    finally
        close(sock)
    end

    return parse_http_response(raw)
end

# Split a raw HTTP response into (status, body). Splits on the first blank
# line (\r\n\r\n, falling back to \n\n).
function parse_http_response(raw::String)
    sep = findfirst("\r\n\r\n", raw)
    body_start = 0
    if sep !== nothing
        body_start = last(sep) + 1
    else
        sep = findfirst("\n\n", raw)
        if sep === nothing
            throw(MongrelDBError(:query, "malformed HTTP response"))
        end
        body_start = last(sep) + 1
    end

    # Status line is the first line. `findfirst` returns a UnitRange over the
    # matched bytes, so take `first(...)` before subtracting.
    first_line_end = findfirst("\r\n", raw)
    if first_line_end === nothing
        first_line_end = findfirst("\n", raw)
    end
    status_line = first_line_end === nothing ? raw : raw[1:first(first_line_end) - 1]
    m = match(r"HTTP/\d\.\d (\d+)", status_line)
    status = m === nothing ? 0 : parse(Int, m.captures[1])

    body = body_start <= ncodeunits(raw) ? raw[body_start:end] : ""
    return status, body
end

# Decode the daemon's {"error":{"message":...,"code":...,"op_index":...}}
# envelope when present. Returns (message, code, op_index).
function parse_error_envelope(body::String)
    isempty(body) && return (body, nothing, nothing)
    decoded = try
        JSON.decode(body)
    catch
        return (body, nothing, nothing)
    end
    if decoded isa Dict
        err = get(decoded, "error", nothing)
        if err isa Dict
            message = get(err, "message", body)
            code = get(err, "code", nothing)
            op_index = get(err, "op_index", nothing)
            return (message isa String ? message : body,
                    code isa String ? code : nothing,
                    op_index isa Int ? op_index : nothing)
        elseif err isa String
            return (err, nothing, nothing)
        end
    end
    return (body, nothing, nothing)
end

# Core request helper. Returns the decoded JSON body (or nothing for empty
# bodies). Throws a MongrelDBError of the appropriate category for non-2xx or
# network failures.
function _request(client::Client, method::String, path::String,
                  payload::Union{Dict,Nothing}=nothing)
    status, body = http_request(client, method, path, payload)

    # Cap the response body at 256 MB so a runaway query or a misbehaving
    # daemon cannot exhaust memory.
    max_bytes = 256 * 1024 * 1024  # 268435456 bytes
    if sizeof(body) > max_bytes
        throw(MongrelDBError(:query,
            "response body exceeds $max_bytes bytes ($(sizeof(body)) bytes)"))
    end

    if !(200 <= status < 300)
        message, code, op_index = parse_error_envelope(body)
        if isempty(message)
            message = "Server error ($status)"
        end
        throw(MongrelDBError(kind_for_status(status), message, code,
                             op_index, status))
    end

    isempty(body) && return nothing
    # The client requests the JSON result format; guard against a non-JSON
    # body (e.g. a legacy server that ignored the format hint) so sql() stays
    # best-effort and returns nothing instead of raising.
    return try
        JSON.decode(body)
    catch
        nothing
    end
end

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

"""
    health(client)

Check daemon health. Returns `true` on success, `false` on failure (never
throws, so it is safe for startup checks).
"""
function health(client::Client)::Bool
    try
        _request(client, "GET", "health")
        return true
    catch e
        e isa MongrelDBError && return false
        rethrow(e)
    end
end

"""List all table names."""
function tables(client::Client)::Vector{String}
    data = _request(client, "GET", "tables")
    data isa AbstractVector ? collect(String, data) : String[]
end

function _history_retention(data)
    data isa Dict || throw(MongrelDBError(:query, "malformed history retention response"))
    (history_retention_epochs=Int(data["history_retention_epochs"]),
     earliest_retained_epoch=Int(data["earliest_retained_epoch"]))
end

historyRetention(client::Client) = _history_retention(_request(client, "GET", "history/retention"))
setHistoryRetentionEpochs(client::Client, epochs::Integer) = _history_retention(
    _request(client, "PUT", "history/retention", Dict("history_retention_epochs" => epochs)))
historyRetentionEpochs(client::Client) = historyRetention(client).history_retention_epochs
earliestRetainedEpoch(client::Client) = historyRetention(client).earliest_retained_epoch

"""Create a table. Pass `constraints` for engine checks. Returns the table id."""
function createTable(client::Client, name::String, columns; constraints=nothing)::Int
    data = _request(client, "POST", "kit/create_table",
        _create_table_body(name, columns; constraints=constraints))
    data isa Dict ? Int(get(data, "table_id", 0)) : 0
end

# Build the JSON body for a `POST /kit/create_table` request. The body
# forwards the column list as-is, so per-column keys like `enum_variants`
# and `default_value` (the engine field name; the server also accepts
# `default_expr`) survive the encode untouched. Extracted so the wire
# shape can be asserted in a unit test without touching a socket.
function _create_table_body(name::AbstractString, columns; constraints=nothing)::Dict
    body = Dict("name" => name, "columns" => columns)
    constraints === nothing || (body["constraints"] = constraints)
    return body
end

"""Drop a table by name."""
function dropTable(client::Client, name::String)
    _request(client, "DELETE", "tables/" * _encode_segment(name))
    return nothing
end

"""Row count for a table."""
function Base.count(client::Client, table::String)::Int
    data = _request(client, "GET", "tables/" * _encode_segment(table) * "/count")
    if data isa Dict && haskey(data, "count") && data["count"] isa Number
        return Int(data["count"])
    end
    throw(MongrelDBError(:query, "malformed count response from server"))
end

"""Insert a row. `cells` maps column id to value."""
function put(client::Client, table::String, cells::Dict)
    data = _request(client, "POST", "kit/txn",
        Dict("ops" => [Dict("put" =>
            Dict("table" => table, "cells" => flatten_cells(cells)))]))
    first_result(data)
end

"""Upsert (insert or update on PK conflict)."""
function upsert(client::Client, table::String, cells::Dict,
                update_cells::Union{Dict,Nothing}=nothing)
    op = Dict("table" => table, "cells" => flatten_cells(cells))
    if update_cells !== nothing
        op["update_cells"] = flatten_cells(update_cells)
    end
    data = _request(client, "POST", "kit/txn",
        Dict("ops" => [Dict("upsert" => op)]))
    first_result(data)
end

"""Delete a row by its internal row id."""
function delete(client::Client, table::String, row_id::Int)
    _request(client, "POST", "kit/txn",
        Dict("ops" => [Dict("delete" =>
            Dict("table" => table, "row_id" => row_id))]))
    return nothing
end

"""Delete a row by its primary key value."""
function deleteByPk(client::Client, table::String, pk)
    _request(client, "POST", "kit/txn",
        Dict("ops" => [Dict("delete_by_pk" =>
            Dict("table" => table, "pk" => pk))]))
    return nothing
end

"""
    sql(client, statement)

Execute SQL, requesting the JSON result format. A SELECT returns a JSON array
of row objects keyed by column name; statements like INSERT/UPDATE that
produce no rows return `nothing`.
"""
function sql(client::Client, statement::String)
    _request(client, "POST", "sql",
        Dict("sql" => statement, "format" => "json"))
end

"""
    query(client, table, conditions=Dict[]; projection=nothing, limit=nothing)

Run a native query. `conditions` is a vector of `Dict(type => params)` (see
[`condition`](@ref)). Returns `(rows, truncated)`.
"""
function query(client::Client, table::String,
               conditions::AbstractVector=Dict[];
               projection::Union{AbstractVector,Nothing}=nothing,
               limit::Union{Int,Nothing}=nothing)::Tuple{Vector,Bool}
    payload = Dict{String,Any}("table" => table)
    if !isempty(conditions)
        payload["conditions"] = collect(conditions)
    end
    projection !== nothing && (payload["projection"] = collect(projection))
    limit !== nothing && (payload["limit"] = limit)
    data = _request(client, "POST", "kit/query", payload)
    data isa Dict || return (Any[], false)
    rows = get(data, "rows", Any[])
    truncated = get(data, "truncated", false)
    return (rows isa AbstractVector ? collect(rows) : Any[],
            truncated === true)
end

# Note: there is no separate `query(client, table; kwargs...)` convenience
# overload. The main method already defaults `conditions` to `Dict[]`, so
# `query(c, "t")` and `query(c, "t"; projection=...)` resolve to it directly.
# Defining a keyword-only overload triggered a method-overwrite precompilation
# error ("Method definition query(Client, String) ... overwritten").

"""Full schema catalog (dict of table name -> descriptor)."""
function schema(client::Client)::Dict{String,Any}
    data = _request(client, "GET", "kit/schema")
    data isa Dict ? get(data, "tables", Dict{String,Any}()) : Dict{String,Any}()
end

"""Descriptor for a single table."""
function schemaFor(client::Client, table::String)::Dict{String,Any}
    data = _request(client, "GET", "kit/schema/" * _encode_segment(table))
    data isa Dict ? data : Dict{String,Any}()
end

"""
    transaction(client, ops, idempotency_key=nothing)

Stage and commit a batch transaction atomically. `ops` is a vector of
`Dict("put" => ...)`, `Dict("upsert" => ...)`, `Dict("delete" => ...)`,
`Dict("delete_by_pk" => ...)`. Optional idempotency key for safe retries.
"""
function transaction(client::Client, ops::AbstractVector,
                     idempotency_key::Union{String,Nothing}=nothing)::Vector
    payload = Dict{String,Any}("ops" => collect(ops))
    if idempotency_key !== nothing
        payload["idempotency_key"] = idempotency_key
    end
    data = _request(client, "POST", "kit/txn", payload)
    if data isa Dict && haskey(data, "results") && data["results"] isa AbstractVector
        return collect(data["results"])
    end
    return Any[]
end

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

# Flatten Dict(col_id => value) into [col_id, value, col_id, value, ...]
# to match the on-wire shape for batch ops. Column ids sorted ascending.
function flatten_cells(cells::Dict)::Vector{Any}
    flat = Any[]
    for k in sort(collect(keys(cells)))
        push!(flat, isa(k, Integer) ? Int(k) : k)
        push!(flat, cells[k])
    end
    return flat
end

# Pull the first per-op result out of a txn response.
function first_result(data)::Dict{String,Any}
    if data isa Dict && haskey(data, "results") && data["results"] isa AbstractVector
        v = data["results"]
        return isempty(v) ? Dict{String,Any}() :
               (v[1] isa Dict ? Dict{String,Any}(v[1]) : Dict{String,Any}())
    end
    return Dict{String,Any}()
end

# ---------------------------------------------------------------------------
# Tiny base64 encoder (avoids adding a dependency for HTTP Basic auth).
# ---------------------------------------------------------------------------

const B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

function base64encode(s::String)::String
    bytes = codeunits(s)
    out = Char[]
    i = 1
    n = length(bytes)
    while i <= n
        a = UInt32(bytes[i])
        b = i + 1 <= n ? UInt32(bytes[i + 1]) : UInt32(0)
        c = i + 2 <= n ? UInt32(bytes[i + 2]) : UInt32(0)
        grp = (a << 16) | (b << 8) | c
        push!(out, B64[(grp >> 18) & 0x3f + 1])
        push!(out, B64[(grp >> 12) & 0x3f + 1])
        push!(out, i + 1 <= n ? B64[(grp >> 6) & 0x3f + 1] : '=')
        push!(out, i + 2 <= n ? B64[grp & 0x3f + 1] : '=')
        i += 3
    end
    return String(out)
end

end # module
