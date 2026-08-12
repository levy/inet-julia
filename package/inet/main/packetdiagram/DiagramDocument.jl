# ============================================================================
# The documents the figure is drawn from.
#
# A band holds strings and numbers, never a `Chunk`. Drawing must not reach into
# the packet's internals, which is the same reason `Packets.jl` gives for not
# using generic reflection on a packet. There is no exception: the figure holds
# no packet, and the projection reads the one it was given.
#
# `value` and `text` are both stored although `text` derives from `value`. The
# projection knows the field's Julia type and can format a `MacAddress`; the
# printer downstream sees only the document. So the text is formatted once, and
# the raw bits stay beside it for a printer that must fall back to a shorter
# base when a cell is too narrow.
# ============================================================================

"""
Common supertype of the two kinds of band a figure draws: a declared header
whose fields it can name, and a run of bytes it can only measure.
"""
abstract type DiagramBand <: Document end

"""
    DiagramField(; name, offset, width, value, text, base)

One field of one header. `offset` is in bits from the start of the band.
"""
@document struct DiagramField
    name::String  = ""
    offset::Int   = 0
    width::Int    = 0
    value::UInt64 = UInt64(0)
    text::String  = ""
    base::Symbol  = :dec
end

"""
    DiagramHeaderBand(; name, offset, width, quality, collapsed, fields)

One declared header. `offset` is in bits from the start of the packet.
`quality` is empty when the chunk is complete, correct and properly
represented, and otherwise says what it is instead.
"""
@document struct DiagramHeaderBand <: DiagramBand
    name::String     = ""
    offset::Int      = 0
    width::Int       = 0
    quality::String  = ""
    collapsed::Bool  = false
    fields::CellVector = CellVector()
end

"""
    DiagramOpaqueBand(; kind, name, offset, width, quality, preview)

A run of the packet the figure can measure but not name: a `Filler`, a `Raw`,
or a `Slice` that does not cover one whole header. `kind` is `:filler`, `:raw`
or `:slice`.
"""
@document struct DiagramOpaqueBand <: DiagramBand
    kind::Symbol    = :filler
    name::String    = ""
    offset::Int     = 0
    width::Int      = 0
    quality::String = ""
    preview::String = ""
end

"""
    PacketDiagram(; label, row_bits, bands)

The figure's own document. `row_bits` is how many bits one row of the grid
holds, and `bands` are the headers and the opaque runs in reading order.

It holds no packet. The projection reads the one it was given, and both the
label and the bands are derived from it inside a cell — so a packet that
announces its writes redraws the figure, and nothing has to be told to.

`row_bits` is view state: a reader may set it to 16 to read an Ethernet header
without a field splitting across a row, and the setting survives a re-render
because the projection builds this document once.
"""
@document struct PacketDiagram
    label::String  = ""
    row_bits::Int  = 32
    bands::CellVector = CellVector()
end

"""
    band_length(band) -> Int

The width of a band in bits. One accessor for both kinds, so the geometry never
dispatches on which kind it has.
"""
band_length(band::DiagramBand) = band.width

"""
    diagram_length(diagram) -> Int

The whole figure's width in bits: the end of its last band.
"""
function diagram_length(diagram::PacketDiagram)
    bands = diagram.bands
    Base.length(bands) == 0 ? 0 : (bands[end].offset + bands[end].width)
end
