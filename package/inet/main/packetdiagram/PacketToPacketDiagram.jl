# ============================================================================
# Packet → PacketDiagram — the first stage, and a thin one.
#
# It wraps the packet in the presentation document the figure is drawn from,
# exactly as `ChartToChartPlot` wraps a chart in the plot that carries the view
# window. The diagram is built ONCE per projection setup and keeps its identity,
# so a row width a reader chose survives a change to the packet.
#
# A packet is a document, so this stage takes `APacket`, the family, and draws
# either layout of it: the native envelope a simulation mutates, and the cell
# layout an editor copies it into. The figure holds no packet of its own and
# nothing announces on its behalf — the label and the bands read the packet
# inside a cell, so a layout that announces its writes redraws the figure, and
# a native one does not, which is what a simulation wants.
# ============================================================================

"""
    PacketToPacketDiagram(; row_bits = 32)

The packet → diagram stage. Stateless: everything it produces lives on the
`PacketDiagram` it emits. `row_bits` seeds the diagram's own row width.
"""
@projection struct PacketToPacketDiagram <: Projection
    row_bits::ImmutableCell{Int} = 32
end

@iomap struct PacketToPacketDiagramIoMap
    projection::Any
    input::Any
    output::Any
end

"""
    packet_diagram(packet; row_bits = 32) -> PacketDiagram

The figure's document for `packet`, built as the projection builds it.

Public because `packet_diagram_string` and the tests build a figure without
running the projection. A page does not: it splices the packet, and the entry
keyed on `APacket` draws it.

The label and the bands are both derived, and both read the packet **inside** a
cell. That is what makes the figure follow a packet that changes: a cell-layout
packet announces every write, and a computed cell that read it re-derives. A
native packet holds no cells and announces nothing, which is the right answer for
one — a simulation mutates a packet on every hop, and a figure that re-derived
each time would be the simulation's cost, not the figure's.
"""
function packet_diagram(packet::APacket; row_bits::Int = 32)
    PacketDiagram(label    = ComputedCell(() -> packet_label(packet)),
                  row_bits = row_bits,
                  bands    = ComputedCellVector(() -> diagram_bands(packet)))
end

packet_diagram(chunk::Chunk; kwargs...) = packet_diagram(Packet(chunk); kwargs...)

function print_document(p::PacketToPacketDiagram, recursion, packet::APacket, ctx)
    PacketToPacketDiagramIoMap(p, packet, packet_diagram(packet; row_bits = p.row_bits))
end

# A bare chunk draws too — a header on its own is a packet with no envelope, and
# refusing it would make the figure unusable on the very value a test holds.
function print_document(p::PacketToPacketDiagram, recursion, chunk::Chunk, ctx)
    print_document(p, recursion, Packet(chunk), ctx)
end

# ---------- the reference mapping -------------------------------------------
#
# A packet is a document, so a place inside it has a name and this stage is no
# longer a wall. The correspondence is the band walk: band `b` was drawn from
# the chunk at `walk_bands(packet)[b][2]`, and a header field is one more step
# on either side —
#
#     content.chunks[2].header.source   ↔   bands[2].fields[4]
#
# Both directions read the walk rather than a stored table, so neither can go
# stale against a packet that changed. A band whose steps are `nothing` shows a
# chunk that is nowhere in the packet, and it maps in neither direction.

function map_reference_forward(p::PacketToPacketDiagram, iomap, reference)
    reference === nothing && return nothing
    @reference_case reference begin
        ∅ => @reference ::PacketDiagram
        __ => _forward_into_diagram(iomap, reference)
    end
end

function map_reference_backward(p::PacketToPacketDiagram, iomap, reference)
    reference === nothing && return nothing
    @reference_case reference begin
        ∅ => @reference ::Packet
        __ => _backward_into_packet(iomap, reference)
    end
end

_steps_to_reference(steps) =
    foldr((step, tail) -> ConcreteReference(step, tail), steps; init = EmptyReference())

