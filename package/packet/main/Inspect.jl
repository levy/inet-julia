# ============================================================================
# Inspection — human-readable packet dissection.
#
# The plan (§6.7) frames this as a projection over the same data structure the
# simulation runs on — no separate reflection layer, no defensive copies.
# Phase 7 provides the underlying `dissect` operation; a projectured editor
# for it can bind to the same tree.
#
# `dissect(x)` returns a `Vector{Dissection}`, one per leaf chunk in reading
# order, with header dissections yielding per-field entries. `describe(io, x)`
# renders that tree as indented text.
# ============================================================================

struct Dissection
    kind::Symbol                     # :filler | :raw | :fields | :marked
    label::String
    length::BitLength
    quality::Quality
    fields::Vector{Pair{Symbol,Any}} # populated for :fields
    children::Vector{Dissection}     # populated for composite entries
end

# ---------- dissect: build the tree -----------------------------------------

dissect(c::Chunk) = [_dissect_one(c)]
function dissect(pk::Packet)
    root = _dissect_one(data_chunk(pk))
    # Wrap as a synthetic top-level entry noting the envelope.
    label = "Packet(data=$(data_length(pk))"
    pk.front == ZERO_LENGTH || (label *= ", front=$(pk.front)")
    pk.back  == ZERO_LENGTH || (label *= ", back=$(pk.back)")
    isempty(pk.packet_tags) || (label *= ", ptags=$(Base.length(pk.packet_tags))")
    isempty(pk.region_tags) || (label *= ", rtags=$(Base.length(pk.region_tags))")
    label *= ")"
    return [Dissection(:envelope, label, data_length(pk), quality(pk.content),
                       Pair{Symbol,Any}[], [root])]
end

_dissect_one(c::Filler) =
    Dissection(:filler, "Filler(fill=$(c.fill))", c.length, c.quality,
               Pair{Symbol,Any}[], Dissection[])

_dissect_one(c::Raw) =
    Dissection(:raw, "Raw($(_hex_preview(c.data, 8)))", c.length, c.quality,
               Pair{Symbol,Any}[], Dissection[])

function _dissect_one(c::Slice)
    inner = _dissect_one(c.chunk)
    return Dissection(:slice,
        "Slice(offset=$(c.offset), length=$(c.length))",
        c.length, quality(c), Pair{Symbol,Any}[], [inner])
end

function _dissect_one(c::Sequence)
    kids = [_dissect_one(x) for x in c.chunks]
    return Dissection(:sequence, "Sequence($(Base.length(c.chunks)))",
                      c.length, quality(c), Pair{Symbol,Any}[], kids)
end

function _dissect_one(h::Fields)
    fs = [Symbol(f) => getfield(h, f) for f in header_fields(typeof(h))]
    return Dissection(:fields, string(document_schema_name(typeof(h))),
                      chunk_length(h), quality(h), fs, Dissection[])
end

function _dissect_one(m::MarkedFields)
    inner = _dissect_one(m.header)
    return Dissection(:marked, "Marked($(inner.label))",
                      chunk_length(m), quality(m), Pair{Symbol,Any}[], [inner])
end

# ---------- describe: text renderer -----------------------------------------

"""
    describe([io], x)

Print a human-readable dissection tree for a Chunk or Packet. Also useful in
tests as a stable snapshot format.
"""
describe(x) = (io = IOBuffer(); describe(io, x); String(take!(io)))
describe(io::IO, x) = _describe(io, dissect(x), 0)

function _describe(io::IO, ds::Vector{Dissection}, indent::Int)
    for d in ds
        print(io, "  "^indent, d.label, "  [", d.length)
        d.quality == Q_COMPLETE || print(io, ", ", d.quality)
        print(io, "]")
        println(io)
        for (name, val) in d.fields
            println(io, "  "^(indent + 1), name, " = ", val)
        end
        _describe(io, d.children, indent + 1)
    end
end

# ---------- helpers ---------------------------------------------------------

function _hex_preview(data::Vector{UInt8}, max_bytes::Int)
    n = min(Base.length(data), max_bytes)
    hex = join([string(b, base = 16, pad = 2) for b in data[1:n]], " ")
    return Base.length(data) > n ? hex * " …" : hex
end
