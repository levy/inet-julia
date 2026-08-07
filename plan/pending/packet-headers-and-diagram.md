# Protocol headers, and a packet as an ASCII art diagram

Two things, one chain. First, declare the real protocol headers — Ethernet PHY,
Ethernet MAC, IPv4, UDP, TCP — with `@header`, so that one declaration gives the
struct, the wire codec and a machine-readable description of the layout. Second,
project a packet built from those headers into the ASCII art figure the RFCs
use, with bits on the horizontal axis and the headers flowing down the page.

The second half needs the first. An ASCII art figure must know the name, the bit
offset, the bit width and the value of every field. Today `@header` throws that
information away after it generates the codec. This plan keeps it.

Status: **PENDING**. No part of this plan is implemented.

## 1. What the plan delivers

1. A field type protocol, so a header field can be a `MacAddress` or an
   `Ipv4Address` and not a bag of integers.
2. A layout descriptor that `@header` emits beside the codec, and that the
   diagram reads.
3. Five header declarations, plus the Ethernet FCS trailer and the 802.1Q tag.
4. A projection chain that starts at a `Packet`, so a packet anywhere in a
   viewed document draws as the figure: the diagram documents, the projection
   that makes them, a row layout module and a printer.
5. A demo page that shows a real packet as the figure.

## 2. Decisions

The user made these four decisions before the plan was written. They are
recorded here because they close questions that the architecture rules leave
open.

| question | decision |
| --- | --- |
| where the headers live | `package/packet/main/`, in a `protocol/` slice |
| where the projection lives | `package/inet/main/`, in a `packetdiagram/` slice |
| how much header scope | fixed-size headers only — no IPv4 options, no TCP options, no IPv6 |
| which figure | the RFC bit grid, with the value under the name in the same cell |

Two consequences follow, and the plan accepts both.

