# ============================================================================
# Chunk — the payload data model.
#
# Four representations collapse to two leaves + two internal composites:
#
#   Filler          length-only (no bytes materialised)  — R1
#   Raw             actual bit-exact data                — R7
#   Slice           internal: a shared view              — smart-ctor only
#   Sequence        internal: an ordered rope            — smart-ctor only
#
# `Fields <: Chunk` is the supertype of every declared header (Phase 3).
# `Encrypted` and `Streaming` (R13) are retained shapes; both introduced later.
#
# INET's `EmptyChunk` is deliberately absent: absence is `nothing`, and the
# two peek flags that gated it collapse into `peek` vs `trypeek` (Phase 3).
#
# Normalisation is enforced by SMART CONSTRUCTORS (`sequence`, `slice`), which
# are the ONLY way to build the composites. The rules — no slice-of-slice, no
# sequence-in-sequence, no singleton, no adjacent mergeables — become an
# invariant of construction, not a convention to remember. Cumulative offsets
# are precomputed so `length` is O(1) and `peek` locates via binary search
# (INET defect 1).
# ============================================================================

abstract type Chunk <: Document end

# ---------- leaves -----------------------------------------------------------

"Length-only payload: never materialises bytes. Fills with `fill` on serialise."
@document ImmutableCell struct Filler <: Chunk
    length::BitLength
    fill::UInt8
    quality::Quality
    selection::Nothing
end
Filler(length::BitLength; fill::UInt8 = 0x00, quality::Quality = Q_COMPLETE) =
    Filler(length, fill, quality)

"Bit-exact data. `length` MAY be a non-multiple of 8 (last byte partially used)."
@document ImmutableCell struct Raw <: Chunk
    data::Vector{UInt8}
    length::BitLength
    quality::Quality
    selection::Nothing
end
function Raw(data::Vector{UInt8}; length::Union{BitLength,Nothing} = nothing,
             quality::Quality = Q_COMPLETE)
    l = length === nothing ? Bytes(Base.length(data)) : length
    l.bits >= 0 || error("Raw: negative length")
    # Byte count must cover the bit length.
    needed = (l.bits + 7) >> 3
    Base.length(data) >= needed ||
        error("Raw: data has $(Base.length(data)) bytes, need at least $needed for $l")
    Raw(data, l, quality)
end

# ---------- composites (smart-constructor gated) -----------------------------

# The type parameter `Slice{C}` carried is gone: `@document` takes a struct's
# type parameters for its own cells. Nothing is lost, because the cell layout
# already has one parameter per field — a `chunk` cell typed to the value rather
# than to the declared `Chunk` keeps the inner chunk inline, and the slice isbits.
# `slice` below is the only place a Slice is built, so that is where the typed
# cell is made.
#
# The bare name is the cell layout, the UnionAll, and not the default spelling.
# `x isa Slice` has to hold for every spelling, and the typed cell above is by
# construction not the default one.
"View into `chunk` starting at `offset` with `length`. Do not build directly."
@document ImmutableCell struct Slice <: Chunk
    chunk::Chunk
    offset::BitLength
    length::BitLength
    selection::Nothing
end

# `chunks` stays a plain `Vector`. A `CellVector` would make the element paths
# read `[i]` instead of `.chunks[i]`, and it lives in `ProjecturedBase`, which
# this package does not depend on and should not. A reference walks a plain
# vector field, and `copy_document` copies it independently — both checked.
"An ordered rope over typed leaves. `offsets[i]` is the cumulative bit-offset
BEFORE `chunks[i]`; `offsets[end] == length.bits`. Do not build directly."
@document ImmutableCell struct Sequence <: Chunk
    chunks::Vector{Chunk}
    offsets::Vector{Int64}
    length::BitLength
    selection::Nothing
end

"Supertype of every declared header (Phase 3)."
abstract type Fields <: Chunk end

# ---------- length + quality (dispatch table) --------------------------------

