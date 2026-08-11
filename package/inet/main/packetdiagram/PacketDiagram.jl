# ============================================================================
# The `PacketDiagram` module — a packet as the ASCII art figure the RFCs draw.
# Design: plan/*/packet-headers-and-diagram.md.
#
# The chain starts at a `Packet`, because a packet may sit inside the document a
# reader is looking at and the renderer reaches such a value by type dispatch:
#
#   Packet → PacketToPacketDiagram → PacketDiagram → PacketDiagramToText
#          → TextBlock → TextToGraphics → GraphicsCanvas
#
# `PacketDiagram` is projection OUTPUT, not a domain document — the same role
# `ChartPlot` plays for `Chart`. The packet stays what it is, and the view state
# a view alone can have (the row width, which band a reader folded, the
# selection) lives on the projected document.
#
#   DiagramDocument.jl        the projected documents
#   DiagramGeometry.jl        rows, cells, widths — pure functions
#   PacketToPacketDiagram.jl  the first stage
#   PacketDiagramToText.jl    the printer, the chain, the entry
# ============================================================================

module PacketDiagramModule

using InetPacket.PacketModule

import ProjecturedKernel.CellModule: Cell, ComputedCell, AbstractCell,
    ReactiveCell, MutableCell
import ProjecturedCollection.CollectionModule: CellVector, ComputedCellVector
import ProjecturedKernel.DocumentModule: Document, var"@document"
import ProjecturedKernel.ReferenceModule: Reference
import ProjecturedKernel.IoMapModule: IoMap, var"@iomap", SimpleIoMap
import ProjecturedKernel.ProjectionApiModule: Projection, print_document,
    map_reference_forward, map_reference_backward
import ProjecturedKernel.ProjectionModule: var"@projection"
import ProjecturedKernel.ReferenceModule: EmptyReference
import ProjecturedKernel.ReferenceModule: var"@reference"
import ProjecturedKernel.ReferenceModule: var"@reference_case"
import ProjecturedKernel.CellStructModule: ImmutableCell
import ProjecturedProjection.ChainingProjectionModule: ChainingProjection
import ProjecturedStyle.ColorModule: DCStyleColor, color_solarized_blue,
    color_solarized_gray, color_solarized_green, color_solarized_magenta
import ProjecturedStyle.FontModule: DCStyleFont, font_ubuntu_monospace_regular_20
import ProjecturedText.TextModule: TextDocument, TextBlock, TextString, TextNewline
import ProjecturedText.TextToGraphicsModule: TextToGraphics
import ProjecturedText.TextToStringModule: TextToString
import ProjecturedStyle.TrueTypeModule: truetype_measure_text
import ProjecturedProjection.RecursiveProjectionModule: RecursiveProjection
import ProjecturedKernel.PrinterContextModule: PrinterContext

export
    # the projected documents
    PacketDiagram, DiagramBand, DiagramHeaderBand, DiagramOpaqueBand, DiagramField,
    # building them from a packet, and announcing a change
    packet_diagram, diagram_bands, refresh_packet_diagram!,
    # the row layout, as plain numbers
    DiagramCell, diagram_rows, grid_width, cell_width,
    # the projections and the two entry points
    PacketToPacketDiagram, PacketDiagramToText,
    packet_projection, packet_diagram_entry, packet_diagram_document_entry,
    packet_diagram_entries, packet_diagram_string

include("DiagramDocument.jl")
include("DiagramGeometry.jl")
include("PacketToPacketDiagram.jl")
include("PacketDiagramToText.jl")

end # module PacketDiagramModule
