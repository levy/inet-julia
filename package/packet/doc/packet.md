# Packet & chunk API

A representation-independent packet data model for `inet-julia`,
derived from INET's `Chunk`/`Packet` API but redesigned around Julia's type
system. Design rationale, decisions and requirements: `plan/*/packet-chunk-api.md`.

## Where it lives

`src/packet/` — a self-contained module `Inet.PacketModule`. It depends on
neither `Omnetpp` nor the rest of `Inet`, so it is usable on its own.

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

    payload = Filler(Bytes(1500))            # 16-byte isbits struct
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

    mutable struct Packet
        content::Chunk           # shared, immutable
        front::BitLength         # consumed prefix (retained)
        back::BitLength          # consumed suffix (retained)
        packet_tags::TagSet
        region_tags::RegionTagSet
    end

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

### The layout descriptor

`header_layout(H)` returns the name, the bit offset, the bit width and the
display base of every field, as a constant built once when the header is
declared:

    for spec in header_layout(Ipv4Header).fields
        println(spec.name, " @", spec.offset, " +", spec.width, " ", spec.base)
    end

The descriptor describes the **wire**: a `constant` field is a field of it, and
a model-only field is not.

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
