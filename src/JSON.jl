# Minimal JSON encoder/decoder for the MongrelDB Julia client.
#
# Self-contained: no external dependencies. The encoder produces compact JSON
# suitable for the daemon's Content-Type: application/json extractors, and
# rejects NaN/Infinity (no valid JSON representation) with an error. The
# decoder is a tolerant recursive parser that accepts the daemon's responses.

module JSON

export encode, decode

# ---------------------------------------------------------------------------
# Encoder
# ---------------------------------------------------------------------------

# Encode a Julia value as compact JSON. Rejects NaN/Inf with an ArgumentError.
function encode(value)::String
    buf = IOBuffer()
    write_value(buf, value)
    return String(take!(buf))
end

function write_value(buf, v)
    T = typeof(v)
    if v === nothing
        write(buf, "null")
    elseif v === true
        write(buf, "true")
    elseif v === false
        write(buf, "false")
    elseif T <: AbstractString
        write_string(buf, String(v))
    elseif T <: Char
        write_string(buf, string(v))
    elseif T <: Number
        write_number(buf, v)
    elseif T <: AbstractDict
        write(buf, '{')
        first = true
        for (k, val) in pairs(v)
            if !first
                write(buf, ',')
            end
            first = false
            write_string(buf, string(k))
            write(buf, ':')
            write_value(buf, val)
        end
        write(buf, '}')
    elseif T <: AbstractArray || T <: AbstractSet
        write(buf, '[')
        first = true
        for val in v
            if !first
                write(buf, ',')
            end
            first = false
            write_value(buf, val)
        end
        write(buf, ']')
    elseif T <: Tuple
        write(buf, '[')
        for (i, val) in enumerate(v)
            if i > 1
                write(buf, ',')
            end
            write_value(buf, val)
        end
        write(buf, ']')
    else
        throw(ArgumentError("cannot JSON-encode value of type $T"))
    end
    return nothing
end

function write_number(buf, v::T) where {T <: Number}
    if isnan(v) || isinf(v)
        throw(ArgumentError("cannot JSON-encode NaN or Infinity"))
    end
    if T <: Integer
        write(buf, string(v))
    else
        # repr keeps full precision; Float64 round-trips cleanly.
        write(buf, repr(Float64(v)))
    end
    return nothing
end

const ESCAPES = Dict(
    '"'  => "\\\"",
    '\\' => "\\\\",
    '\n' => "\\n",
    '\r' => "\\r",
    '\t' => "\\t",
    '\b' => "\\b",
    '\f' => "\\f",
)

function write_string(buf, s::String)
    write(buf, '"')
    for ch in s
        if ch < ' '
            esc = get(ESCAPES, ch, nothing)
            if esc !== nothing
                write(buf, esc)
            else
                # Manual \uXXXX (avoid pulling in Printf as a dependency).
                write(buf, "\\u", string(UInt32(ch), base = 16, pad = 4))
            end
        elseif haskey(ESCAPES, ch)
            write(buf, ESCAPES[ch])
        else
            write(buf, ch)
        end
    end
    write(buf, '"')
    return nothing
end

# ---------------------------------------------------------------------------
# Decoder
# ---------------------------------------------------------------------------

# Decode a JSON string into a Julia value. Objects become Dict{String,Any},
# arrays become Vector{Any}, numbers stay numbers, and the literals
# true/false/null become true/false/nothing.
function decode(s::AbstractString)
    bytes = codeunits(s)
    pos = 1
    skipws(bytes, pos)
    value, pos = parse_value(bytes, pos)
    skipws(bytes, pos)
    return value
end

@inline function skipws(b, pos)
    @inbounds while pos <= length(b) && (b[pos] === 0x20 || b[pos] === 0x09 ||
                                          b[pos] === 0x0a || b[pos] === 0x0d)
        pos += 1
    end
    return pos
end

function parse_value(b, pos)
    pos = skipws(b, pos)
    @inbounds c = b[pos]
    if c === 0x7b            # '{'
        return parse_object(b, pos)
    elseif c === 0x5b        # '['
        return parse_array(b, pos)
    elseif c === 0x22        # '"'
        return parse_string(b, pos)
    elseif c === 0x74        # 't' -> true
        return true, pos + 4
    elseif c === 0x66        # 'f' -> false
        return false, pos + 5
    elseif c === 0x6e        # 'n' -> null
        return nothing, pos + 4
    elseif c === 0x2d || (0x30 <= c <= 0x39)   # '-' or digit
        return parse_number(b, pos)
    else
        error("unexpected character at position $pos")
    end
