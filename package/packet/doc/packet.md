# Packet & chunk API

A representation-independent packet data model for `inet-julia`,
derived from INET's `Chunk`/`Packet` API but redesigned around Julia's type
system. Design rationale, decisions and requirements: `plan/*/packet-chunk-api.md`.

## Where it lives

`src/packet/` — a self-contained module `Inet.PacketModule`. It depends on
neither `Omnetpp` nor the rest of `Inet`, so it is usable on its own. Its one
dependency is `ProjecturedKernel`, the document substrate.

## Every type here is a document

A packet, a chunk and a header are ProjecturEd **documents**. That is what makes
a live packet a thing an inspector opens, a reference points into and a
projection watches — with no shadow, no sync and no snapshot of it.

Being a document costs nothing here, because each type says which layout its
bare name is:

| type | layout | why |
| --- | --- | --- |
| `Packet` | `[M, C]` — the mutable native struct | the envelope a simulation mutates on every hop |
| `Filler`, `Raw`, `Slice`, `Sequence`, `MarkedFields` | `[C]` — the cell layout | a chunk is a value, and a slice's smart constructor types its own cell |
| every `@header` | `[I, C]` — the immutable native struct | a header is a value the codec reads field by field |
| `TagSet`, `RegionTag` | `[DC]` — the default spelling | a tag is stored by value in a field |

Every one of them writes `selection::Nothing` rather than taking the injected
`Union{Nothing, Reference, SelectionDocument}`. The injected field is a union
over heap types, and one of them in the struct would take `Filler` from 16 bytes
inline to 24 on the heap. **Nothing a simulation touches is reactive**, and the
allocation numbers say so: not one hot-path measurement moved when these types
became documents.

`live_packet(pk)` is the envelope as a reactive document, over the chunks it
already holds. That is what an editor watches. It shares the chunks rather than
copying them, because a chunk is a value: in a cell layout of a header
`fieldtype` is a cell, so it has no wire form at all.

## Two layers

### Chunks — immutable, structurally shared payload

