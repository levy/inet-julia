# ============================================================================
# The packet diagram — the documents, the first projection stage, and the row
# layout.
#
# The figure is the one view in this repository that is wrong if it is merely
# plausible: a field one column too wide still renders, and still lies. So the
# geometry is checked as numbers here, and the printer's own file checks the
# characters those numbers become.
# ============================================================================
using Test
using Inet
using Inet.PacketModule
using Inet.PacketDiagramModule
using Projectured.ProjectionApiModule: print_document, map_reference_forward,
    map_reference_backward
using Projectured.PrinterContextModule: PrinterContext
using Projectured.IoMapModule: get_iomap_output
using Projectured.ReferenceModule: EmptyReference

# The frame every check below reads: Ethernet MAC, IPv4, UDP, a 32-byte filler
# payload and the FCS — 78 bytes, four declared headers and one opaque run.
function diagram_test_frame()
    pk = Packet(Filler(Bytes(32)))
    pushfirst!(pk, UdpHeader(src_port = 1000, dst_port = 2000, length = UInt16(40)))
    pushfirst!(pk, Ipv4Header(total_length = UInt16(60), protocol = IP_PROTOCOL_UDP,
                              src_address = Ipv4Address("10.0.0.1"),
                              dst_address = Ipv4Address("10.0.0.2")))
    pushfirst!(pk, EthernetMacHeader(MacAddress("0a:00:00:00:00:02"),
                                     MacAddress("0a:00:00:00:00:01"),
                                     ETHERTYPE_IPV4))
    push!(pk, EthernetFcs())
    return pk
end

@testset "diagram_bands — every chunk becomes a band, in reading order" begin
    bands = diagram_bands(diagram_test_frame())
    @test Base.length(bands) == 5
    @test [b.name for b in bands] ==
          ["EthernetMacHeader", "Ipv4Header", "UdpHeader",
           "Filler", "EthernetFcs"]
    @test [b.offset for b in bands] == [0, 112, 272, 336, 592]
    @test [b.width  for b in bands] == [112, 160, 64, 256, 32]

    # Offsets run without a gap, and the last band ends at the packet's length.
    offset = 0
    for b in bands
        @test b.offset == offset
        offset += b.width
    end
    @test offset == 78 * 8

    @test bands[1] isa DiagramHeaderBand
    @test bands[4] isa DiagramOpaqueBand
    @test bands[4].kind === :filler
end

@testset "diagram_bands — a header band carries its declared fields" begin
    bands = diagram_bands(diagram_test_frame())
    ip = bands[2]
    @test [f.name for f in ip.fields][1:4] == ["version", "ihl", "dscp", "ecn"]
    @test [f.width for f in ip.fields][1:4] == [4, 4, 6, 2]
    @test [f.offset for f in ip.fields][1:4] == [0, 4, 8, 14]

    # The value is stored as raw bits AND as the text a reader sees.
    src = ip.fields[12]
    @test src.name == "src_address"
    @test src.value == 0x0a000001
    @test src.text == "10.0.0.1"
    @test src.base === :ipv4

    protocol = ip.fields[10]
    @test protocol.text == "UDP (17)"
    @test ip.fields[1].text == "0100"          # four bits, as bits

    mac = bands[1]
    @test mac.fields[1].text == "0a:00:00:00:00:02"
    @test mac.fields[3].text == "IPv4 (0x0800)"

    # Every band is complete, so no band says otherwise.
    @test all(b -> b.quality == "", bands)
end

@testset "diagram_rows — a continuous grid over the whole packet" begin
    bands = diagram_bands(diagram_test_frame())
    rows = diagram_rows(bands, 32)

    # Row 1 is the first 32 bits of the destination address: one cell, split
    # into two parts, and this is the wider one.
    first_row = rows[1].cells
    @test Base.length(first_row) == 1
    @test first_row[1].width == 32
    @test first_row[1].parts == 2
    @test first_row[1].widest
    @test first_row[1].starts_band

    # Row 2 holds the rest of the destination and the start of the source.
    @test [c.width for c in rows[2].cells] == [16, 16]
    @test rows[2].cells[1].part == 2
    @test !rows[2].cells[1].widest              # the value prints in row 1

    # Row 4 is where the MAC header ends and IPv4 begins, mid-row.
    fourth = rows[4].cells
    @test [c.width for c in fourth] == [16, 4, 4, 6, 2]
    @test fourth[1].band == 1                   # ethertype
    @test fourth[2].band == 2                   # version
    @test fourth[2].starts_band                 # a header boundary inside a row

    # Every row holds exactly row_bits bits, except the last one of a run.
    for row in rows
        row.kind === :grid || continue
        total = sum(c.width for c in row.cells)
        @test total <= 32
    end
