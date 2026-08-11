# ============================================================================
# Packet → PacketDiagram — the first stage, and a thin one.
#
# It wraps the packet in the presentation document the figure is drawn from,
# exactly as `ChartToChartPlot` wraps a chart in the plot that carries the view
# window. The diagram is built ONCE per projection setup and keeps its identity,
# so a row width a reader chose survives a change to the packet.
#
# A `Packet` holds no reactive cells, and it can hold none: `InetPacket` may not
# import the kernel that defines them. So the packet cannot announce its own
# change, and the announcement comes from the cell that holds it — the `packet`
# field here. Writing it re-derives the bands; mutating a packet in place does
# not, and `refresh_packet_diagram!` is for a holder that cannot write.
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
    packet_diagram(packet; row_bits = 32, label = packet_label(packet)) -> PacketDiagram

The figure's document for `packet`, built as the projection builds it.

Public because a **document** is what an embed can carry: a `WidgetCard` renders
its content only when the content is a `Document`
(`WidgetToGraphics.jl`, `w.content isa Document`), and every marker on a page
arrives in a card. So a page splices this, and the `Packet` entry of
`packet_diagram_entries` serves a packet the renderer meets anywhere else.
"""
function packet_diagram(packet::Packet; row_bits::Int = 32,
                        label::AbstractString = packet_label(packet))
    packet_cell = Cell(packet)
    PacketDiagram(packet   = packet_cell,
                  label    = String(label),
                  row_bits = row_bits,
                  bands    = ComputedCellVector(() -> diagram_bands(packet_cell[])))
end

packet_diagram(chunk::Chunk; kwargs...) = packet_diagram(Packet(chunk); kwargs...)

function print_document(p::PacketToPacketDiagram, recursion, packet::Packet, ctx)
    PacketToPacketDiagramIoMap(p, packet, packet_diagram(packet; row_bits = p.row_bits))
end

# A bare chunk draws too — a header on its own is a packet with no envelope, and
# refusing it would make the figure unusable on the very value a test holds.
function print_document(p::PacketToPacketDiagram, recursion, chunk::Chunk, ctx)
    print_document(p, recursion, Packet(chunk), ctx)
end

"""
    refresh_packet_diagram!(diagram, packet = diagram.packet) -> diagram

Announce that the packet changed. Writing the `packet` field is what invalidates
the bands, so a holder that replaced its packet needs nothing else; a holder
that mutated one in place calls this.
"""
function refresh_packet_diagram!(diagram::PacketDiagram, packet = diagram.packet)
    diagram.packet = packet
    return diagram
end

# ---------- the reference mapping -------------------------------------------
#
# A `Packet` has no reference steps, and it can never have any, so the whole
# packet maps to the whole diagram and nothing maps inside it. Backward this
# stage is a wall: no edit crosses it until an operation exists that rebuilds
# the packet and writes it into the field that holds it.

function map_reference_forward(::PacketToPacketDiagram, iomap, reference)
    reference === nothing && return nothing
    @reference_case reference begin
        ∅ => @reference ::PacketDiagram
        __ => nothing
    end
end

map_reference_backward(::PacketToPacketDiagram, iomap, reference) = nothing

# ---------- building the bands ----------------------------------------------

"""
    diagram_bands(packet) -> Vector{DiagramBand}

The packet's chunks as bands, in reading order, each carrying its bit offset
from the start of the packet.

This walks the chunk tree rather than `dissect`, which reports a header's field
values but not their bit offsets or widths — and without those there is no
figure to draw.
"""
function diagram_bands(packet::Packet)
    bands = DiagramBand[]
    _append_band!(bands, data_chunk(packet), 0)
    return bands
end

diagram_bands(chunk::Chunk) = (bands = DiagramBand[]; _append_band!(bands, chunk, 0); bands)
diagram_bands(::Nothing) = DiagramBand[]

function _append_band!(bands::Vector{DiagramBand}, sequence::Sequence, offset::Int)
    for child in sequence.chunks
        offset = _append_band!(bands, child, offset)
    end
    return offset
end

function _append_band!(bands::Vector{DiagramBand}, header::Fields, offset::Int)
    push!(bands, _header_band(header, offset, quality_text(quality(header))))
    return offset + chunk_length(header).bits
end

function _append_band!(bands::Vector{DiagramBand}, marked::MarkedFields, offset::Int)
    push!(bands, _header_band(marked.header, offset, quality_text(quality(marked))))
    return offset + chunk_length(marked).bits
end

function _append_band!(bands::Vector{DiagramBand}, chunk::Chunk, offset::Int)
    width = chunk_length(chunk).bits
    push!(bands, DiagramOpaqueBand(kind    = _chunk_kind(chunk),
                                   name    = _chunk_name(chunk),
                                   offset  = offset,
                                   width   = width,
                                   quality = quality_text(quality(chunk)),
                                   preview = _chunk_preview(chunk)))
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
function packet_label(packet::Packet)
    label = "Packet  " * string(data_length(packet))
    packet.front == ZERO_LENGTH || (label *= "  front=" * string(packet.front))
    packet.back  == ZERO_LENGTH || (label *= "  back="  * string(packet.back))
    return label
end