"""
    chunk_length(c::Chunk)::BitLength

The bit-length of a chunk's payload. Not `Base.length`: that returns an Int
element count, and chunks measure bits — silently coercing would swallow the
category error INET's `b`/`B` types exist to catch.

For `Fields` subtypes this must be defined per header (its wire length).
"""
# The read is written out rather than dotted. A document's bare name is its cell
# layout, a UnionAll, so `c` is still abstract inside a method that dispatches on
# it and the dotted read cannot be inferred. These four are called once per chunk
# per sequence built, so an uninferred read here is felt on every frame.
chunk_length(c::Filler)   = getfield(c, :length)[]::BitLength
chunk_length(c::Raw)      = getfield(c, :length)[]::BitLength
chunk_length(c::Slice)    = getfield(c, :length)[]::BitLength
chunk_length(c::Sequence) = getfield(c, :length)[]::BitLength

quality(c::Filler)   = getfield(c, :quality)[]::Quality
quality(c::Raw)      = getfield(c, :quality)[]::Quality
quality(c::Slice)    = quality(c.chunk)             # inherits from the target
quality(c::Sequence) = foldl(⊔, (quality(x) for x in c.chunks); init = Q_COMPLETE)
quality(::Fields)    = Q_COMPLETE                   # overridden per header

Base.isempty(c::Chunk) = chunk_length(c) == ZERO_LENGTH   # fixes INET defect 5

# ---------- iteration --------------------------------------------------------
#
# Iteration walks the LEAVES in order: a Sequence iterates its children (which
# may themselves be Slice-wrapped leaves), a leaf yields itself.

_leaves(c::Filler)      = (c,)
_leaves(c::Raw)         = (c,)
_leaves(c::Fields)      = (c,)
_leaves(c::Slice)       = (c,)                       # slice is a leaf-shape
_leaves(c::Sequence)    = c.chunks                   # already-normalised children

Base.iterate(c::Chunk, s = 1) = _iter(c, s)
_iter(c::Sequence, s::Int) = s > Base.length(c.chunks) ? nothing : (c.chunks[s], s + 1)
_iter(c::Chunk, s::Int)    = s > 1 ? nothing : (c, s + 1)
Base.eltype(::Type{<:Chunk}) = Chunk
# Chunks aren't "containers" in the collection sense — iteration walks their
# children, but the natural length measure is `chunk_length` (in bits), not an
# element count. Telling `collect` the size is unknown avoids Base.length being
# probed as an Integer.
Base.IteratorSize(::Type{<:Chunk}) = Base.SizeUnknown()

# ---------- smart constructors -----------------------------------------------

"Wrap `c` as a Slice over [`offset`, `offset+len`). Collapses slice-of-slice
and no-op slices; returns the leaf itself when the range covers it exactly."
function slice(c::Chunk, offset::BitLength, len::BitLength)
    offset.bits >= 0 || error("slice: negative offset $offset")
    len.bits    >= 0 || error("slice: negative length $len")
    offset + len <= chunk_length(c) ||
        error("slice: [$offset, $(offset+len)) out of bounds of $(chunk_length(c))")
    # no-op slice → return the original
    if offset == ZERO_LENGTH && len == chunk_length(c)
        return c
    end
    # slice-of-slice → flatten
    if c isa Slice
        return slice(c.chunk, c.offset + offset, len)
    end
    # slice into a Sequence — descend so every leaf is either a plain leaf or
    # a Slice over one. This keeps the tree flat and peek O(log n).
    if c isa Sequence
        return _slice_sequence(c, offset, len)
    end
    # The cell is typed to the value, not to the declared `Chunk`: that is what
    # keeps the inner chunk inline and `Slice` isbits, which the type parameter
    # used to do.
    return Slice(ImmutableCell{typeof(c)}(c), ImmutableCell{BitLength}(offset),
                 ImmutableCell{BitLength}(len), ImmutableCell{Nothing}(nothing))