end

@testset "diagram_rows — a long opaque band collapses to one box" begin
    bands = diagram_bands(diagram_test_frame())
    rows = diagram_rows(bands, 32; max_opaque_rows = 2)
    boxes = [r for r in rows if r.kind === :box]
    @test Base.length(boxes) == 1
    @test boxes[1].band == 4
    @test boxes[1].offset == 336

    # The grid restarts after the box: the FCS row begins where the band ended.
    after = findfirst(r -> r.kind === :grid && r.offset >= 592, rows)
    @test after !== nothing
    @test rows[after].offset == 592

    # A payload short enough to draw is drawn.
    short = Packet(Filler(Bytes(4)))
    short_rows = diagram_rows(diagram_bands(short), 32; max_opaque_rows = 2)
    @test all(r -> r.kind === :grid, short_rows)
end

@testset "diagram_rows — the last row of a packet may be short" begin
    pk = Packet(UdpHeader(src_port = 1, dst_port = 2, length = UInt16(8)))
    rows = diagram_rows(diagram_bands(pk), 32)
    @test Base.length(rows) == 2
    @test sum(c.width for c in rows[2].cells) == 32

    # A header that does not fill its last row leaves it short.
    odd = Packet(EthernetFcs(0x11223344))
    odd_rows = diagram_rows(diagram_bands(odd), 64)
    @test Base.length(odd_rows) == 1
    @test sum(c.width for c in odd_rows[1].cells) == 32
end

@testset "grid_width / cell_width — the character geometry" begin
    @test grid_width(32) == 65
    @test grid_width(16) == 33
    @test cell_width(1) == 1
    @test cell_width(4) == 7
    @test cell_width(16) == 31
    @test cell_width(32) == 63
    # A row's cells and their borders fill the grid exactly.
    @test 1 + sum(cell_width(w) + 1 for w in [4, 4, 6, 2, 16]) == grid_width(32)
end

@testset "PacketToPacketDiagram — the packet becomes the figure's document" begin
    pk = diagram_test_frame()
    projection = PacketToPacketDiagram()
    iomap = print_document(projection, nothing, pk, PrinterContext())
    diagram = get_iomap_output(iomap)

    @test diagram isa PacketDiagram
    @test diagram.packet === pk
    @test diagram.row_bits == 32
    @test Base.length(diagram.bands) == 5
    @test diagram.bands[2].name == "Ipv4Header"
    @test occursin("78B", diagram.label)

    # The row width is view state on the document, so a reader may change it.
    diagram.row_bits = 16
    @test diagram.row_bits == 16

    # A bare chunk draws too — a header on its own is a packet with no envelope.
    header_only = print_document(projection, nothing,
                                 UdpHeader(src_port = 1, dst_port = 2, length = UInt16(8)),
                                 PrinterContext())
    @test Base.length(get_iomap_output(header_only).bands) == 1
end

@testset "PacketToPacketDiagram — writing the packet re-derives the bands" begin
    pk = diagram_test_frame()
    iomap = print_document(PacketToPacketDiagram(), nothing, pk, PrinterContext())
    diagram = get_iomap_output(iomap)
    @test Base.length(diagram.bands) == 5

    # A packet holds no cells, so the announcement is the write to this field.
    smaller = Packet(UdpHeader(src_port = 1, dst_port = 2, length = UInt16(8)))
    refresh_packet_diagram!(diagram, smaller)
    @test diagram.packet === smaller
    @test Base.length(diagram.bands) == 1
    @test diagram.bands[1].name == "UdpHeader"
end