end

function parse_object(b, pos)
    @inbounds pos += 1   # consume '{'
    result = Dict{String,Any}()
    pos = skipws(b, pos)
    @inbounds if b[pos] === 0x7d   # '}'
        return result, pos + 1
    end
    while true
        pos = skipws(b, pos)
        key, pos = parse_string(b, pos)
        pos = skipws(b, pos)
        @inbounds if b[pos] !== 0x3a   # ':'
            error("expected ':' at position $pos")
        end
        pos += 1
        val, pos = parse_value(b, pos)
        result[key] = val
        pos = skipws(b, pos)
        @inbounds c = b[pos]
        if c === 0x2c            # ','
            pos += 1
            continue
        elseif c === 0x7d        # '}'
            return result, pos + 1
        else
            error("expected ',' or '}' at position $pos")
        end
    end
end

function parse_array(b, pos)
    @inbounds pos += 1   # consume '['
    result = Any[]
    pos = skipws(b, pos)
    @inbounds if b[pos] === 0x5d   # ']'
        return result, pos + 1
    end
    while true
        val, pos = parse_value(b, pos)
        push!(result, val)
        pos = skipws(b, pos)
        @inbounds c = b[pos]
        if c === 0x2c            # ','
            pos += 1
            continue
        elseif c === 0x5d        # ']'
            return result, pos + 1
        else
            error("expected ',' or ']' at position $pos")
        end
    end
end

function parse_string(b, pos)
    @inbounds pos += 1   # consume opening '"'
    chars = Char[]
    @inbounds while pos <= length(b)
        c = b[pos]
        if c === 0x22           # closing '"'
            return String(chars), pos + 1
        elseif c === 0x5c       # backslash escape
            pos += 1
            @inbounds e = b[pos]
            if e === 0x22       push!(chars, '"')
            elseif e === 0x5c   push!(chars, '\\')
            elseif e === 0x2f   push!(chars, '/')
            elseif e === 0x62   push!(chars, '\b')
            elseif e === 0x66   push!(chars, '\f')
            elseif e === 0x6e   push!(chars, '\n')
            elseif e === 0x72   push!(chars, '\r')
            elseif e === 0x74   push!(chars, '\t')
            elseif e === 0x75   # \uXXXX
                cp = parse(UInt32, String(b[pos + 1:pos + 4]); base = 16)
                pos += 4
                push!(chars, Char(cp))
            else
                error("invalid escape '\\$(Char(e))' at position $pos")
            end
            pos += 1
        else
            # Decode UTF-8 by reading a full codepoint from the byte stream.
            ch, len = read_utf8(b, pos)
            push!(chars, ch)
            pos += len
        end
    end
    error("unterminated string")
end

# Read one UTF-8 codepoint starting at pos. Returns (Char, byte_length).
@inline function read_utf8(b, pos)
    @inbounds b1 = b[pos]
    if b1 < 0x80
        return Char(b1), 1
    elseif b1 >> 5 == 0b110
        @inbounds cp = ((UInt32(b1) & 0x1f) << 12) |
                       (UInt32(b[pos + 1]) & 0x3f) << 6 |
                       (UInt32(b[pos + 2]) & 0x3f)
        return Char(cp), 3
    elseif b1 >> 4 == 0b1110
        @inbounds cp = ((UInt32(b1) & 0x0f) << 18) |
                       (UInt32(b[pos + 1]) & 0x3f) << 12 |
                       (UInt32(b[pos + 2]) & 0x3f) << 6 |
                       (UInt32(b[pos + 3]) & 0x3f)
        return Char(cp), 4
    else   # 4-byte
        @inbounds cp = ((UInt32(b1) & 0x07) << 24) |
                       (UInt32(b[pos + 1]) & 0x3f) << 18 |
                       (UInt32(b[pos + 2]) & 0x3f) << 12 |
                       (UInt32(b[pos + 3]) & 0x3f) << 6 |
                       (UInt32(b[pos + 4]) & 0x3f)
        return Char(cp), 4
    end
end

function parse_number(b, pos)
    start = pos
    is_float = false
    @inbounds while pos <= length(b)
        c = b[pos]
        if (0x30 <= c <= 0x39) || c === 0x2d || c === 0x2b ||
           c === 0x2e || c === 0x65 || c === 0x45
            if c === 0x2e || c === 0x65 || c === 0x45
                is_float = true
            end
            pos += 1
        else
            break
        end
    end
    text = String(b[start:pos - 1])
    return is_float ? parse(Float64, text) : parse(Int, text), pos
end

end # module
