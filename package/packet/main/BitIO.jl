# ============================================================================
# BitWriter / BitReader — bit-granular I/O for header codecs.
#
# Network headers are bit-packed (e.g. IPv4 version|ihl share a byte, TCP flags
# straddle a byte boundary), so a byte-level `IOBuffer` won't do. Reads and
# writes are MSB-first within each byte, which is what "network byte order"
# means at the bit level and what INET's own `Chunk` codecs use.
#
# Byte order is a per-call argument, `:be` or `:le`. Big-endian is the default
# and network order. IEEE 802.11 is the reason `:le` exists: it writes its
# Duration, Sequence Control and BA Control fields least significant byte
# first, and a codec that assumes network order everywhere gets them wrong.
# A little-endian field must be a whole number of bytes — the byte is the unit
# the order applies to, so the question has no answer for a 12-bit field.
#
# These are private to the packet module — user headers call `write_bits!` and
# `read_bits!` from generated `serialize` / `deserialize` methods.
# ============================================================================

mutable struct BitWriter
    bytes::Vector{UInt8}
    bit_count::Int
end
BitWriter() = BitWriter(UInt8[], 0)

bit_count(w::BitWriter) = w.bit_count
bytes(w::BitWriter) = w.bytes

"Reject a byte order that a field of `n` bits cannot have."
function check_order(order::Symbol, n::Int)
    order === :be && return nothing
    order === :le ||
        error("byte order: expected `:be` or `:le`, got `:$(order)`")
    n % 8 == 0 ||
        error("byte order: a little-endian field must be a whole number of bytes, got $n")
    return nothing
end

"Write the low `n` bits of `value`, MSB-first inside each byte."
function write_bits_be!(w::BitWriter, value::Unsigned, n::Int)
    for i in (n-1):-1:0
        bit = UInt8((value >> i) & 0x1)
        byte_idx = (w.bit_count >> 3) + 1
        bit_idx  = w.bit_count & 7
        if byte_idx > Base.length(w.bytes)
            push!(w.bytes, 0x00)
        end
        w.bytes[byte_idx] |= bit << (7 - bit_idx)
        w.bit_count += 1
    end
end

"Write the low `n` bits of `value` in byte order `order`."
function write_bits!(w::BitWriter, value::Unsigned, n::Int, order::Symbol = :be)
    check_order(order, n)
    if order === :be
        write_bits_be!(w, value, n)
    else
        for i in 0:(n >> 3 - 1)
            write_bits_be!(w, (UInt64(value) >> (8 * i)) & 0xff, 8)
        end
    end
end
# Convenience — signed values get bit-cast to the matching unsigned width.
write_bits!(w::BitWriter, value::Integer, n::Int, order::Symbol = :be) =
    write_bits!(w, unsigned(value), n, order)
write_bits!(w::BitWriter, value::Bool, n::Int, order::Symbol = :be) =
    write_bits!(w, UInt8(value), n, order)

# ---------- reader -----------------------------------------------------------

mutable struct BitReader
    bytes::Vector{UInt8}
    bit_pos::Int
    total::Int
end
BitReader(bytes::Vector{UInt8}) = BitReader(bytes, 0, Base.length(bytes) * 8)
BitReader(bytes::Vector{UInt8}, total_bits::Int) = BitReader(bytes, 0, total_bits)

remaining(r::BitReader) = r.total - r.bit_pos

"Write a run of bytes. The writer need not be byte-aligned."
function write_bytes!(w::BitWriter, data::AbstractVector{UInt8})
    for byte in data
        write_bits_be!(w, byte, 8)
    end
    return w
end

"Write `count` copies of `byte`."
function write_byte_repeatedly!(w::BitWriter, byte::UInt8, count::Int)
    for _ in 1:count
        write_bits_be!(w, byte, 8)
    end
    return w
end

"""
    pad_bits(offset::Int, boundary::BitLength)::Int

The number of bits that take `offset` up to the next multiple of `boundary`.
Zero when `offset` already sits on one.
"""
function pad_bits(offset::Int, boundary::BitLength)
    unit = boundary.bits
    unit > 0 || error("@pad: the boundary must be positive, got $boundary")
    over = offset % unit
    return over == 0 ? 0 : unit - over
end

"Read `n` bits as a `UInt64`, MSB-first inside each byte."
function read_bits_be!(r::BitReader, n::Int)::UInt64
    r.bit_pos + n <= r.total ||
        error("BitReader: read of $n bits past end (have $(r.total - r.bit_pos))")
    value = UInt64(0)
    for _ in 1:n
        byte_idx = (r.bit_pos >> 3) + 1
        bit_idx  = r.bit_pos & 7
        bit = (r.bytes[byte_idx] >> (7 - bit_idx)) & 0x1
        value = (value << 1) | UInt64(bit)
        r.bit_pos += 1
    end
    return value
end

"Read `n` bits as a `UInt64`, in byte order `order`."
function read_bits!(r::BitReader, n::Int, order::Symbol = :be)::UInt64
    check_order(order, n)
    order === :be && return read_bits_be!(r, n)
    value = UInt64(0)
    for i in 0:(n >> 3 - 1)
        value |= read_bits_be!(r, 8) << (8 * i)
    end
    return value
end

"Read `count` bytes. The reader need not be byte-aligned."
function read_bytes!(r::BitReader, count::Int)
    count >= 0 ||
        error("BitReader: a byte field cannot be $count bytes long")
    data = Vector{UInt8}(undef, count)
    for index in 1:count
        data[index] = UInt8(read_bits_be!(r, 8))
    end
    return data
end

"Skip `n` bits, and refuse to run past the end."
function skip_bits!(r::BitReader, n::Int)
    r.bit_pos + n <= r.total ||
        error("BitReader: skip of $n bits past end (have $(r.total - r.bit_pos))")
    r.bit_pos += n
    return r
end