# `content.…` → `bands[b]`, and one field deeper when the tail names one.
function _forward_into_diagram(iomap, reference)
    reference isa Reference || return nothing
    iomap.input isa APacket || return nothing
    steps = get_reference_steps(strip_reference_types(reference))
    walk = walk_bands(iomap.input)
    for (index, (band, path)) in enumerate(walk)
        path === nothing && continue
        _starts_with(steps, path) || continue
        head = Any[FieldReferenceStep("bands"), ElementReferenceStep(index)]
        rest = steps[(Base.length(path) + 1):end]
        field = _field_index(band, rest)
        field === nothing && return _steps_to_reference(head)
        return _steps_to_reference(vcat(head, Any[FieldReferenceStep("fields"),
                                                  ElementReferenceStep(field)]))
    end
    return nothing
end

# `bands[b]` → the chunk's own steps, and `bands[b].fields[f]` → one field more.
function _backward_into_packet(iomap, reference)
    reference isa Reference || return nothing
    iomap.input isa APacket || return nothing
    steps = get_reference_steps(strip_reference_types(reference))
    index = _indexed(steps, "bands")
    index === nothing && return nothing
    walk = walk_bands(iomap.input)
    (1 <= index <= Base.length(walk)) || return nothing
    band, path = walk[index]
    path === nothing && return nothing
    Base.length(steps) == 2 && return _steps_to_reference(path)
    field = _indexed(steps[3:end], "fields")
    field === nothing && return nothing
    band isa DiagramHeaderBand || return nothing
    (1 <= field <= Base.length(band.fields)) || return nothing
    return _steps_to_reference(vcat(path,
                                    Any[FieldReferenceStep(band.fields[field].name)]))
end

_starts_with(steps, path) =
    Base.length(steps) >= Base.length(path) &&
    all(steps[i] == path[i] for i in eachindex(path))

# `<name>[i]` at the head of a step list, as the index `i`.
function _indexed(steps, name::String)
    Base.length(steps) >= 2 || return nothing
    (steps[1] isa FieldReferenceStep && steps[1].name == name) || return nothing
    steps[2] isa RangeReferenceStep || return nothing
    return steps[2].start + 1
end

# Which of a header band's fields the remaining steps name, if they name one.
function _field_index(band, rest)
    band isa DiagramHeaderBand || return nothing
    Base.length(rest) >= 1 || return nothing
    rest[1] isa FieldReferenceStep || return nothing
    # A plain loop, because a `CellVector` is not an indexable collection that
    # `findfirst` can ask for its keys.
    for (index, field) in enumerate(band.fields)
        field.name == rest[1].name && return index
    end
    return nothing
end

# ---------- building the bands ----------------------------------------------

"""
    diagram_bands(packet) -> Vector{DiagramBand}

The packet's chunks as bands, in reading order, each carrying its bit offset
from the start of the packet.

This walks the chunk tree rather than `dissect`, which reports a header's field
values but not their bit offsets or widths — and without those there is no
figure to draw.
"""
diagram_bands(packet::APacket) = DiagramBand[band for (band, _) in walk_bands(packet)]
diagram_bands(chunk::Chunk) = DiagramBand[band for (band, _) in walk_bands(chunk)]
diagram_bands(::Nothing) = DiagramBand[]

"""
    walk_bands(packet) -> Vector{Tuple{DiagramBand, Union{Vector{Any}, Nothing}}}

One walk, two views: the bands the figure draws, and the reference steps from
the packet to the chunk each band was drawn from. The mapping between the two
documents is what those steps are for, and taking them from the same walk is
what stops the figure and the mapping from disagreeing.

A band's steps are `nothing` when the chunk it shows is nowhere in the packet.
`data_chunk` trims the retained front and back, and what it returns is then a
derived chunk with no place of its own. It gives back `content` itself when it
trims nothing, and the walk tests that identity rather than reading the two
lengths, because the smart constructor decides it.
"""
function walk_bands(packet::APacket)
    out = Tuple{DiagramBand, Union{Vector{Any}, Nothing}}[]
    chunk = data_chunk(packet)
    root = chunk === packet.content ? Any[FieldReferenceStep("content")] : nothing
    _append_band!(out, chunk, 0, root)
    return out
end

# A bare chunk is not inside a packet, so no band has a place to name.
walk_bands(chunk::Chunk) =
    (out = Tuple{DiagramBand, Union{Vector{Any}, Nothing}}[];
     _append_band!(out, chunk, 0, nothing); out)

