# ============================================================================
# Tags — packet-scope and region-scope metadata.
#
# Two mechanisms, not INET's three (plan §4.3):
#
#   Packet tags    keyed by TYPE, at-most-one per packet, never on the wire.
#                  Cross-layer control (L3AddressReq/Ind, DispatchProtocolReq).
#                  The Req/Ind naming convention is worth keeping.
#
#   Region tags    keyed by (TYPE, bit-range), non-overlapping per type,
#                  attached to CONTENT. This is R6, the sleeper feature —
#                  it lets end-to-end delay / TCP request framing / etc.
#                  survive segmentation and reassembly.
#
# Design:
#
#   - `TagSet` (packet tags) is a lightweight Dict{DataType,Any}. `Any` is
#     fine here because dispatch is via `Base.get(tags, T)` returning `T`
#     unambiguously.
#   - `RegionTagSet` stores tags as `(type, first, last, value)` tuples in a
#     flat Vector — small n (usually 0-3), so a Vector beats a Dict.
#   - Packet holds BOTH. Push/pop shift region-tag ranges eagerly (plan
#     mentions lazy as a follow-up; measurement is a Phase 9 question).
#     The eager version has no invalidation bugs because the envelope is
#     the ONLY mutation point.
# ============================================================================

# ---------- Packet tags ------------------------------------------------------

"Packet-scope tags: keyed by type, at most one per packet."
struct TagSet
    entries::Dict{DataType,Any}
end
TagSet() = TagSet(Dict{DataType,Any}())

Base.isempty(t::TagSet) = isempty(t.entries)
Base.length(t::TagSet)  = Base.length(t.entries)
Base.haskey(t::TagSet, ::Type{T}) where {T} = haskey(t.entries, T)

"Get the tag of type `T`. Errors if absent — use `tryget` for a soft check."
function Base.getindex(t::TagSet, ::Type{T}) where {T}
    haskey(t.entries, T) || error("TagSet: no tag of type $T")
    return t.entries[T]::T
end
function Base.setindex!(t::TagSet, value::T, ::Type{T}) where {T}
    t.entries[T] = value
    return value
end
Base.delete!(t::TagSet, ::Type{T}) where {T} = (delete!(t.entries, T); t)
tryget(t::TagSet, ::Type{T}) where {T} =
    haskey(t.entries, T) ? t.entries[T]::T : nothing

# ---------- Region tags ------------------------------------------------------

"A region tag: a value of some type, scoped to a bit-range [first, last]."
struct RegionTag
    type::DataType         # cached typeof(value); duplicated for indexing
    first::Int64           # inclusive
    last::Int64            # inclusive
    value::Any
end

"Set of region tags. Ranges are in BITS, relative to the enclosing content."
mutable struct RegionTagSet
    tags::Vector{RegionTag}
end
RegionTagSet() = RegionTagSet(RegionTag[])

Base.isempty(rs::RegionTagSet) = isempty(rs.tags)
Base.length(rs::RegionTagSet)  = Base.length(rs.tags)

"""
    add_region_tag!(rs, T, range::UnitRange{Int}, value::T)

Attach `value` to the bit-range `range`. Enforces R6's non-overlap per type:
if any existing tag of type `T` overlaps `range`, the call throws.
"""
function add_region_tag!(rs::RegionTagSet, ::Type{T}, range::UnitRange{Int}, value::T) where {T}
    for tag in rs.tags
        if tag.type === T && !(tag.last < first(range) || tag.first > last(range))
            error("RegionTagSet: overlapping range for tag type $T at $range vs $(tag.first):$(tag.last)")
        end
    end
    push!(rs.tags, RegionTag(T, Int64(first(range)), Int64(last(range)), value))
    return rs
end

"Find all tags of type `T` intersecting `range`."
function region_tags(rs::RegionTagSet, ::Type{T}, range::UnitRange{Int}) where {T}
    out = Tuple{UnitRange{Int},T}[]
    for tag in rs.tags
        tag.type === T || continue
        (tag.last < first(range) || tag.first > last(range)) && continue
        overlap = max(tag.first, first(range)):min(tag.last, last(range))
        push!(out, (Int(overlap[1]):Int(overlap[end]), tag.value::T))
    end
    return out
end

"Shift every tag by `delta` bits — used when inserting/removing at the front."
function shift_region_tags!(rs::RegionTagSet, delta::Int64)
    for i in eachindex(rs.tags)
        t = rs.tags[i]
        rs.tags[i] = RegionTag(t.type, t.first + delta, t.last + delta, t.value)
    end
    return rs
end

"Drop tags that fall entirely outside [lo, hi]; clip any that straddle the edges."
function clip_region_tags!(rs::RegionTagSet, lo::Int64, hi::Int64)
    kept = RegionTag[]
    for t in rs.tags
        t.last < lo && continue
        t.first > hi && continue
        first_ = max(t.first, lo)
        last_  = min(t.last, hi)
        push!(kept, RegionTag(t.type, first_, last_, t.value))
    end
    rs.tags = kept
    return rs
end

Base.copy(rs::RegionTagSet) = RegionTagSet(copy(rs.tags))
