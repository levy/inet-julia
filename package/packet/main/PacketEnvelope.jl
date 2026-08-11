# ============================================================================
# Packet — the mutable envelope over immutable, shared content.
#
# A packet is owned by one module at a time, so the envelope is mutable and
# protocol code reads as statements rather than rebind chains. Sharing safety
# comes from the CONTENT being immutable: `dup` is O(1), broadcast to N
# receivers costs one envelope per receiver plus a shared payload pointer.
#
# The front/back cursors carry INET's meaning verbatim — front-popped is what
# layers above already consumed, back-popped is trailers, the middle is
# "my layer's business". They are RETAINED, not discarded, because
# `Ipv4::decapsulate` saves the front offset for ICMP reconstruction
# (plan §2.2), and dissectors use `back` as a scoping mechanism
# (Ipv4ProtocolDissector.cc:19-44). `trim!` is the explicit "drop what I've
# consumed" operation.
#
# The ~40-method cross product on INET's `Packet` (peekAtFront/AtBack/DataAt/…)
# collapses into Base verbs + a `from = :front | :back` keyword.
# ============================================================================

# `@native_document` binds the bare name to the plain `mutable struct` — the same
# object, field for field, that a simulation has always mutated. `selection` is
# typed `Nothing` because the injected union would add a pointer to every packet
# and nothing on the hot path carries a selection.
@native_document struct Packet <: Document
    content::Chunk         # immutable, structurally shared
    front::BitLength       # consumed prefix (retained, not discarded)
    back::BitLength        # consumed suffix (retained, not discarded)
    packet_tags::TagSet    # keyed by type, at-most-one (Phase 5)
    region_tags::RegionTagSet   # keyed by (type, bit-range), R6 (Phase 5)
    selection::Nothing
end

Packet(content::Chunk = Filler(ZERO_LENGTH)) =
    Packet(content, ZERO_LENGTH, ZERO_LENGTH, TagSet(), RegionTagSet())

# ---------- accessors --------------------------------------------------------
# Total wire length of the payload (before front-trim / back-trim).
content_length(pk::Packet) = chunk_length(pk.content)
# The window a layer above front/below back sees.
data_length(pk::Packet) = content_length(pk) - pk.front - pk.back
front_length(pk::Packet) = pk.front
back_length(pk::Packet)  = pk.back

# The "visible" chunk: content restricted to [front, back).
data_chunk(pk::Packet) = slice(pk.content, pk.front, data_length(pk))

Base.isempty(pk::Packet) = data_length(pk) == ZERO_LENGTH

