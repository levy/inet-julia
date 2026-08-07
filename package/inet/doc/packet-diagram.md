# The packet diagram

A packet as the ASCII art figure the RFCs draw: bits across the top, fields in
boxes, the headers flowing down the page. It is a projection of the packet, not
a picture of one — the figure is drawn from the same declaration that wrote the
bytes, so it cannot disagree with them.

## Where it lives

`package/inet/main/packetdiagram/`, in the umbrella, because it needs a packet
and the editor stack at once and no component below has both. `InetPacket`
still depends on nothing.

## The chain

```
Packet → PacketToPacketDiagram → PacketDiagram → PacketDiagramToText
       → TextBlock → TextToGraphics → GraphicsCanvas
```

The first stage is a projection, not a builder function. A packet may sit
inside the document a reader is looking at, and the renderer reaches such a
value by type dispatch — which calls a projection. That is why
`packet_diagram_entry()` is keyed on `Packet` itself:

```julia
NaturalToGraphics(extra = Pair{Type,Any}[packet_diagram_entry(measure = measure)])
```

A page then splices the packet, and nothing converts it first.

`PacketDiagram` is projection **output**, the role `ChartPlot` plays for
`Chart`: the packet stays what it is, and the view state a view alone can have
— the row width, which band a reader folded, the selection — lives on the
projected document. The projection builds it once per setup, so a row width a
reader chose survives a change to the packet.

## What makes it refresh

A `Packet` holds no reactive cells, and it can hold none: `InetPacket` may not
import the kernel that defines them. So a packet cannot announce its own
change, and the announcement comes from the cell that holds it.

- **Replace the packet** — the holder writes a new `Packet` into its field.
  That field is a cell, so the figure re-derives. This is the normal case.
- **Mutate a packet in place** — `pushfirst!` on the envelope changes what the
  packet means without touching any cell, and nothing invalidates.

So: **a document that holds a packet announces a change by writing the field,
not by mutating the packet.** `refresh_packet_diagram!(diagram, packet)` is
that write, for a holder that cannot make it.

## Reading the figure

```
        Packet  78B
         0                   1                   2                   3
         0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1 2 3 4 5 6 7 8 9 0 1
         EthernetMacHeader  14 B
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 0x0000 |                              dst                              |
        |                       0a:00:00:00:00:02                       |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 0x0004 |              dst              |              src              |
        |               ~               |               ~               |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 0x0008 |                              src                              |
        |                       0a:00:00:00:00:01                       |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
                                         Ipv4Header  20 B
 0x000c |           ethertype           #version|  ihl  |   dscp    |ecn|
        |         IPv4 (0x0800)         # 0100  | 0101  |  000000   |00 |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 0x0010 |         total_length          |        identification         |
        |              60               |            0x0000             |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 0x0014 |flags|       frag_offset       |      ttl      |   protocol    |
        | 000 |            0            |      64       |   UDP (17)    |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 0x0018 |        header_checksum        |          src_address          |
        |            0x0000             |           10.0.0.1            |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 0x001c |          src_address          |          dst_address          |
        |               ~               |           10.0.0.2            |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
                                         UdpHeader  8 B
 0x0020 |          dst_address          #           src_port            |
        |               ~               #             1000              |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 0x0024 |           dst_port            |            length             |
        |             2000              |              40               |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 0x0028 |           checksum            |
        |            0x0000             |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
        +---------------------------------------------------------------+
 0x002a |                    Filler  32 B  fill=0x00                    |
        +---------------------------------------------------------------+
         EthernetFcs  4 B
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
 0x004a |                              fcs                              |
        |                          0x00000000                           |
        +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
```

- `|` separates two fields of one header. `#` separates two headers — the grid
  is continuous over the whole packet, so a header that ends mid-row says so.
- The gutter is the byte offset of the row, which is what a reader compares
  against a hex dump.
- A header's name floats above the row it starts in, at the column of its first
  bit.
- A field that crosses a row boundary splits. Every part prints the name; only
  the widest part prints the value, and the others print `~`.
- A run the figure can measure but not name — a `Filler`, a `Raw` — collapses
  to one box when it is longer than `max_opaque_rows` rows. The grid resumes
  after it, and the gutter keeps the true offset.

## What a value looks like

The base comes from the field's declaration, through `header_layout`:

| base | form | where it comes from |
| --- | --- | --- |
| `:bin` | `0100` | a width that is not a whole number of bytes |
| `:dec` | `60` | a whole number of bytes |
| `:hex` | `0x003c` | `| hex` in the declaration |
| `:mac` | `0a:00:00:00:00:01` | the `MacAddress` type |
| `:ipv4` | `10.0.0.1` | the `Ipv4Address` type |
| `:enum` | `UDP (17)` | the `EtherType` and `IpProtocol` types |

A value wider than its cell falls back to a shorter base — the name of an enum
goes first, then binary becomes hexadecimal — and a value that fits nowhere is
cut with a `*` and named in full in a legend under the figure.

## Two rules a change must keep

**Use one font inside the grid.** Colour may vary, because colour does not
change the advance width of a glyph; a bold face can, and a grid whose columns
do not line up is not a grid.

**Draw with ASCII only** — `+ - | # ~`. The SDL backend does not fall back to
another face, so a Unicode box-drawing glyph the font lacks renders as an empty
box.

## From a REPL

```julia
using Inet, Inet.PacketModule, Inet.PacketDiagramModule

pk = Packet(Filler(Bytes(32)))
pushfirst!(pk, UdpHeader(src_port = 1000, dst_port = 2000, length = UInt16(40)))
print(packet_diagram_string(pk))              # the figure, as a String
print(packet_diagram_string(pk; row_bits = 16, show_offsets = false))
```

`packet_diagram_string` needs no window, which is what makes it the form a test
pins and the form a REPL prints.

## What is not there yet

The figure is **display-only**. `PacketDiagramToText` returns `nothing` from
both mappers, so a click selects nothing; and `PacketToPacketDiagram` is a wall
for edits, because a `Packet` has no reference steps to name. Making a cell
selectable needs a span table in the printer's IO map; making it editable needs
an operation that rebuilds the packet and writes it into the field that holds
it. Both are one phase, deferred.

A packet received from a wire holds `Raw` bytes rather than header structs, so
it draws as one opaque band. A dissector that walks the bytes with a
next-protocol table — ethertype picks IPv4, protocol picks UDP or TCP — is the
other deferred phase.
