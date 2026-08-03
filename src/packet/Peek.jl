# ============================================================================
# peek — random access + type-directed representation duality (R2).
#
# `peek(c, T; at, length, ...)` returns a value of type `T` covering the range
# [at, at+length) of `c`. Dispatch on the TARGET type decides how the value is
# built:
#
#   Filler   length only                       free, lossy by design
#   Raw      serialise                          exact
#   Slice    wrap                               free
#   Fields   serialise → deserialise, R9-gated  expensive
#
# The `::T` return annotation is what matters at the boundary: callers get a
# concrete type back, so a protocol path built on `peek` is fully inferable.
# Internally the walk is dynamically dispatched over the chunk tree, exactly
# as INET's is.
#
# Phase 3 fills in the R9 reinterpretation guard and the Fields conversion.
# ============================================================================

# ---------- normalise the (at, length) kwargs to a concrete range ------------

function _peek_range(c::Chunk, at, len)
    off = at === nothing ? ZERO_LENGTH : at::BitLength
    l   = len === nothing ? chunk_length(c) - off : len::BitLength
    off.bits >= 0 || error("peek: negative offset $off")
    l.bits   >= 0 || error("peek: negative length $l")
    off + l <= chunk_length(c) ||
        error("peek: [$off, $(off+l)) out of bounds of $(chunk_length(c))")
    return off, l
end

# Extend Base.peek so `peek(chunk, T)` composes with Julia's stream-peek
# convention (look without consuming). Nothing changes semantically; users of
# `using PacketModule` get `peek` without an ambiguity warning.
import Base: peek

# ---------- generic entry points --------------------------------------------

"""
    peek(c::Chunk[, ::Type{T}]; at, length, ...)

Return a chunk covering `[at, at+length)` of `c`. Without `T`, returns the
most efficient representation (a Slice for internal windows, the leaf itself
for a full-cover query). With `T`, converts to that representation; see the
per-type conversion methods.
"""
peek(c::Chunk; at = nothing, length = nothing, kwargs...) = peek(c, Chunk; at = at, length = length, kwargs...)

# Untyped: give back whatever is cheapest and preserves structure.
function peek(c::Chunk, ::Type{Chunk}; at = nothing, length = nothing, kwargs...)
    off, len = _peek_range(c, at, length)
    return slice(c, off, len)
end

# Slice as a target is just an alias for the untyped form.
peek(c::Chunk, ::Type{Slice}; at = nothing, length = nothing, kwargs...) =
    peek(c, Chunk; at = at, length = length, kwargs...)

# --- Filler target: length only, lossy by design (R1 conversion path) --------
function peek(c::Chunk, ::Type{Filler}; at = nothing, length = nothing,
              fill::UInt8 = 0x00, kwargs...)
    off, len = _peek_range(c, at, length)
    # If the source already IS a Filler and covers the range, keep it.
    if c isa Filler && off == ZERO_LENGTH && len == c.length
        return c
    end
    return Filler(len, fill, quality(c))
end

# --- Raw target: serialise. Phase 3 wires the codec; Phase 1 handles the
#     data-preserving cases (Raw source, Filler source) so testSlicing/testMerging
#     pass without waiting on serialisation. -----------------------------------
function peek(c::Chunk, ::Type{Raw}; at = nothing, length = nothing, kwargs...)
    off, len = _peek_range(c, at, length)
    return _to_raw(c, off, len)
end

# Raw source: bit-slice the underlying byte vector. Byte-aligned windows are
# the common case; a bit-shifted window falls back to a copy loop.
function _to_raw(c::Raw, off::BitLength, len::BitLength)
    if isbyte(off) && isbyte(len)
        b0 = bytes(off) + 1
        n  = bytes(len)
        data = copy(view(c.data, b0:(b0 + n - 1)))
        return Raw(data, len, c.quality)
    end
    error("_to_raw: bit-shifted Raw slicing not yet implemented (phase 3)")
end

# Filler source: materialise the fill byte over `len`.
function _to_raw(c::Filler, off::BitLength, len::BitLength)
    n = (len.bits + 7) >> 3
    data = fill(c.fill, n)
    return Raw(data, len, c.quality)
end

# Slice source: descend into the target.
function _to_raw(c::Slice, off::BitLength, len::BitLength)
    return _to_raw(c.chunk, c.offset + off, len)
end

# Sequence source: collect from each intersecting child, then concatenate.
function _to_raw(c::Sequence, off::BitLength, len::BitLength)
    parts = UInt8[]
    total_bits = 0
    q = Q_COMPLETE
    remaining = len.bits
    pos = off.bits
    i = max(searchsortedlast(c.offsets, pos), 1)
    while remaining > 0
        child = c.chunks[i]
        child_start = c.offsets[i]
        child_len   = chunk_length(child).bits
        local_off   = pos - child_start
        take        = min(child_len - local_off, remaining)
        r = _to_raw(child, BitLength(local_off), BitLength(take))
        # Byte-align check: only support byte-aligned concatenation for now.
        isbyte(BitLength(total_bits)) || error("_to_raw: unaligned Sequence merge (phase 3)")
        isbyte(BitLength(take))       || error("_to_raw: unaligned Sequence merge (phase 3)")
        append!(parts, r.data)
        total_bits += take
        q = q ⊔ r.quality
        pos       += take
        remaining -= take
        i         += 1
    end
    return Raw(parts, len, q)
end

# Fields source: serialise into a byte vector, then bit-slice.
function _to_raw(c::Fields, off::BitLength, len::BitLength)
    bs = to_bytes(c)
    return _to_raw(Raw(bs, chunk_length(c), quality(c)), off, len)
end
