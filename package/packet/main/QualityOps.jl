# ============================================================================
# Quality manipulation — mark_* helpers + the strict-by-default peek gate.
#
# The lattice is already in Quality.jl (§3.3): three monotone bits with a
# bitwise-OR join. This file adds the operations that PRODUCE non-Q_COMPLETE
# chunks (for error injection, corruption tests, and cut-through paths), and
# the guard `peek` invokes so imperfect data is never returned silently.
#
# Peek keyword args (plan §3.3), replacing INET's six PF_ALLOW_* bits:
#   peek(c, T; incomplete   = true)    accept a truncated header
#   peek(c, T; incorrect    = true)    accept a bad checksum
#   peek(c, T; misrepresented = true)  accept an alternative representation
#   peek(c, T; reinterpret  = true)    R9 opt-out (already Phase 3)
# ============================================================================

"Return `c` with the given quality flags OR-joined in. Cheap: rebuilds the
leaf with an updated `quality` field; the payload isn't touched."
mark_quality(c::Chunk, q::Quality) = _rewrap_quality(c, quality(c) ⊔ q)

mark_incomplete(c::Chunk)      = mark_quality(c, Q_INCOMPLETE)
mark_incorrect(c::Chunk)       = mark_quality(c, Q_INCORRECT)
mark_misrepresented(c::Chunk)  = mark_quality(c, Q_MISREPRESENTED)

# Per-representation rewrap (leaves get a fresh struct; Slice/Sequence descend).
_rewrap_quality(c::Filler,   q::Quality) = Filler(c.length, c.fill, q)
_rewrap_quality(c::Raw,      q::Quality) = Raw(c.data, c.length, q)
function _rewrap_quality(c::Slice, q::Quality)
    # A slice's quality is the target's quality (see Chunk.jl); to change it,
    # rewrap the target and re-slice.
    return slice(_rewrap_quality(c.chunk, q), c.offset, c.length)
end
function _rewrap_quality(c::Sequence, q::Quality)
    return sequence(Chunk[_rewrap_quality(x, q) for x in c.chunks])
end
# Fields have quality delegated through _fields_quality (below); we wrap them
# in a MarkedFields envelope so the mark travels without touching the header.
_rewrap_quality(c::Fields,   q::Quality) = MarkedFields(c, q)

# ============================================================================
# MarkedFields — a Fields envelope that carries a quality other than
# Q_COMPLETE. Kept separate from the header so plain headers stay clean
# immutable structs, matching the isbits story (§6.1).
# ============================================================================
struct MarkedFields{H<:Fields} <: Chunk
    header::H
    quality::Quality
end
chunk_length(m::MarkedFields) = chunk_length(m.header)
quality(m::MarkedFields)      = m.quality
# When someone asks for the underlying header type back, hand over the header.
# The mark is a chunk-level property, so a caller that already peeked at type
# T naturally re-encounters the mark via `quality(peeked_chunk)` if they
# rewrap; more commonly they call `peek(pk, T)` which strips the wrapper.

# Serialise/deserialise transparently.
serialize(io::BitWriter, m::MarkedFields) = serialize(io, m.header)

# A marked header is byte-shaped exactly as the header it wraps, and the mark
# travels on the bytes that come out. Without this a marked header sitting
# inside a `Sequence` — which is where one always sits, since it is a packet's
# header — has no `_to_raw`: `MarkedFields` is a `Chunk` but not a `Fields`, so
# the `Fields` method above does not cover it. The gate would then refuse the
# strict peek, name `incomplete = true` as the way through, and the opt-in
# would die on a MethodError instead of reading the header.
function _to_raw(m::MarkedFields, off::BitLength, len::BitLength)
    raw = _to_raw(m.header, off, len)
    return Raw(raw.data, chunk_length(raw), quality(raw) ⊔ m.quality)
end

# Marking an already-marked header joins into the mark it carries rather than
# nesting a second envelope — `mark_quality` has already OR-ed the old quality
# into `q`, and the lattice is monotone, so two marks are one chunk with both
# bits set. Nesting would make `mark_incorrect(mark_incomplete(h))` a different
# shape from `mark_incomplete(mark_incorrect(h))`, which the join says it is
# not, and leave the inner mark unreachable behind `quality`.
_rewrap_quality(m::MarkedFields, q::Quality) = MarkedFields(m.header, q)

# Peek(m, T::Fields) returns the wrapped header when the type matches — but
# the caller must have gated on `quality(pk_slice)` first, or opt in via the
# peek kwargs below.
function peek(m::MarkedFields{H}, ::Type{H}; kwargs...) where {H<:Fields}
    return m.header
end
peek(m::MarkedFields, ::Type{T}; kwargs...) where {T<:Fields} =
    peek(m.header, T; kwargs...)

# ============================================================================
# The strict-by-default gate. Called inside peek(Fields …) BEFORE returning.
# ============================================================================
function _check_quality(source_quality::Quality, target::Type;
                        incomplete::Bool = false,
                        incorrect::Bool = false,
                        misrepresented::Bool = false)
    if is_incomplete(source_quality) && !incomplete
        error("peek($target): source is INCOMPLETE. Pass `incomplete = true` to accept.")
    end
    if is_incorrect(source_quality) && !incorrect
        error("peek($target): source is INCORRECT. Pass `incorrect = true` to accept.")
    end
    if is_improperly_represented(source_quality) && !misrepresented
        error("peek($target): source is MISREPRESENTED. Pass `misrepresented = true` to accept.")
    end
    return nothing
end