# ---------- duplicate: O(1) share --------------------------------------------
"Duplicate the envelope; the content is SHARED, not copied. `dup(pk).content
=== pk.content` is a load-bearing identity used to prove sharing. Tag sets
are COPIED — a packet tag added to `dup(pk)` must not appear on `pk`."
dup(pk::Packet) = Packet(pk.content, pk.front, pk.back,
                         TagSet(copy(pk.packet_tags.entries)),
                         copy(pk.region_tags))

# ---------- push / pop -------------------------------------------------------
#
# push!(pk, x)      appends `x` as a trailer   (analogue: insertAtBack)
# pushfirst!(pk, x) prepends `x` as a header   (analogue: insertAtFront)
# popfirst!(pk[, T]) consumes the front (a chunk or a specific type)
# pop!(pk[, T])      consumes the back  (a chunk or a specific type)
#
# Because content is immutable, "insert" is a functional update that rebuilds
# `content` via the sequence smart constructor. Front-trim / back-trim state
# is preserved by prepending/appending to the ACTIVE window; a chunk inserted
# at the front is inserted at offset `front`, not at absolute zero.

"Prepend `x` to the active window. The `front` cursor is unchanged, so the
newly-inserted chunk becomes the new front of the data window."
function Base.pushfirst!(pk::Packet, x::Chunk)
    inserted_at = Int64(pk.front.bits)
    delta = Int64(chunk_length(x).bits)
    if pk.front == ZERO_LENGTH && pk.back == ZERO_LENGTH
        pk.content = sequence(Chunk[x, pk.content])
    else
        prefix = slice(pk.content, ZERO_LENGTH, pk.front)
        middle = data_chunk(pk)
        suffix = slice(pk.content, pk.front + data_length(pk), pk.back)
        pk.content = sequence(Chunk[prefix, x, middle, suffix])
    end
    # Region tags at or after the insertion point shift by `delta`.
    for i in eachindex(pk.region_tags.tags)
        t = pk.region_tags.tags[i]
        if t.first >= inserted_at
            pk.region_tags.tags[i] =
                RegionTag(t.type, t.first + delta, t.last + delta, t.value)
        end
    end
    pk
end

"Append `x` to the active window. The `back` cursor is unchanged."
function Base.push!(pk::Packet, x::Chunk)
    inserted_at = Int64((pk.front + data_length(pk)).bits)
    delta = Int64(chunk_length(x).bits)
    if pk.front == ZERO_LENGTH && pk.back == ZERO_LENGTH
        pk.content = sequence(Chunk[pk.content, x])
    else
        prefix = slice(pk.content, ZERO_LENGTH, pk.front)
        middle = data_chunk(pk)
        suffix = slice(pk.content, pk.front + data_length(pk), pk.back)
        pk.content = sequence(Chunk[prefix, middle, x, suffix])
    end
    # Region tags strictly AFTER the append point shift by `delta` (tags at
    # the boundary belong to the region ending here, so they stay put).
    for i in eachindex(pk.region_tags.tags)
        t = pk.region_tags.tags[i]
        if t.first >= inserted_at
            pk.region_tags.tags[i] =
                RegionTag(t.type, t.first + delta, t.last + delta, t.value)
        end
    end
    pk
end

"Consume `len` bits from the front of the data window and return the removed
chunk. The cursor advances; the bits are RETAINED in `content` for callers
that need to reconstruct the original (ICMP, dissectors)."
function Base.popfirst!(pk::Packet, len::BitLength)
    len <= data_length(pk) || error("popfirst!: $len exceeds data window $(data_length(pk))")
    piece = slice(pk.content, pk.front, len)
    pk.front = pk.front + len
    return piece
end

"Consume `len` bits from the back of the data window and return the removed
chunk. Symmetric to `popfirst!`."
function Base.pop!(pk::Packet, len::BitLength)
    len <= data_length(pk) || error("pop!: $len exceeds data window $(data_length(pk))")
    piece = slice(pk.content, pk.front + data_length(pk) - len, len)
    pk.back = pk.back + len
    return piece
end

# ---------- peek — type-directed access into a packet ------------------------

"""
    peek(pk::Packet, T; at = ZERO_LENGTH, length = nothing, from = :front, kwargs...)

Return a value of type `T` covering `[at, at+length)` of the packet's data
window. `from = :front` (default) measures from the head of the window;
`from = :back` measures from the tail. Untyped `peek(pk)` returns a Slice
covering the whole window.
"""
function peek(pk::Packet; at = nothing, length = nothing, from::Symbol = :front, kwargs...)
    return peek(pk, Chunk; at = at, length = length, from = from, kwargs...)
end

function peek(pk::Packet, ::Type{T}; at = nothing, length = nothing,
              from::Symbol = :front, kwargs...) where {T}
    off = at === nothing ? ZERO_LENGTH : at::BitLength
    # For a Fields target the caller usually means "the T at the front" —
    # default the window to T's wire length. Otherwise default to whatever
    # remains of the data window.
    l = if length !== nothing
        length::BitLength
    elseif T <: Fields && is_fixed_length(T)
        chunk_length(T)
    elseif T <: Fields
        # A variable-length header decides its own size out of the window, so
        # give it what is left and let it take what it needs.
        data_length(pk) - off
    else
        data_length(pk) - off
    end
    off.bits >= 0 || error("peek(pk): negative offset $off")
    l.bits   >= 0 || error("peek(pk): negative length $l")
    off + l <= data_length(pk) ||
        error("peek(pk): [$off, $(off+l)) out of window $(data_length(pk))")
    src_off = from === :front ? pk.front + off :
              from === :back  ? pk.front + data_length(pk) - off - l :
              error("peek(pk): from must be :front or :back, got :$(from)")
    return peek(pk.content, T; at = src_off, length = l, kwargs...)
end

# ---------- trim! — drop the popped prefix/suffix ----------------------------

"Drop the retained front/back pop regions, freeing memory. After `trim!`,
`front == back == 0` and `content` is the active data window."
function trim!(pk::Packet)
    if pk.front == ZERO_LENGTH && pk.back == ZERO_LENGTH
        return pk
    end
    front_shift = Int64(pk.front.bits)
    hi = Int64(pk.front.bits + data_length(pk).bits) - 1
    pk.content = data_chunk(pk)
    pk.front = ZERO_LENGTH
    pk.back  = ZERO_LENGTH
    # Drop or clip region tags that fall outside the surviving window,
    # then shift so ranges are relative to the new content origin.
    clip_region_tags!(pk.region_tags, front_shift, hi)
    shift_region_tags!(pk.region_tags, -front_shift)
    return pk
end

function Base.show(io::IO, pk::Packet)
    print(io, "Packet(", data_length(pk))
    pk.front == ZERO_LENGTH || print(io, ", front=", pk.front)
    pk.back  == ZERO_LENGTH || print(io, ", back=",  pk.back)
    isempty(pk.packet_tags) || print(io, ", ptags=", Base.length(pk.packet_tags))
    isempty(pk.region_tags) || print(io, ", rtags=", Base.length(pk.region_tags))
    print(io, ")")
end

# ---------- packet-level convenience -----------------------------------------

"""
    has(pk::Packet, T) -> Bool

Cheap "have I received at least a full T at the front?" check. Doesn't
deserialise; just measures the data window against the least a `T` can be —
which for a header with an option list is its fixed part.
"""
has(pk::Packet, ::Type{T}) where {T<:Fields} =
    data_length(pk) >= minimum_chunk_length(T)

# ---------- packet-level tag helpers (thin sugar over the tag sets) ---------

set_tag!(pk::Packet, value::T) where {T} = (pk.packet_tags[T] = value)
get_tag(pk::Packet, ::Type{T}) where {T} = pk.packet_tags[T]
has_tag(pk::Packet, ::Type{T}) where {T} = haskey(pk.packet_tags, T)
del_tag!(pk::Packet, ::Type{T}) where {T} = delete!(pk.packet_tags, T)
try_tag(pk::Packet, ::Type{T}) where {T} = tryget(pk.packet_tags, T)

"""
    add_region_tag!(pk, T, range::UnitRange, value::T)

Attach `value` to the packet's data window bit-range `range`. The range is
INTERPRETED IN DATA-WINDOW COORDINATES — 0 is the head of the data window.
Internally the tag is stored relative to `content`, offset by `front`.
"""
function add_region_tag!(pk::Packet, ::Type{T}, range::UnitRange{Int}, value::T) where {T}
    shifted = (first(range) + Int64(pk.front.bits)):(last(range) + Int64(pk.front.bits))
    add_region_tag!(pk.region_tags, T, Int(shifted[1]):Int(shifted[end]), value)
    return pk
end

"""
    region_tags(pk::Packet, T[, range::UnitRange])

Region tags of type `T` intersecting `range` (or the whole data window if
omitted), returned as `(range, value)` pairs in DATA-WINDOW coordinates.
"""
function region_tags(pk::Packet, ::Type{T}) where {T}
    return region_tags(pk, T, 0:Int(data_length(pk).bits) - 1)
end
function region_tags(pk::Packet, ::Type{T}, range::UnitRange{Int}) where {T}
    shifted = (first(range) + Int64(pk.front.bits)):(last(range) + Int64(pk.front.bits))
    pairs = region_tags(pk.region_tags, T, Int(shifted[1]):Int(shifted[end]))
    # Map back into data-window coordinates.
    return [((p[1][1] - Int(pk.front.bits)):(p[1][end] - Int(pk.front.bits)), p[2]) for p in pairs]
end
