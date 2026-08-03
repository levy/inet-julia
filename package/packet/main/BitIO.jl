# ============================================================================
# BitWriter / BitReader — bit-granular I/O for header codecs.
#
# Network headers are bit-packed (e.g. IPv4 version|ihl share a byte, TCP flags
# straddle a byte boundary), so a byte-level `IOBuffer` won't do. Reads and
# writes are MSB-first within each byte, which is what "network byte order"
# means at the bit level and what INET's own `Chunk` codecs use.
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

"Write the low `n` bits of `value`, MSB-first."
function write_bits!(w::BitWriter, value::Unsigned, n::Int)
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
# Convenience — signed values get bit-cast to the matching unsigned width.
write_bits!(w::BitWriter, value::Integer, n::Int) = write_bits!(w, unsigned(value), n)
write_bits!(w::BitWriter, value::Bool, n::Int)    = write_bits!(w, UInt8(value), n)

# ---------- reader -----------------------------------------------------------

mutable struct BitReader
    bytes::Vector{UInt8}
    bit_pos::Int
    total::Int
end
BitReader(bytes::Vector{UInt8}) = BitReader(bytes, 0, Base.length(bytes) * 8)
BitReader(bytes::Vector{UInt8}, total_bits::Int) = BitReader(bytes, 0, total_bits)

remaining(r::BitReader) = r.total - r.bit_pos

"Read `n` bits as a `UInt64`, MSB-first."
function read_bits!(r::BitReader, n::Int)::UInt64
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