`InetPacket` learns the names of Ethernet, IP, UDP and TCP. Its dependency set
stays empty, so [IAR-PACKET-DEPENDS-ON-NOTHING](../../documentation/architecture-requirements.md#iar-packet-depends-on-nothing)
still holds. What changes is that the data model is no longer protocol-neutral.
Record the reason in `Packet.jl`: the headers are declarations, not behaviour,
and a declaration that every package above needs belongs at the bottom.

`Inet` gains a dependency on the ProjecturEd stack. A program that only runs a
simulation now loads the editor packages when it says `using Inet`. If the
precompile cost becomes a problem, split the `packetdiagram/` slice into its own
package later; nothing in the design prevents it.

## 3. The state today

- [`Header.jl`](../../package/packet/main/Header.jl) holds `@header`. It parses
  `name :: Type` and `name :: Type | width`, and it emits the struct,
  `chunk_length`, `serialize`, `deserialize`, `quality` and `show`.
- [`BitIO.jl`](../../package/packet/main/BitIO.jl) holds `BitWriter` and
  `BitReader`. Both work most-significant-bit first, which is network order.
- [`demo_headers.jl`](../../package/packet/example/demo_headers.jl) declares
  `Ipv4Header` and `UdpHeader` in the **example** package.
- [`EthernetFrame.jl`](../../package/linklayer/main/t1s/EthernetFrame.jl)
  declares `EthernetMacHeader` and `EthernetFcs`. It splits each MAC address
  into `hi::UInt16` and `lo::UInt32`, because `@header` cannot express a 48-bit
  field. Its comment names this plan's job.
- [`Inspect.jl`](../../package/packet/main/Inspect.jl) gives `dissect`, which
  lists the leaf chunks and the field values of a header. It does **not** give
  bit offsets or bit widths, so it cannot drive the figure on its own.
- [`Packets.jl`](../../package/inet/example/Packets.jl) turns `dissect` output
  into a syntax document for the demo. That view stays; the figure is a second
  view of the same packet.
- No file in `inet-julia` is sealed yet. Every file in
  [`SEALING.md`](../../SEALING.md) is still `⬜`.

## 4. The field type protocol

### 4.1 Four generic functions

Add `package/packet/main/FieldTypes.jl` with four generic functions. A field
type answers all four; `@header` calls them.

```julia
field_width(::Type{T})::Int              # the default width, when `| n` is absent
field_encode(::Type{T}, value)::UInt64   # the bits that go on the wire
field_decode(::Type{T}, bits::UInt64)::T # the value that comes back
field_base(::Type{T})::Symbol            # :bin | :dec | :hex | :mac | :ipv4 | :enum
```

Give default methods for the types that already work:

- `T <: Unsigned` — width is `sizeof(T) * 8`, encode and decode are conversions.
- `T <: Bool` — width 1, base `:bin`.
- `T <: Enum` — width from the enum's base type, base `:enum`.

The default base depends on the declared width, not on the type: a field that is
not a whole number of bytes reads as bits, and a whole number of bytes reads as
a number. Use `:bin` when the width is not a multiple of 8, and `:dec`
otherwise. Every other choice is a per-field override.

### 4.2 The value types

Declare these in the same file. Each one is an immutable wrapper over the
smallest integer that holds it, so a header field stays a bits type.

| type | width | shown as | example |
| --- | --- | --- | --- |
| `MacAddress` | 48 | `:mac` | `0a:00:00:00:00:01` |
| `Ipv4Address` | 32 | `:ipv4` | `10.0.0.1` |
| `EtherType` | 16 | `:enum` | `IPv4 (0x0800)` |
| `IpProtocol` | 8 | `:enum` | `UDP (17)` |
| `PortNumber` | 16 | `:dec` | `1000` |

`EtherType` and `IpProtocol` carry a name table. A value that the table does not
know shows as its number alone, never as an error.

Give each type a `Base.show` that prints the same text the figure prints. One
formatter, two callers.

### 4.3 Three changes to `@header`

**Accept a field type.** `dst :: MacAddress | 48` must generate
`field_encode(MacAddress, h.dst)` on the write side and
`field_decode(MacAddress, read_bits!(io, 48))` on the read side. The present
macro calls `$(type)(read_bits!(...))`, which only works for integers.

**Accept a display override.** Read a third pipe segment as the base:
`header_checksum :: UInt16 | 16 | hex`. The segment is a bare name from the
known set. A wrong name is a macro error, not a silent default.

**Accept a default value.** `preamble :: UInt64 | 56 = 0x55555555555555` gives
the field a default, so `EthernetPhyHeader()` builds the constant header. Emit a
keyword constructor when at least one field has a default.

Warning: do not widen the generated positional constructor when every field has
a default. A zero-argument positional constructor overwrites the one Julia
generates for the struct, and the method overwrite is fatal at precompile time.
Emit the keyword form as a separate method.

## 5. The layout descriptor

`@header` emits one more method: the description of the layout it just encoded.
Put the types in `package/packet/main/HeaderLayout.jl`.

```julia
struct FieldSpec
    name::Symbol
    type::Type
    offset::Int      # bits, from the start of the header
    width::Int       # bits
    base::Symbol     # :bin | :dec | :hex | :mac | :ipv4 | :enum
end

struct HeaderLayout
    name::Symbol
    length::BitLength
    fields::Vector{FieldSpec}
end

header_layout(::Type{H})::HeaderLayout where {H <: Fields}
```

The descriptor is a constant, computed by the macro and returned by a method on
the type. It costs nothing at run time and it is the only reflection the diagram
needs. `field_value(h, spec)` reads one field and returns the raw bits, so the
diagram never calls `getfield` with a name it guessed.

This is what makes the plan's second half possible without a second description
of the layout. The codec and the figure read the same declaration, so they
cannot disagree — the same argument
[IR-DECLARED-HEADERS](../../documentation/requirements.md#ir-declared-headers)
makes about the codec pair.

## 6. The headers

Put one file per protocol under `package/packet/main/protocol/`. Each file holds
the declaration, the constants that belong to it, and the constructors a caller
wants. No behaviour, no simulator, no state.

### 6.1 `protocol/Ethernet.jl`

`EthernetPhyHeader` — IEEE 802.3 clause 4, 8 bytes.

| field | type | bits |
| --- | --- | --- |
| `preamble` | `UInt64` | 56 |
| `sfd` | `UInt8` | 8 |

Default the preamble to seven `0x55` octets and the start-frame delimiter to
`0xD5`.

`EthernetMacHeader` — 14 bytes.

| field | type | bits |
| --- | --- | --- |
| `dst` | `MacAddress` | 48 |
| `src` | `MacAddress` | 48 |
| `ethertype` | `EtherType` | 16 |

`EthernetFcs` — 4 bytes, one `UInt32` shown as hexadecimal.

`Ieee8021qTag` — 4 bytes, optional in the build order: `tpid` 16, `pcp` 3,
`dei` 1, `vid` 12. It is a chunk of its own, not a part of the MAC header,
because that is where it sits on the wire.

Keep the constants that
[`EthernetFrame.jl`](../../package/linklayer/main/t1s/EthernetFrame.jl) already
defines: the minimum and maximum frame length, the interframe gap and the
ethertype numbers. Move them here and let the link layer import them.

### 6.2 `protocol/Ipv4.jl`

`Ipv4Header` — RFC 791, 20 bytes, `ihl` fixed at 5.

| field | type | bits | base |
| --- | --- | --- | --- |
| `version` | `UInt8` | 4 | bin |
| `ihl` | `UInt8` | 4 | bin |
| `dscp` | `UInt8` | 6 | bin |
| `ecn` | `UInt8` | 2 | bin |
| `total_length` | `UInt16` | 16 | dec |
| `identification` | `UInt16` | 16 | hex |
| `flags` | `UInt8` | 3 | bin |
| `frag_offset` | `UInt16` | 13 | dec |
| `ttl` | `UInt8` | 8 | dec |
| `protocol` | `IpProtocol` | 8 | enum |
| `header_checksum` | `UInt16` | 16 | hex |
| `src_address` | `Ipv4Address` | 32 | ipv4 |
| `dst_address` | `Ipv4Address` | 32 | ipv4 |

Add the three flag names as constants — `IPV4_FLAG_DF` and `IPV4_FLAG_MF` — and
the protocol numbers the library uses.

### 6.3 `protocol/Udp.jl`

`UdpHeader` — RFC 768, 8 bytes: `src_port` and `dst_port` as `PortNumber`,
`length` as `UInt16`, `checksum` as `UInt16` shown as hexadecimal.

A field named `length` is safe. `Filler` and `Raw` already have one, and field
access never shadows `Base.length`.

### 6.4 `protocol/Tcp.jl`

`TcpHeader` — RFC 9293, 20 bytes, `data_offset` fixed at 5.

| field | type | bits | base |
| --- | --- | --- | --- |
| `src_port` | `PortNumber` | 16 | dec |
| `dst_port` | `PortNumber` | 16 | dec |
| `sequence_number` | `UInt32` | 32 | dec |
| `acknowledgment_number` | `UInt32` | 32 | dec |
| `data_offset` | `UInt8` | 4 | bin |
| `reserved` | `UInt8` | 4 | bin |
| `cwr` `ece` `urg` `ack` `psh` `rst` `syn` `fin` | `Bool` | 1 each | bin |
| `window` | `UInt16` | 16 | dec |
| `checksum` | `UInt16` | 16 | hex |
| `urgent_pointer` | `UInt16` | 16 | dec |

Eight one-bit flags is the honest declaration, and it is what makes the figure
show the flag row the way RFC 9293 draws it. RFC 9331 renames the top reserved
bit to `AE`; keep four reserved bits and note the rename in a comment.

### 6.5 What the plan leaves out

Record the drops, as
[IAR-DERIVE-DONT-TRANSLITERATE](../../documentation/architecture-requirements.md#iar-derive-dont-transliterate)
asks.

- IPv4 options and TCP options. A variable-length tail needs a width that
  depends on a field the reader already read. The macro cannot express that
  today, and the user scoped it out.
- IPv6, and with it 128-bit fields. `UInt64` bounds every field this plan
  declares.
- Checksum arithmetic. The headers carry the checksum field; nothing computes
  it. INET's default `fcsMode` is `declared` and this matches it. Section 13
  keeps the follow-up.

## 7. Move the headers that exist

Three sets of declarations become one. Do this in the same phase that adds the
new files, so no name is declared twice at any commit.

1. Delete [`demo_headers.jl`](../../package/packet/example/demo_headers.jl).
   `InetPacketExample` re-exports the headers from `InetPacket` instead.
   `src_addr` becomes `src_address`, `dst_addr` becomes `dst_address`, and
   `udp_length` becomes `length`.
2. Repoint the file marker in
   [`Headers.md`](../../package/inet/example/demo/pages/Headers.md). It quotes
   `../../../packet/example/demo_headers.jl`, which will not exist.
3. Rename the declarations inside
   [`phase3_headers.jl`](../../package/packet/test/phase3_headers.jl). That file
   tests the **macro**, so its headers must keep their own names — prefix them
   with `Test` — or they collide with the imported ones.
4. Cut `EthernetMacHeader` and `EthernetFcs` from
   [`EthernetFrame.jl`](../../package/linklayer/main/t1s/EthernetFrame.jl). Keep
   `build_ethernet_frame`. Drop `mac_pack`, `mac_hi` and `mac_lo`; a
   `MacAddress` needs no split.
5. Warning: `MacFsm.jl` is generated. It reads `hdr.dst_mac_hi` at line 313.
   Edit the machine in
   [`tool/generate_mac_fsm.jl`](../../tool/generate_mac_fsm.jl) at line 341 and
   run the generator again. Do not edit the generated file
   ([IAR-EDIT-THE-MACHINE](../../documentation/architecture-requirements.md#iar-edit-the-machine)).
6. Update `T1s.jl`, `phase1_frame.jl` and the other call sites the grep in the
   research turned up.

The wire bytes do not change. A 48-bit address writes the same 48 bits whether
it arrives as one value or as two. So the T1S golden hashes must come out
bit-for-bit equal
([IAR-GOLDEN-HASHES](../../documentation/architecture-requirements.md#iar-golden-hashes)).
Treat a changed hash as a defect in the migration, not as a new baseline.

## 8. The diagram, and the projection that makes it

A packet may sit inside the document a reader is looking at — a field of a page,
a value in a simulation document, an element of a list. The renderer reaches
such a value by type dispatch, and dispatch hands the value to a **projection**.
A plain builder function is unreachable from there. So the first stage of the
chain is a projection whose input is a `Packet`:

```
Packet → PacketToPacketDiagram → PacketDiagram → PacketDiagramToText → TextBlock → TextToGraphics
```

`print_document` dispatches on the input value, not on a document type, which is
how [`ObjectToSyntax.jl`](../../../projectured-julia/package/visual/main/syntax/ObjectToSyntax.jl)
prints plain Julia objects. A `Packet` is a legal input.

`PacketDiagram` is therefore **projection output**, not a domain document. It is
the same role `ChartPlot` plays for `Chart` and `GraphLayout` plays for
`GraphGraph`: the semantic content stays where it is, and the view state that
only a view can have — the row width, which bands are collapsed, the selection —
lives on the projected document.

### 8.1 The documents

Put the types in
`package/inet/main/packetdiagram/PacketDiagram.jl`.

```julia
@document struct PacketDiagram <: PacketDiagramDocument
    packet::Any = nothing                # the Packet this was projected from
    label::String = ""
    row_bits::Int = 32                   # view state: bits per grid row
    bands::CellVector = CellVector()     # DiagramBand, in reading order
end

@document struct DiagramHeaderBand <: DiagramBand
    name::String = ""
    offset::Int = 0                      # bits, from the start of the packet
    width::Int = 0
    quality::Symbol = :complete
    collapsed::Bool = false              # view state: the reader folded this band
    fields::CellVector = CellVector()    # DiagramField
end

@document struct DiagramField <: PacketDiagramDocument
    name::String = ""
    offset::Int = 0                      # bits, from the start of the band
    width::Int = 0
    value::UInt64 = 0                    # the raw bits, always
    text::String = ""                    # the value, formatted
    base::Symbol = :dec
end

@document struct DiagramOpaqueBand <: DiagramBand
    kind::Symbol = :filler               # :filler | :raw | :slice
    name::String = ""
    offset::Int = 0
    width::Int = 0
    preview::String = ""
end
```

A band holds strings and integers, never a `Chunk`. The bands are what the
figure draws, and drawing must not reach into the packet's internals — the same
reason [`Packets.jl`](../../package/inet/example/Packets.jl) gives for not using
generic reflection. The `packet` field on the root is the exception, and it is
the projection's own back-pointer, not content.

`value` and `text` are both stored although `text` derives from `value`. The
projection knows the field's Julia type and can format a `MacAddress`; the
printer downstream only sees the document. Store the formatted text once, and
keep the raw bits so the printer can fall back to a shorter base when a cell is
too narrow.

### 8.2 The projection

Put it in `package/inet/main/packetdiagram/PacketToPacketDiagram.jl`. Follow
[`ChartToChartPlot.jl`](../../../projectured-julia/package/domain/main/chart/ChartToChartPlot.jl),
which is the same shape one layer over.

```julia
struct PacketToPacketDiagram <: Projection end

@iomap struct PacketToPacketDiagramIoMap
    projection::Any
    input::Any
    output::Any
end

function print_document(p::PacketToPacketDiagram, recursion, pk::Packet, ctx)
    diagram = PacketDiagram(Cell(pk), Cell(""), Cell(32),
                            ComputedCell(() -> diagram_bands(pk)))
    PacketToPacketDiagramIoMap(p, pk, diagram)
end
```

The projection is stateless. Everything it produces lives on the `PacketDiagram`
it emits, and the diagram is built **once per projection setup**, so it keeps
its identity: a reader who set `row_bits` to 16 or collapsed a band keeps that
across a re-render, exactly as a chart keeps its zoom when a column changes.

`diagram_bands(pk)` walks the chunk tree:

- A `Fields` chunk becomes a `DiagramHeaderBand`, and `header_layout` gives its
  fields.
- A `Filler`, a `Raw`, or a `Slice` that does not cover a whole header becomes a
  `DiagramOpaqueBand`.
- A `Sequence` contributes its children in order.

Do not build the bands from `dissect`. `dissect` reports the field values but
not their bit offsets or widths, so the figure cannot be drawn from it.

### 8.3 What makes the figure refresh

A `Packet` holds no reactive cells, and it can hold none: `InetPacket` may not
import the kernel that defines them. So the packet cannot announce its own
change, and the invalidation comes from the cell that holds the packet.

- **The packet is replaced.** The holder writes a new `Packet` into its field.
  That field is a cell, so the child projection is re-run and a fresh diagram
  appears. This is the normal case, and it needs no extra machinery.
- **The packet is mutated in place.** `pushfirst!` on the envelope changes what
  the packet means without touching any cell. Nothing invalidates and the figure
  goes stale. The holder must write the field again to announce it.

State this in the reference guide as the rule it is: **a document that holds a
packet announces a change by writing the field, not by mutating the packet.**
Give `refresh_packet_diagram!(diagram)` for the case where the holder cannot,
which rewrites `diagram.bands` from `diagram.packet`.

Note what does *not* break on a refresh. A selection is a reference **path**,
not a pointer to a node, so a rebuilt band at the same index keeps the caret.
Only view state that lives on a rebuilt node would be lost, which is why
`row_bits` sits on the root and `collapsed` sits on the band that a reader
folded.

### 8.4 The reference mapping

`map_reference_forward` maps the empty reference to `::PacketDiagram`. There is
nothing else to map: a `Packet` has no reference steps, so no path can point
inside it.

`map_reference_backward` maps `::PacketDiagram` to the empty reference and
everything below it to `nothing`. This stage is a wall for edits, and it says so
in one place. Phase 9 is what changes that: an edit becomes an operation that
rebuilds the packet and writes it into the holder's field, which is the same
announcement rule as section 8.3.

A wall here is not unusual — `ReferenceInspectorToText` returns `nothing` from
both mappers and is display-only by design. What matters is that the wall is one
stage, named, and not spread over the pipeline.

## 9. The row layout

Put the pure functions in
`package/inet/main/packetdiagram/PacketDiagramGeometry.jl`. They take integers
and return cells. They import no projection and no font, so they are testable in
a REPL with nothing loaded.

### 9.1 The grid

- One continuous bit grid runs over the whole packet. A header does not start a
  new row. This is what "the headers flow through the packet" means, and it is
  the truth about the wire: an Ethernet MAC header is 14 bytes and does end in
  the middle of the fourth row.
- A row holds `row_bits` bits, 32 by default.
- Each bit is 2 characters wide. A row is `1 + 2 * row_bits` characters, so 65
  for the default.
- A field of `b` bits has an interior of `2b - 1` characters between its two
  borders.
- A field that crosses a row boundary splits into parts. Every part prints the
  name. Only the widest part prints the value; the others print `~`. When two
  parts tie, the first one wins.

### 9.2 The borders

- `|` separates two fields of the same header.
- `#` separates two headers. A header boundary in the middle of a row is a real
  boundary and must be visible.
- `+-+-+…+` separates two rows. Draw it as wide as the wider of the two rows it
  sits between.

Warning: use ASCII only — `+`, `-`, `|`, `#`, `~`. Do not use the Unicode
box-drawing characters. The SDL backend does not fall back to another face, and
a glyph the font lacks renders as an empty box.

### 9.3 The gutter and the titles

- A left gutter of 8 characters carries the byte offset of the row, as
  `0x0000`. Make it optional; the width is fixed so the grid stays aligned.
- A header's name floats on its own line above the row where the header starts,
  at the character column of the header's first bit. Shift it left when it would
  run past the right edge. Print the length beside the name.

### 9.4 The values

Format by the field's base:

| base | form |
| --- | --- |
| `:bin` | raw bit digits, no `0b` prefix — the figure already says these are bits |
| `:dec` | `60` |
| `:hex` | `0x003c` |
| `:mac` | `0a:00:00:00:00:01` |
| `:ipv4` | `10.0.0.1` |
| `:enum` | `UDP (17)` |

When the text is wider than the cell, shorten it in this order: drop the name
from an enum, change binary to hexadecimal, then truncate and mark the cut with
`*`. Every truncated value also goes into a legend line under the figure, so no
value is unreadable.

### 9.5 Long opaque bands

A 1500-byte payload is 375 rows of nothing. Collapse a `DiagramOpaqueBand`
longer than `max_opaque_rows` — 2 by default — into one full-width box that
names the kind, the length and the fill. The grid restarts at the end of the
band, and the gutter keeps the true offset.

### 9.6 The specimen

This is the target output for a 78-byte frame: Ethernet MAC, IPv4, UDP, a
32-byte filler payload and the FCS. It is generated from the rules above, so
treat it as the specification of the format and as the golden snapshot of the
first test.

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

Read the fourth grid row. The `#` after `ethertype` is where the MAC header ends
and IPv4 begins, 14 bytes in, in the middle of a row. No other figure of this
packet says that.

## 10. The printer

Put it in `package/inet/main/packetdiagram/PacketDiagramToText.jl`. Follow
[`ReferenceInspectorToText.jl`](../../../projectured-julia/package/visual/main/inspector/ReferenceInspectorToText.jl):
a hand-written `print_document` that returns a `TextBlock` built inside a thunk,
and a `SimpleIoMap`.

```julia
@projection struct PacketDiagramToText <: Projection
    row_bits::ImmutableCell{Int}
    show_offsets::ImmutableCell{Bool}
    show_values::ImmutableCell{Bool}
    max_opaque_rows::ImmutableCell{Int}
    font::ImmutableCell{DStyleFont}
    chrome_color::ImmutableCell{DStyleColor}
    title_color::ImmutableCell{DStyleColor}
    name_color::ImmutableCell{DStyleColor}
    value_color::ImmutableCell{DStyleColor}
end
```

Four rules bind the printer.

1. Build the spans inside the `TextBlock(() -> …)` thunk. Every cell the printer
   reads must be read inside a cell, or the figure freezes at its first render.
2. Emit a flat sequence of `TextString` spans with `TextNewline` between rows.
   Do not emit `TextLine`. `TextToGraphics` does not lay `TextLine` out yet, and
   a line-structured block renders blank there.
3. Use one font for everything inside the grid. Colour may vary, because colour
   does not change the advance width; a bold face can. Give the title line its
   own line so a second face there cannot disturb the grid.
4. Return `SimpleIoMap(p, input, out)`. In the first version
   `map_reference_forward` and `map_reference_backward` return `nothing`, which
   makes the figure display-only. Section 12 phase 8 replaces them.

The mappers of this stage stay `nothing` in the first version, so the figure is
display-only end to end. Phase 9 gives this stage the span table that maps a
cell of the grid to the field it draws; the stage above it is a wall for edits
until the same phase gives the packet a write-back path (section 8.4).

The whole chain, and the entry that installs it:

```julia
packet_projection(; measure = truetype_measure_text) =
    ChainingProjection(PacketToPacketDiagram(),
                       PacketDiagramToText(),
                       TextToGraphics(measure = measure))

packet_diagram_entry(; measure = truetype_measure_text) =
    Packet => packet_projection(measure = measure)
```

The entry is keyed on `Packet`, not on `PacketDiagram`. That is the point of
section 8: a packet anywhere in a viewed document draws as the figure, with no
conversion at the place that holds it. Check in phase 8 that the dispatch table
of `NaturalToGraphics` keys a plain struct as readily as a document type; if it
does not, the fix belongs there and not here.

Add one more function beside the printer for the tests and the REPL:
`packet_diagram_string(pk; kwargs...)` renders through `TextToString` and
returns a `String`. It needs no window.

## 11. Where the code lives

New files in `package/packet/main/`:

```
FieldTypes.jl              the four generic functions and the value types
HeaderLayout.jl            FieldSpec, HeaderLayout, header_layout
protocol/Ethernet.jl       PHY header, MAC header, FCS, 802.1Q tag, constants
protocol/Ipv4.jl           Ipv4Header and its constants
protocol/Udp.jl            UdpHeader
protocol/Tcp.jl            TcpHeader
```

Include them from [`Packet.jl`](../../package/packet/main/Packet.jl) in that
order, after `Header.jl`, and add the new names to its `export` list.

New files in `package/inet/main/`:

```
packetdiagram/PacketDiagram.jl           PacketDiagramModule root, the include order
packetdiagram/DiagramDocument.jl         the projected documents
packetdiagram/DiagramGeometry.jl         rows, cells, widths — pure functions
packetdiagram/PacketToPacketDiagram.jl   the first stage, and diagram_bands
packetdiagram/PacketDiagramToText.jl     the printer, the chain, the entry
```

Include the module root from [`Inet.jl`](../../package/inet/main/Inet.jl) and
export `PacketDiagramModule`, as `Inet` already exports `PacketModule` and
`T1sModule`.

Add one dependency to `package/inet/main/Project.toml`:

```toml
ProjecturedVisual = "c94a1234-2b3c-4d5e-8f6a-7b8c9d0e1f23"
```

with `[sources]` reaching `../../../../projectured-julia/package/visual/main`.
`ProjecturedVisual` re-exports the kernel and base modules as its own
(`ProjecturedVisual.CellModule`, `.DocumentModule`, `.ProjectionApiModule`,
`.CollectionModule`, `.ChainingProjectionModule`), and it owns `TextBlock`, the
fonts and `TextToGraphics`. Do not depend on the `Projectured` umbrella here —
it pulls in the domains and the backends this slice does not use. The root
environment already lists what is needed, so no change is needed there.

## 12. Build order

Work in a git worktree, created as a **sibling** of `inet-julia` in
`/home/projectured/workspace/`. A worktree inside the checkout breaks every
relative `[sources]` path. Commit at the end of each phase and mark the phase
done in this file.

### Phase 1 — the field types — **DONE**

- [x] Add `FieldTypes.jl` with the four generic functions and the defaults.
- [x] Add the five value types with their `Base.show` methods.
- [x] Extend `@header`: field types, the display override, field defaults.
- [x] Add `phase8_field_types.jl`.

Gate: `phase3_headers.jl` still passes unchanged. The macro's old two forms must
keep working. **Met** — `test_packet()` gives 1753 passes and no failure.

Two things the build settled:

- `field_base` takes the width as a second argument. The default depends on the
  declared width, not on the type alone, and only the macro knows the width.
- `Base.convert` is defined from `Integer` to each value type, so
  `EthernetMacHeader(0x0a0000000002, 0x0a0000000001, 0x0800)` still works. That
  is what keeps the link-layer call sites of phase 4 readable.

### Phase 2 — the layout descriptor — **DONE**

- [x] Add `HeaderLayout.jl`.
- [x] Emit `header_layout` from `@header`.
- [x] Extend `phase8_field_types.jl`: the offsets are contiguous, the widths sum
      to `chunk_length`, and the field order matches the declaration.

Two decisions the build made:

- The macro emits `const _HEADER_LAYOUT_<Name>` beside the struct and returns it
  from `header_layout`. The descriptor is built once, at declaration time, so a
  view may call it on every render.
- `field_text` lives here, not in the projection. The value types already know
  how to print themselves, and one formatter serves the REPL, the tests and the
  figure. It takes an optional base, which is how a view shortens a value that
  does not fit its cell.

### Phase 3 — the headers — **DONE**

- [x] Add the four files under `protocol/`.
- [x] Add `phase9_protocol_headers.jl` with the golden byte vectors.
- [x] Rename the declarations of `phase3_headers.jl` with a `Test` prefix. That
      step belonged to phase 4, but the collision it predicted appeared here:
      the test file declares `Ipv4Header` in the same scope that now imports
      one.

Gate: the twenty IPv4 bytes on the
[Headers page](../../package/inet/example/demo/pages/Headers.md) —
`45 00 00 3c 00 00 00 00 40 11 00 00 0a 00 00 01 0a 00 00 02` — come out of the
new declaration byte for byte. **Met**, and `test_packet()` gives 1892 passes
and no failure.

Two things the build settled:

- `@header` now wraps the struct in `Base.@__doc__`. Julia refuses to document a
  macro that expands to a block, so without it a header could not carry a
  docstring — and every declared header wants one.
- `Ieee8021qTag` is declared. It is fixed-size, it costs four lines, and a
  frame that carries a VLAN tag is otherwise unrepresentable.

### Phase 4 — move the old declarations — **DONE**

- [x] Do the six steps of section 7.
- [x] Regenerate `MacFsm.jl` from the machine. The regenerated diff is the one
      intended line, `dst = hdr.dst.value`.

Gate: `test_packet()`, `test_linklayer()` and `test_inet()` pass, and the T1S
golden hashes are unchanged. **Met** — 1892, 494 and 164 passes, no failure.
The `notraffic` and `bestcase` pins reproduce, which is the check that a 48-bit
address writes the same 48 bits it did as two halves.

Three things the build settled:

- Each value type needs an identity constructor (`EtherType(t::EtherType) = t`).
  An inner constructor taking an `Integer` replaces the default one, so without
  it a value could not be passed where one is built.
- `SourceConfig.ethertype` becomes an `EtherType`. The model kept a `UInt16`
  and defaulted it to `ETHERTYPE_IPV4`, which is now typed; taking the type is
  the honest fix, and an integer still converts at the keyword.
- The model keeps `UInt64` for a MAC address in `MacState` and `SourceConfig`.
  The machines compare addresses as integers, `MacAddress` converts from one,
  and widening that to the whole link layer is not this plan's work.

New files are listed unsealed in `SEALING.md` in the commit that lands them,
as its own rule asks, rather than at the end in phase 12.

### Phase 5 — the documents and the first stage — **DONE**

- [x] Add the ProjecturEd dependency to `package/inet/main/Project.toml`.
- [x] Add `DiagramDocument.jl` with the projected documents.
- [x] Add `PacketToPacketDiagram.jl` with the projection, `diagram_bands` and
      `refresh_packet_diagram!`.
- [x] Test `diagram_bands`: band count, offsets, field values, one collapsed
      band.
- [x] Test the view state: `row_bits` set by hand stays set.
- [x] Test the forward mapper: the empty reference maps to `::PacketDiagram`,
      and the backward mapper is a wall.

Four things the build settled:

- **One dependency, not three.** `ProjecturedVisual` re-exports the kernel and
  base modules as its own (`ProjecturedVisual.CellModule` and the rest), so it
  reaches everything the slice needs without the domains and the backends the
  `Projectured` umbrella would pull in.
- **The slice is one submodule**, `PacketDiagramModule`, with a module root that
  names the include order — the same shape as `T1sModule`. Four modules that
  import each other would buy nothing.
- **`bands` is a `ComputedCellVector` over the `packet` cell.** That is what
  makes the announcement rule of section 8.3 a mechanism rather than a
  convention: writing `diagram.packet` re-derives the bands, and
  `refresh_packet_diagram!` is just that write.
- **`quality` on a band is a `String`, not a `Symbol`** — empty when the chunk
  is complete. The printer prints it; nothing dispatches on it.

A trap for the next environment change: `Pkg.resolve()` does **not** notice a
new dependency in a path-dependency's `Project.toml`. Delete the `Manifest.toml`
and instantiate. It is gitignored, so this costs nothing.

### Phase 6 — the row layout — **DONE**

- [x] Add `DiagramGeometry.jl`.
- [x] Test: a field that splits across a row, a header boundary in the middle of
      a row, a truncated last row, a collapsed band.

`diagram_rows` returns `DiagramRow`s of two kinds: a `:grid` row carrying cells,
and a `:box` row standing for one collapsed opaque band. The grid restarts after
a box, so a row always begins where the last one ended and the gutter keeps the
true offset.

### Phase 7 — the printer — **DONE**

- [x] Add `PacketDiagramToText.jl`, `packet_projection`,
      `packet_diagram_entry` and `packet_diagram_string`.
- [x] Pin the specimen of section 9.6 as a golden snapshot.

Three things the build settled:

- The specimen lives in `package/inet/test/packetdiagram-figure.txt` and the
  test reads it verbatim. A triple-quoted Julia string will not do: Julia
  de-indents one, and the gutter of this figure is exactly the leading
  whitespace it would strip. Section 9.6 is now that file's content.
- `frag_offset` takes a `| dec` override. The width rule made it binary, and
  thirteen zeros in a cell say less than one `0` does. This is the first field
  where the default was wrong, and it is what the override exists for.
- A collapsed band's fill moved from its name into its preview, so the box
  reads `Filler  32 B  fill=0x00` — name, then length, then what it holds, in
  the order every other band uses.

### Phase 8 — the demo page — **DONE**

- [x] Check that the dispatch table of `NaturalToGraphics` accepts `Packet` as a
      key. It does — the table is keyed by type, and nothing requires a document
      type.
- [x] Add `packet_diagram_entry` to the `extra` list of `demo_projection`.
- [x] Change the `packet("name")` marker in
      [`Packets.jl`](../../package/inet/example/Packets.jl) to splice the
      `Packet` itself, and add `packet_tree("name")` for the chunk tree. The two
      views are two projections of one packet, and a page names the one its
      prose is about; `PacketIsChunks.md` moved to the tree marker.
- [x] Add `pages/PacketDiagram.md` and link it from `index.md`.
- [x] Build the frame of section 9.6 in `InetPacketExample` (`make_frame`) so
      the page shows a full stack, not one header.

Gate: the page shows the figure with no conversion in the marker function.
**Met** — `test_inet()` gives 281 passes, and a new case in `demo.jl` renders
the page through the chain `run_demo` builds and finds the grid, a header title
and a MAC address in what it draws.

### Phase 9 — selection and edit — **DEFERRED**

The figure is display-only until this phase. Two seams open, in this order.

1. **Selection.** `PacketDiagramToText` records which span draws which field and
   stores the table in its IO map. Its two mappers then translate between a
   field of the diagram and a span of the text, so a click on a cell selects the
   field and a caret can walk the grid.
2. **Edit.** A typed digit becomes an operation on `DiagramField.value`.
   `PacketToPacketDiagram` turns that into a rebuilt header, a rebuilt packet,
   and a write into the field that holds the packet — the announcement rule of
   section 8.3, run backward. Until this exists the stage returns `nothing` from
   `map_reference_backward` and the wall stands.

Do this only after phase 8 shows the figure is worth editing.

### Phase 10 — dissect raw bytes — **DEFERRED**

A packet received from a wire holds `Raw` bytes, not header structs, so the
figure shows one opaque band. A dissector walks the bytes with a next-protocol
table — ethertype picks IPv4, protocol picks UDP or TCP — and returns the header
chain. It is small while the headers are fixed-size, and it is what makes the
figure work on captured traffic.

### Phase 11 — the checksums — **DEFERRED**

Add `ipv4_header_checksum`, `udp_checksum`, `tcp_checksum` and `ethernet_fcs`.
The figure can then mark a checksum field as correct or wrong, which is the
first thing anybody looks for in such a figure.

### Phase 12 — documentation and the seal list — **PENDING**

- [ ] Extend [`packet.md`](../../package/packet/doc/packet.md): the field types,
      the layout descriptor, the header inventory.
- [ ] Add `package/inet/doc/packet-diagram.md` with the specimen and the rules.
- [ ] Insert every new file into [`SEALING.md`](../../SEALING.md), unsealed, at
      its include position.
- [ ] Update the `inet` row of
      [`architecture.md`](../../documentation/architecture.md): the umbrella now
      depends on the ProjecturEd stack and owns the packet diagram.
- [ ] Move this plan to `plan/done/`.

## 13. Tests

| what | where | command |
| --- | --- | --- |
| field types, layout descriptor | `package/packet/test/phase8_field_types.jl` | `julia --project=package/packet/test -e 'using InetPacketTest; test_packet()'` |
| the headers, golden bytes | `package/packet/test/phase9_protocol_headers.jl` | the same |
| link layer after the move | `package/linklayer/test/` | `julia --project=package/linklayer/test -e 'using InetLinkLayerTest; test_linklayer()'` |
| projection, geometry, printer | `package/inet/test/packetdiagram.jl` | `julia --project=package/inet/test -e 'using InetTest; test_inet()'` |

Four kinds of assertion carry the weight.

1. **Golden bytes.** Serialize a header built by hand and compare against the
   octets a capture shows. This is what makes "accurate" checkable.
2. **Round trip.** Deserialize the golden bytes and compare field by field
   against the header that produced them.
3. **The descriptor agrees with the codec.** For every declared header, the sum
   of the field widths equals `chunk_length`, and the offsets are contiguous
   from zero. A descriptor that disagrees with the codec is the one failure this
   design exists to prevent.
4. **The golden figure.** `packet_diagram_string` of the phase 8 frame equals
   the specimen of section 9.6, character for character. Assert the whole
   string, not a substring: the figure is alignment, and a substring test cannot
   see alignment.

Add the geometry tests as plain function calls. They need no packet and no
editor, so they run in milliseconds and locate a layout defect exactly.

## 14. Open questions

1. **Does `#` read as a header boundary?** It is the only ASCII character that
   is visibly heavier than `|` and is not already used. Look at the rendered
   figure in phase 7 and change it if it reads as noise.
2. **Should `row_bits` follow the header?** Ethernet reads better at 16 bits per
   row, IPv4 at 32. A per-band override is one field on `DiagramHeaderBand`.
   Decide after phase 7, from the rendered figure.
3. **Where does the legend go?** Section 9.4 puts truncated values under the
   whole figure. Under each header is also defensible. Decide when a truncated
   value first appears in a real packet.
4. **Does the umbrella pay too much?** Measure the load time of `using Inet`
   before and after phase 5. If the editor stack costs more than a second,
   reopen the placement decision of section 2.

## 15. Rejected alternatives

**A separate `protocol` or `view` package.** Both were offered and both were
declined. The record matters for the audit: `InetPacket` now knows protocol
names by decision, not by accident, and `Inet` depends on the editor stack by
decision, not by drift.

**A builder function instead of a first projection stage.**
`packet_diagram(pk)` would return the document, and the chain would start at
`PacketDiagram`. It reads simply, and it is unreachable. A packet held inside a
viewed document is drawn by type dispatch, and dispatch calls a projection — so
every document that could hold a packet would have to convert it by hand before
the renderer ever saw it. The two real limits of a `Packet` — no cells, no
reference steps — do not go away under either shape; sections 8.3 and 8.4 name
where each one lands.

**Generic reflection over the header struct.** `ObjectToWidget` would render a
header without any new code, and it would render the Julia struct — field names
and types, no bit offsets, no wire order. The figure is about the wire, and the
wire is exactly what generic reflection does not see.

**A string renderer with no document.** `describe(pk)` already prints a tree,
and a second function could print the figure. It would be a picture of a packet
rather than the packet, as
[`Packets.jl`](../../package/inet/example/Packets.jl) argues. A document can be
navigated, selected and later edited; a string cannot.

**One `Vector{FieldSpec}` computed at run time.** Walking `fieldnames` and a
width table at each render is simpler to write and wrong in the same way a
hand-written codec is wrong: it is a second description of the layout. The macro
already knows the widths. Let it say so.