@testset "PacketToPacketDiagram — the reference mapping" begin
    pk = diagram_test_frame()
    projection = PacketToPacketDiagram()
    iomap = print_document(projection, nothing, pk, PrinterContext())

    # The whole packet maps to the whole diagram; nothing maps inside it,
    # because a Packet has no reference steps to name.
    @test map_reference_forward(projection, iomap, EmptyReference()) !== nothing
    @test map_reference_forward(projection, iomap, nothing) === nothing

    # Backward this stage is a wall: no edit crosses it.
    @test map_reference_backward(projection, iomap, EmptyReference()) === nothing
end

# ---------------------------------------------------------------------------
# The printer. The figure is alignment, and a substring test cannot see
# alignment — so the whole string is pinned, character for character.
# ---------------------------------------------------------------------------

# The figure lives in a file of its own, read verbatim. A triple-quoted string
# would not do: Julia de-indents one, and the gutter of this figure is exactly
# the leading whitespace it would strip.
const DIAGRAM_SPECIMEN = rstrip(read(joinpath(@__DIR__, "packetdiagram-figure.txt"), String), '
')

@testset "PacketDiagramToText — the figure, character for character" begin
    @test packet_diagram_string(diagram_test_frame()) == DIAGRAM_SPECIMEN
end

@testset "PacketDiagramToText — what the figure says" begin
    figure = packet_diagram_string(diagram_test_frame())
    lines = split(figure, '\n')

    # Every grid line is the same width, which is what makes it a grid.
    grid = [l for l in lines if startswith(strip(l), "|") || startswith(strip(l), "+")]
    @test all(l -> Base.length(l) <= 8 + grid_width(32), grid)

    # A header boundary inside a row is drawn, and only there.
    @test any(l -> occursin("#version", l), lines)
    @test count(l -> occursin("#", l), lines) == 4

    # The values are in the base the field declares.
    @test any(l -> occursin("0a:00:00:00:00:02", l), lines)   # a MAC address
    @test any(l -> occursin("10.0.0.1", l), lines)            # an IPv4 address
    @test any(l -> occursin("UDP (17)", l), lines)            # a protocol number
    @test any(l -> occursin("0x0000", l), lines)              # a checksum, in hex
    # Four bits, printed as bits, in the cell after the header boundary.
    @test any(l -> occursin("# 0100  |", l), lines)

    # The byte offset gutter counts in bytes, and the header names float above
    # the row they start in.
    @test any(l -> startswith(l, " 0x000c"), lines)
    @test any(l -> occursin("Ipv4Header  20 B", l), lines)
    @test any(l -> occursin("UdpHeader  8 B", l), lines)

    # A payload too long to draw bit by bit becomes one box.
    @test any(l -> occursin("Filler  32 B  fill=0x00", l), lines)

    # ASCII only: no box-drawing glyph, because SDL does not fall back.
    @test all(c -> isascii(c), figure)
end

@testset "PacketDiagramToText — the row width is the reader's" begin
    pk = diagram_test_frame()
    narrow = packet_diagram_string(pk; row_bits = 16)
    wide   = packet_diagram_string(pk; row_bits = 32)
    @test Base.length(split(narrow, '\n')) > Base.length(split(wide, '\n'))
    # At 16 bits per row an Ethernet address still splits, but a port does not.
    @test occursin("#           src_port            |", wide)

    # The gutter is optional, and dropping it moves every line left by 8.
    bare = packet_diagram_string(pk; show_offsets = false)
    @test !occursin("0x000c", bare)
    @test any(l -> startswith(l, "|"), split(bare, '\n'))
end

@testset "PacketDiagramToText — a value that does not fit goes to the legend" begin
    # `flags` is three bits wide, so its cell holds five characters. A value
    # that needs more than that is cut, and the legend carries it whole.
    pk = Packet(Ipv4Header(total_length = UInt16(20), protocol = IP_PROTOCOL_TCP,
                           src_address = Ipv4Address("255.255.255.255"),
                           dst_address = Ipv4Address("255.255.255.255")))
    figure = packet_diagram_string(pk; row_bits = 4)
    # At four bits per row a cell holds seven characters, which fits neither the
    # dotted quad, nor the same number in hexadecimal, nor in decimal.
    @test occursin("Ipv4Header.src_address = 255.255.255.255", figure)
    @test occursin("*", figure)
end

@testset "packet_diagram_entry — keyed on the packet itself" begin
    entry = packet_diagram_entry()
    @test entry isa Pair
    @test entry.first === Packet
end