end

function _slice_sequence(s::Sequence, offset::BitLength, len::BitLength)
    if len == ZERO_LENGTH
        # An empty view of a sequence has no sensible leaf; use a zero Filler.
        return Filler(ZERO_LENGTH)
    end
    parts = Chunk[]
    remaining = len.bits
    pos = offset.bits
    # binary search for first touched child
    i = searchsortedlast(s.offsets, pos)
    i = max(i, 1)
    while remaining > 0
        child = s.chunks[i]
        child_start = s.offsets[i]
        child_len   = chunk_length(child).bits
        local_off   = pos - child_start
        take        = min(child_len - local_off, remaining)
        push!(parts, slice(child, BitLength(local_off), BitLength(take)))
        pos       += take
        remaining -= take
        i         += 1
    end
    return sequence(parts)
end

# A function barrier, and it is load-bearing. `p` is typed `Chunk` at the call
# site and a document's bare name is a UnionAll, so narrowing it with `isa`
# leaves the field's type unknown and the read boxes. Written inline — even with
# the type annotated — it costs 48 bytes a call, which `push!` pays on every
# frame built. As its own function the call dispatches once and the read inside
# is static.
@noinline _children(s) = getfield(s, :chunks)[]::Vector{Chunk}

"Build a Sequence from `parts`, canonicalising:
  - drop empty parts
  - flatten nested Sequences
  - merge adjacent mergeable leaves (same Filler fill, or two Raws)
  - return a bare leaf when only one remains
  - return `Filler(0)` when nothing remains"
function sequence(parts::AbstractVector{<:Chunk})
    flat = Chunk[]
    for p in parts
        if isempty(p)
            continue
        elseif p isa ASequence
            append!(flat, _children(p))
        else
            push!(flat, p)
        end
    end
    # merge adjacent
    merged = Chunk[]
    for c in flat
        if !isempty(merged)
            m = _try_merge(merged[end], c)
            if m !== nothing
                merged[end] = m
                continue
            end
        end
        push!(merged, c)
    end
    if isempty(merged)
        return Filler(ZERO_LENGTH)
    elseif Base.length(merged) == 1
        return merged[1]
    end
    offsets = Vector{Int64}(undef, Base.length(merged) + 1)
    offsets[1] = 0
    for i in eachindex(merged)
        offsets[i + 1] = offsets[i] + chunk_length(merged[i]).bits
    end
    return Sequence(merged, offsets, BitLength(offsets[end]))
end

# --- adjacency merge rules ---------------------------------------------------
_try_merge(a::Chunk, b::Chunk) = nothing

function _try_merge(a::Filler, b::Filler)
    # Fixes INET defect 7: fill match required, quality joined (was ignored).
    if a.fill == b.fill && a.quality == b.quality
        return Filler(a.length + b.length, a.fill, a.quality)
    end
    return nothing
end

function _try_merge(a::Raw, b::Raw)
    # Only merge if `a` is a whole number of bytes — otherwise byte alignment
    # of `b`'s bits would shift and we'd have to re-pack. That's a real op,
    # not a merge, so refuse.
    isbyte(a.length) || return nothing
    a.quality == b.quality || return nothing
    n_a = bytes(a.length)
    # Take exactly the bytes covering `b`'s bits.
    n_b_bytes = (b.length.bits + 7) >> 3
    data = Vector{UInt8}(undef, n_a + n_b_bytes)
    copyto!(data, 1, a.data, 1, n_a)
    copyto!(data, n_a + 1, b.data, 1, n_b_bytes)
    return Raw(data, a.length + b.length, a.quality)
end

# Adjacent Slices over the SAME underlying chunk with contiguous ranges → one Slice.
function _try_merge(a::Slice, b::Slice)
    if a.chunk === b.chunk && a.offset + a.length == b.offset
        return slice(a.chunk, a.offset, a.length + b.length)
    end
    return nothing
end