_BandWalk = Vector{Tuple{DiagramBand, Union{Vector{Any}, Nothing}}}

# One step deeper, and still nowhere once the walk has left the packet.
_below(path, steps...) = path === nothing ? nothing : vcat(path, Any[steps...])

function _append_band!(out::_BandWalk, sequence::Sequence, offset::Int, path)
    for (index, child) in enumerate(sequence.chunks)
        offset = _append_band!(out, child, offset,
                               _below(path, FieldReferenceStep("chunks"),
                                      ElementReferenceStep(index)))
    end
    return offset
end

function _append_band!(out::_BandWalk, header::Fields, offset::Int, path)
    push!(out, (_header_band(header, offset, quality_text(quality(header))), path))
    return offset + chunk_length(header).bits
end

function _append_band!(out::_BandWalk, marked::MarkedFields, offset::Int, path)
    push!(out, (_header_band(marked.header, offset, quality_text(quality(marked))),
                _below(path, FieldReferenceStep("header"))))
    return offset + chunk_length(marked).bits
end

function _append_band!(out::_BandWalk, chunk::Chunk, offset::Int, path)
    width = chunk_length(chunk).bits
    push!(out, (DiagramOpaqueBand(kind    = _chunk_kind(chunk),
                                  name    = _chunk_name(chunk),
                                  offset  = offset,
                                  width   = width,
                                  quality = quality_text(quality(chunk)),
                                  preview = _chunk_preview(chunk)), path))
    return offset + width
end

function _header_band(header::Fields, offset::Int, quality::String)
    layout = describe_layout(typeof(header))
    # A field wider than 64 bits — an IPv6 address is 128 — has no `UInt64`, so
    # `value` stays zero and the figure prints `text` alone. `_value_forms` in
    # the printer reads `width` and offers a numeric form only when there is one.
    #
    # `base` no longer names a display base: a value type prints itself, so the
    # declaration never states one. It carries `classify_display` instead, which
    # is what a view wants to know about a field.
    fields = Any[DiagramField(name   = String(spec.name),
                              offset = spec.offset,
                              width  = spec.width,
                              value  = has_bits(spec) ? encode_field(header, spec) : UInt64(0),
                              text   = format_field(header, spec),
                              base   = classify_display(spec))
                 for spec in layout.fields]
    DiagramHeaderBand(name     = String(layout.name),
                      offset   = offset,
                      width    = layout.length.bits,
                      quality  = quality,
                      fields   = CellVector(fields))
end

_chunk_kind(::Filler) = :filler
_chunk_kind(::Raw)    = :raw
_chunk_kind(::Slice)  = :slice
_chunk_kind(::Chunk)  = :chunk

_chunk_name(::Filler)     = "Filler"
_chunk_name(::Raw)        = "Raw"
_chunk_name(chunk::Slice) = "Slice of " * _chunk_name(chunk.chunk)
_chunk_name(::Chunk)      = "Chunk"

# What a band shows beside its name and its length: for a filler what it is
# filled with, for raw bytes the first of them.
_chunk_preview(chunk::Filler) = "fill=0x" * string(chunk.fill, base = 16, pad = 2)
_chunk_preview(chunk::Raw)    = _hex_preview(chunk.data, 8)
_chunk_preview(::Chunk)       = ""

function _hex_preview(data::Vector{UInt8}, limit::Int)
    n = min(Base.length(data), limit)
    text = join((string(b, base = 16, pad = 2) for b in data[1:n]), " ")
    return Base.length(data) > n ? text * " …" : text
end

"""
    quality_text(quality) -> String

What a chunk is instead of complete, correct and properly represented. Empty
when it is all three, so the figure prints a note only when there is one.
"""
quality_text(q) = q == Q_COMPLETE ? "" : string(q)

"""
    packet_label(packet) -> String

The figure's title line: what the envelope holds, and what it retains.
"""
function packet_label(packet::APacket)
    label = "Packet  " * string(data_length(packet))
    packet.front == ZERO_LENGTH || (label *= "  front=" * string(packet.front))
    packet.back  == ZERO_LENGTH || (label *= "  back="  * string(packet.back))
    return label
end