Four representations collapse to two leaves + two smart-constructor-gated
composites (compared with INET's five):

    Filler          length-only, no bytes materialised   (R1)
    Raw             actual bit-exact data                (R7)
    Slice{C}        internal view — smart-ctor only
    Sequence        internal rope — smart-ctor only

Plus `Fields` (the supertype of every declared header — Phase 3) and
`MarkedFields{H}` (a wrapper carrying non-`Q_COMPLETE` quality without
disturbing the header struct).

    payload = Filler(Bytes(1500))            # 16-byte isbits value, still
    bytes   = Raw(UInt8[…])                  # exact bit-length
    window  = slice(bytes, Bytes(2), Bytes(4))   # never nests

`sequence(parts)` and `slice(c, offset, length)` are the ONLY ways to build
composites. They enforce canonicalisation by construction:
- no `Slice`-of-`Slice`, no `Sequence`-of-`Sequence`, no singleton
- adjacent mergeable leaves are joined (same-fill `Filler`s, byte-aligned
  `Raw`s)
- cumulative offsets are precomputed so `chunk_length` is O(1) and `peek`
  locates a bit-offset via binary search (fixes INET defect 1)

### Packet — mutable envelope over immutable content

    @native_document struct Packet <: Document
        content::Chunk           # shared, immutable
        front::BitLength         # consumed prefix (retained)
        back::BitLength          # consumed suffix (retained)
        packet_tags::TagSet
        region_tags::RegionTagSet
        selection::Nothing
    end

The bare name is the plain `mutable struct` it has always been, field for field.
`@native_document` adds the family, the cell layout and the registry beside it,
and takes nothing away.

The read side of the API below takes `APacket`, the family, so both layouts
answer — the native envelope a simulation mutates and the one an editor watches.
The write side takes `Packet`, the native one, because a simulation is the only
thing that writes.

`dup(pk)` is O(1) — a fresh envelope pointing at the same content. That is
the exact contract the parallel kernel wants: per-thread envelopes, shared
frozen payload.

## The common verbs

INET's ~40 `peek*` / `insert*` / `remove*` methods collapse to Base verbs +
a `from = :front | :back` keyword. Reads by TYPE, not by position:

    pushfirst!(pk, ip_header)                # header
    push!(pk, ethernet_fcs)                  # trailer
    popfirst!(pk, Bytes(20))                 # consume 20 bytes
    peek(pk, Ipv4Header)                     # type-directed access
    peek(pk, EthernetFcs; from = :back)      # symmetric
    peek(pk, Raw; at = Bytes(20), length = Bytes(4))
    trim!(pk)                                # drop retained prefix/suffix

`peek(pk, T)` where `T <: Fields` defaults `length` to `chunk_length(T)`.

## Declared headers

`@header` produces the struct AND its codec from a single declaration —
no drift possible between them. Bit widths are first-class, a field may have a
type of its own, a display base and a default:

    @header Ipv4Header begin
        version         :: UInt8       | 4        = IPV4_VERSION
        ihl             :: UInt8       | 4        = IPV4_MIN_IHL
        dscp            :: UInt8       | 6        = 0x00
        ecn             :: UInt8       | 2        = 0x00
        total_length    :: UInt16
        header_checksum :: UInt16      | 16 | hex = 0x0000
        src_address     :: Ipv4Address
        # …
    end

Yields `struct Ipv4Header <: Fields`, `chunk_length(::Ipv4Header) =
Bytes(20)`, `serialize(io::BitWriter, h)`, `deserialize(::Type{Ipv4Header},
io::BitReader)`, `header_layout(Ipv4Header)`, a keyword constructor filling
every default, and a nice `show`. Headers whose codec cannot be described
declaratively (variable-length tails) just define `serialize`/`deserialize`
directly — dispatch wins.

### Field types

A field's type answers four questions, and any type may answer them:

    field_width(::Type{T})::Int              # the width when `| n` is absent
    field_encode(::Type{T}, value)::UInt64   # the bits that go on the wire
    field_decode(::Type{T}, bits::UInt64)::T # the value that comes back
    field_base(::Type{T}, width::Int)        # how a reader wants to see it

A `UInt64` stops at 64 bits, and an `Ipv6Address` is 128. A second pair owns
the stream instead of a number, and it is the pair the macro calls:

    field_write(io::BitWriter, ::Type{T}, value, width::Int, order::Symbol)
    field_read(io::BitReader, ::Type{T}, width::Int, order::Symbol)::T

A type that answers only the first four still works: the default `field_write`
is `write_bits!` of `field_encode`. Define the wide pair when the type is wider
than 64 bits, or when the decode needs the declared width — which is why the
signed integers define it. `Int16(-1)` in a 12-bit field is `0xfff` on the
wire, and it must read back as `-1`.

`FieldTypes.jl` answers them for the unsigned and the signed integers, `Bool`
and any `Enum`, and declares six types of its own: `MacAddress` (48 bits,
prints as `0a:00:00:00:00:01`), `Ipv4Address` (32, `10.0.0.1`), `Ipv6Address`
(128, `2001:db8::1`), `EtherType` (16, `IPv4 (0x0800)`), `IpProtocol` (8,
`UDP (17)`) and `PortNumber` (16). An `Integer` converts into any of the narrow
ones, so a call site may still pass a number.

The default display base depends on the declared width, not the type alone: a
field that is not a whole number of bytes reads as bits, and a whole number of
bytes reads as a number. `| hex`, `| dec` and the rest override it per field.

### Byte order, wire-only and model-only fields

Three more segments make a declaration say things it could not before.

    duration      :: UInt16 | 16 | le             # least significant byte first
    signature     :: UInt8  | 8  | constant(0x4E) # on the wire, not in the struct
    checksum_mode :: ChecksumMode | 0 = DECLARED  # in the struct, not on the wire

`| le` is what IEEE 802.11 needs: it writes its Duration, Sequence Control and
BA Control fields least significant byte first. A little-endian field must be a
whole number of bytes, because the byte is the unit the order applies to.

`constant(v)` makes a **wire-only** field. It takes width, writes `v`, discards
what it reads, and no struct field holds it. That is a reserved field and a
fixed delimiter. The clause is `constant` and not `const`, because `const` is a
reserved word and the line would not parse.

Width `0` makes a **model-only** field: in the struct, never on the wire. That
is how a header carries state its protocol needs and its format does not, which
is what INET's `ChecksumMode` and `FcsMode` are. It must have a default,
because a reader has no bits to fill it with.

### Derived values, checks and quality

Two more clauses make a declaration state what the codec computes and what it
refuses.

    ihl     :: UInt8 | 4 | derive(cld(bits(chunk_length(h)), 32)) = IPV4_MIN_IHL
    version :: UInt8 | 4 | check(version == 6)                    = IPV6_VERSION

`derive(expr)` computes the value on write and ignores the struct field; on
read it keeps what arrived, so a foreign sender's disagreement stays visible.
The result converts to the field's type, because Julia arithmetic widens to
`Int`.

`check(expr)` marks on read and throws on write. A packet that arrived
malformed is data, so the reader returns the header inside a `MarkedFields`
envelope carrying `Q_INCORRECT`; a header the model built wrong is a bug, so
the writer refuses it. `@check expr` on a line of its own is the same rule
across fields.

`peek` gates twice: once on the source chunk's quality, and once on what the
deserializer said. So `peek(pk, Ipv6Header)` refuses a version of 5, and
`peek(pk, Ipv6Header; incorrect = true)` returns the header.

Inside either clause, every field is bound by its own name and the header is
`h`. A header therefore cannot have a field named `h`.

A checksum needs no clause of its own — it is a `derive` that reads a
model-only mode field:

    checksum      :: UInt16 | 16 | hex |
                     derive(checksum_mode == CHECKSUM_COMPUTED ?
                            internet_checksum(h) : checksum) = 0x0000
    checksum_mode :: ChecksumMode | 0 = CHECKSUM_DECLARED

`Checksum.jl` gives `ChecksumMode`, `ones_complement_checksum` (RFC 1071),
`with_field` and `internet_checksum`. `CHECKSUM_DECLARED` is the default, as in
INET: the stored value goes out unchanged, which is what lets a capture
round-trip byte for byte. `internet_checksum` breaks the recursion by
serialising a copy whose mode is declared and whose checksum is zero.

### A length the data decides

A header may end in bytes whose count another field gives, or in padding.

    body :: Vector{UInt8} | length(Bytes(count))   # as many bytes as `count` says
    tail :: Vector{UInt8} | rest                   # the remainder of the window
    @pad to Bytes(4) fill 0x00                     # up to the next boundary

`rest` must be the last line, because it leaves nothing for a later field.

Such a header is **variable-length**, and three questions replace one:

    chunk_length(h)              # the length of THIS header — always works
    minimum_chunk_length(H)      # the fixed part — always works
    is_fixed_length(H)           # false, so `chunk_length(H)` has no answer

`chunk_length(H)` on a variable-length type raises an error that says which of
the other two to ask. `peek(pk, H)` with no `length` gives the reader the whole
remaining window and takes the length from the value that comes back.

Inside a clause, `offset` is where the codec is and `remaining` is what the
window has left. `remaining` exists on the read side only: a writer has no
window to have a remainder of. `serialize` walks the entries twice — an
arithmetic pass computes the derived values and the padding widths and runs the
checks, then a second pass writes — so a failed check refuses before any bits
reach the caller's writer.

### The layout descriptor

`header_layout(H)` returns the name, the bit offset, the bit width and the
display base of every field, as a constant built once when the header is
declared:

    for spec in header_layout(Ipv4Header).fields
        println(spec.name, " @", spec.offset, " +", spec.width, " ", spec.base)
    end

The descriptor describes the **wire**: a `constant` field is a field of it, and
a model-only field is not. For a variable-length header the TYPE layout stops
at the first variable entry, and `header_layout(h)` gives the whole thing with
the widths that header actually has.

`field_bits(h, spec)` reads one field's raw bits and `field_text(h, spec)`
formats it — with an optional base, which is how a narrow view falls back to a
shorter form. This is the only reflection a view of a packet needs, and it is
computed from the same declaration the codec is, so the two cannot disagree.

Three accessors go with it. `field_value(h, spec)` reads the struct, or the
constant when the field is wire-only. `is_constant(spec)` says which of the
two. `has_bits(spec)` says whether one `UInt64` describes the field at all — it
is `false` for an `Ipv6Address`, and a view that asks `field_bits` for one gets
an error rather than a wrong number.
`Inet`'s packet diagram is drawn from it.

## The protocol headers

`protocol/` declares the wire formats, one file per protocol. They are
declarations, not behaviour, which is why they sit in the package that depends
on nothing.

| header | bytes | file |
| --- | --- | --- |
| `EthernetPhyHeader` | 8 | `protocol/Ethernet.jl` |
| `EthernetMacHeader` | 14 | `protocol/Ethernet.jl` |
| `Ieee8021qTag` | 4 | `protocol/Ethernet.jl` |
| `EthernetFcs` | 4 | `protocol/Ethernet.jl` |
| `Ipv4Header` | 20 | `protocol/Ipv4.jl` |
| `Ipv6Header` | 40 | `protocol/Ipv6.jl` |
| `UdpHeader` | 8 | `protocol/Udp.jl` |
| `TcpHeader` | 20 | `protocol/Tcp.jl` |

Every one of them is fixed-size: `ihl` is 5 and `data_offset` is 5, so no
header here carries options. A variable-length tail needs a width that depends
on a field the reader already read, which the macro does not yet express —
`plan/*/protocol-header-inventory.md` §C designs it.

`Ipv6Header` is declared in the order `Ipv6HeaderSerializer.cc` writes, which
is **not** the order `Ipv6Header.msg` declares. The two disagree about where
the addresses go. The serializer is the wire format; a port that reads the
message file alone gets the header wrong.

## What a header says about itself

`describe_layout` says where the fields lie. `HeaderFacts.jl` answers the three
questions a view of a header asks next, and each is computed from the type:

    find_declaration(Ipv4Header)      # (file = ".../protocol/Ipv4.jl", line = 44)
    declaration_path(Ipv4Header)      # that file, as a path that exists now
    example_header(Ipv4Header)        # an instance: every field distinct, and
                                      # the header agreeing with its own bytes
    describe_construction(header)     # the call that rebuilds it
    describe_update(header)           # one field written, and the byte that moved

`@header` records where it expanded, and a header written by hand
passes `@__FILE__` to `register_header`. So a view shows the declaration itself
rather than a copy of it, and a renamed header fails loudly.

`describe_construction` names a field that has no default, and a field whose
value is not its default. It leaves out the rest, because the declaration
already decides them. A derived field is left out only when the writer can put
it back: `ihl` counts the header's own width, so nobody states it, while
`header_checksum` derives to *itself* unless the mode says to compute one. The
two are told apart by trying it rather than by reading the declaration's shape.

Two functions answer the two questions about one value:

    format_field(Ipv4Address("10.0.0.1"))    # "10.0.0.1"     — for a reader
    literal_field(Ipv4Address("10.0.0.1"))   # the constructor call — for the compiler

A field is read and written by name, which is what a caller holding a name has:

    get_field(header, :time_to_live)
    set_field(header, :time_to_live, 63)     # a header is immutable; this is a copy

`InetExample` puts all of it on a page: the gallery in the demo catalog shows
ten headers, and `plan/*/protocol-header-gallery.md` says how.

## R2 duality + R9 guard

Ask for a header type, get one, regardless of the source representation:

    peek(pk, Ipv4Header)     # source is a field struct → returned as-is
                             # source is a Raw          → deserialised
                             # source is a Sequence     → concatenated + deserialised
                             # source is a Slice        → descended

Cross-type reinterpretation is REFUSED unless the caller opts in — INET's
`Chunk.cc:120-131` rule preserved verbatim in spirit:

    peek(eth_pkt, Ipv4Header)                   # throws (R9)
    peek(eth_pkt, Ipv4Header; reinterpret = true)   # deliberately ugly

## Quality gate

Three monotone flags composed via bitwise OR (`⊔`). A `Sequence`'s quality
is the join over its children — automatically.

    mark_incomplete(chunk)
    mark_incorrect(chunk)
    mark_misrepresented(chunk)

The peek gate is strict-by-default; six INET `PF_ALLOW_*` bits become three
kwargs:

    peek(pk, UdpHeader)                    # throws if source is incorrect
    peek(pk, UdpHeader; incorrect = true)  # accept a bad checksum
    peek(pk, IpHdr; incomplete = true, incorrect = true, misrepresented = true)

## Tags

- **Packet tags** — type-keyed, at-most-one per packet. Cross-layer control:

        set_tag!(pk, L3AddressReq(dest))
        get_tag(pk, L3AddressReq)

- **Region tags** — `(type, bit-range)`-keyed, non-overlapping per type,
  attached to the content. This is R6, the sleeper feature: byte-range
  metadata that follows the data across segmentation and reassembly.

        add_region_tag!(pk, GenericAppMsgReq, 0:1023, GenericAppMsgReq(1, 1024))
        region_tags(pk, GenericAppMsgReq)   # → [(range, value), …]

## Buffers

- **`ChunkQueue`** — FIFO for TX queues. Straddling pop returns a normalised
  chunk; adjacent byte-Raws merge on push.
- **`ChunkBuffer`** — sparse offset-indexed buffer with explicit
  `OverlapPolicy` (`REFUSE`, `KEEP_EXISTING`, `OVERWRITE`) — fixes INET
  defect 3 (silent-overwrite is wrong for TCP retransmit). `region_at`,
  `gaps`, `is_complete_range`, `assembled_chunk` are the region-query API
  every INET caller wrote by hand (defect 4).

Reassembly and reorder are one call each over `ChunkBuffer`:

    b = ChunkBuffer()
    write!(b, Bytes(0),  Raw(…))
    write!(b, Bytes(8),  Raw(…))
    is_complete_range(b, 0:95) && assembled_chunk(b, 0:95)

## Inspection

`dissect(pk)` returns a `Vector{Dissection}` — a nested description of the
packet's structure, including per-field entries for `Fields`. `describe(pk)`
prints it as an indented tree. The plan (§6.7) proposes wiring this into
`projectured-julia` as an interactive projection over the same data
structure the simulation runs on.

## Non-obvious design decisions

- **`chunk_length(c)::BitLength`, not `Base.length`.** Julia's `Base.length`
  must return an `Integer` count — overloading it with a `BitLength` breaks
  `collect`, `sum`, and every generic iterator that probes the size.
- **`peek` extends `Base.peek`.** Matches Julia's stream convention (look
  without consuming) and avoids the ambiguity `Base.peek` would raise.
- **`@header` uses explicit `@__MODULE__` qualification.** Unescaped names
  in a macro's `function` form still resolve to the caller's module, so
  they would create shadows instead of adding methods to
  `PacketModule.serialize` etc.
- **Region tags: eager fix-up, not lazy.** The plan proposes lazy offset
  mapping for correctness (no invalidation bugs). The eager version has no
  invalidation bugs either — the envelope is the sole mutation point.
  Lazy vs eager is a measurement question best answered after Phase 8
  benchmarks.

## What's not shipped yet

- **`SerializedFields{H}` byte-round-trip cache** — for byte-exact
  deserialise→serialise even when the field model is lossy. The mark path
  currently uses `mark_misrepresented`; the cache is Phase 4 follow-up.
- **`Streaming` (R13)** — availability-vs-length disagreement, needed for
  cut-through. Not on the Phase 8 blocker path.
- **RoutingModel adoption (Phase 8)** — requires a captured benchmark
  baseline and golden-hash validation across all five topologies. Deferred
  as a separate gated task.
- **`Foreign` (§7 — INET C++ chunk pass-through)** — Phase 9, only if the
  compatibility work stream reaches the point of needing it.
