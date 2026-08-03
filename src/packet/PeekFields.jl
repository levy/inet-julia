# ============================================================================
# `peek(c, T)` where T <: Fields — the R2 duality boundary.
#
# The whole point of the API (plan §1, R2): a protocol module names the header
# type it wants and gets that type, regardless of whether the packet is
# currently field-shaped, raw bytes, or a length-only Filler.
#
# The R9 guard (plan §1.1): most cross-type conversions are bugs. Bytes → any
# Fields is free; one Fields type → another is REFUSED unless the caller
# passes `reinterpret = true`. Following INET's `Chunk.cc:120-131` exactly.
# ============================================================================

# The primary dispatch: peek into a Fields target. Default `length` to the
# TARGET's wire length — a caller who says `peek(pk, Ipv4Header)` almost
# never means "…and reinterpret whatever bits happen to be here", they mean
# "…and give me 20 bytes' worth of Ipv4Header".
function peek(c::Chunk, ::Type{T}; at = nothing, length = nothing,
              reinterpret::Bool = false,
              incomplete::Bool = false,
              incorrect::Bool = false,
              misrepresented::Bool = false,
              kwargs...) where {T<:Fields}
    off = at === nothing ? ZERO_LENGTH : at::BitLength
    len = length === nothing ? chunk_length(T) : length::BitLength
    off + len <= chunk_length(c) ||
        error("peek($T): [$off, $(off+len)) out of bounds of $(chunk_length(c))")
    # A window narrower than T's full wire length is a prefix peek — that's
    # how "have I received the full header yet" works (FieldsChunk.cc:100-106).
    # Rather than deserialise partial bytes, we mark the source incomplete
    # and route through the standard gate.
    src_q = quality(peek(c, Chunk; at = off, length = len))
    if len < chunk_length(T)
        src_q = src_q ⊔ Q_INCOMPLETE
    end
    _check_quality(src_q, T;
        incomplete = incomplete, incorrect = incorrect, misrepresented = misrepresented)
    # Type-preserving fast path: same type, full cover.
    if c isa T && off == ZERO_LENGTH && len == chunk_length(c)
        return c::T
    end
    return _to_fields(T, c, off, len, reinterpret)
end

# Fallback / dispatch entry — walks the tree to a leaf-shape.
function _to_fields(::Type{T}, c::Chunk, off::BitLength, len::BitLength,
                    reinterpret::Bool) where {T<:Fields}
    # A Slice over some target: descend, preserving `reinterpret`.
    if c isa Slice
        return _to_fields(T, c.chunk, c.offset + off, len, reinterpret)
    end

    # A Sequence: materialise the range as Raw, then hit the Raw path.
    if c isa Sequence
        return _to_fields(T, _to_raw(c, off, len), ZERO_LENGTH, len, reinterpret)
    end

    # A different Fields type in the SOURCE — this is the R9 case.
    if c isa Fields
        reinterpret || _throw_r9(typeof(c), T)
        # Round-trip through bytes.
        bs = to_bytes(c)
        return _to_fields(T, Raw(bs), off, len, true)
    end

    # Raw: the primary deserialise path.
    if c isa Raw
        need = chunk_length(T).bits
        len.bits == need ||
            error("peek($T): asked for $len bits, need $need for a full $(T)")
        # Bit-slice: build a BitReader positioned at `off`.
        return _deserialize_from_raw(T, c, off, len)
    end

    # Filler: all-zero bytes over `len`. If `len` is a full header we return
    # a T deserialised from zeros; otherwise it's an incomplete-header shape
    # that Phase 4 will formalise. For now, refuse partial.
    if c isa Filler
        need = chunk_length(T).bits
        len.bits == need ||
            error("peek($T): a Filler window of $len is not a full $(T) ($(need) bits)")
        bs = fill(c.fill, (need + 7) >> 3)
        return deserialize(T, BitReader(bs))
    end

    error("peek($T): no conversion from $(typeof(c))")
end

_throw_r9(from::Type, to::Type) = error("""
peek: refusing to reinterpret $(from) as $(to).
Reading one Fields type as another is almost always a bug — an $(from) is
laid out differently from a $(to). If you really mean it, pass
`reinterpret = true`; the shape is deliberately awkward.
""")

# Deserialise a Fields value out of a Raw at `off`, taking `len` bits.
function _deserialize_from_raw(::Type{T}, r::Raw, off::BitLength, len::BitLength) where {T<:Fields}
    if isbyte(off)
        # Common case: byte-aligned. Just point the reader at the right byte.
        b0 = bytes(off) + 1
        nbytes = (len.bits + 7) >> 3
        return deserialize(T, BitReader(r.data[b0:(b0 + nbytes - 1)], Int(len.bits)))
    end
    # Bit-shifted: read bit-by-bit through a BitReader positioned at `off`.
    reader = BitReader(r.data, Int(chunk_length(r).bits))
    reader.bit_pos = Int(off.bits)
    return deserialize(T, reader)
end

# The packet-level convenience `has(pk, T)` lives in PacketEnvelope.jl,
# since it needs the `Packet` type defined there.
