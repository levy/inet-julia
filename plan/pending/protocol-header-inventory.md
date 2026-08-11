# The protocol header inventory, and the types that describe it

A wire format is a sequence of named fields of stated widths. INET says that
twice — a `.msg` file gives the field model and a hand-written `*Serializer.cc`
gives the bit layout — and the two drift. This plan says it once, in a Julia
struct, and derives everything else from the struct.

```julia
struct EthernetMacHeader
    destination    :: MacAddress
    source         :: MacAddress
    type_or_length :: EtherTypeOrLength
end
```

That is a complete header. `encode_header`, `decode_header`, `chunk_length`
and `describe_layout` work on it at once, because `fieldnames` and `fieldtypes`
already are the layout, and the codec is written once, generically, over them.

Status: **PENDING**. This is a redesign of the plan that phases 0 to 3
implemented. §11 says which of the landed commits survive it.

## 1. What the plan delivers

1. A machine-built inventory of every wire format INET declares, with the
   capability each one needs.
2. A set of value types that carry meaning and width, so a declaration reads
   like the standard that defines it.
3. One generic codec over `fieldtypes`, in place of a codec generated per
   header.
4. `@header`, which adds the two things a type cannot hold: defaults, and
   expressions over sibling fields.
5. `Draft`, so a header under construction is a different type from a header.
6. A round-trip corpus that proves each declared format.

## 2. Where the facts come from

Source: the `inet-cpp` branch `remotes/origin/topic/bz/serializertest`, head
`547ba383fe`. That branch is the right reference because it repaired the
serializers until they round-trip. Before it, a `FieldsChunk` built by
deserialization cached the original wire bytes and the serializer replayed the
cache, which hid every asymmetry between the reader and the writer. With the
cache cleared, the pcap corpus went from 1219 differing frames to 30.

[`tool/inventory_headers.jl`](../../tool/inventory_headers.jl) parses that ref
and writes
[`package/packet/doc/inventory.md`](../../package/packet/doc/inventory.md). The
generated file holds the per-family and the per-format tables; this plan states
only the headline figures, so the two cannot drift.

| fact | count |
| --- | --- |
| `.msg` files under `src/inet/` | 229 |
| classes that derive from `FieldsChunk` | 301 |
| … of them with a registered serializer | 206 |
| … of them with no wire format at all | 95 |
| `Register_Serializer` declarations | 214 |
| lines of hand-written serializer code | 12408 |

The 95 classes with no serializer are model-only: QUIC (23), EIGRP (13),
RSVP-TE (9), LDP (7), IPsec (3) and the abstract bases of the families that do
have one.

## 3. The inventory

### 3.1 A message file is not a wire format

`Ipv6Header.msg` declares its fields in the order `version, srcAddress,
destAddress, payloadLength, trafficClass, flowLabel, hopLimit, protocolId`.
`Ipv6HeaderSerializer` writes them in the order `version(4), trafficClass(8),
flowLabel(20), payloadLength(16), protocolId(8), hopLimit(8), srcAddress(128),
destAddress(128)`.

Write every declaration from the **standard**, and use the serializer to check
it. INET's field order, its class hierarchy and its abstract bases are its own
model, and this library does not inherit them. RFC 791 and IEEE 802.3 are the
source; INET is the second opinion.

### 3.2 The five tiers

Group the 206 formats that have a serializer by what their codec needs.

| tier | what the codec needs | formats |
| --- | --- | --- |
| T0 | fixed widths, network order, nothing else | 16 |
| T1 | plus padding, byte order or validation | 14 |
| T2 | plus a length that depends on the data | 10 |
| T3 | plus repetition: arrays or option lists | 89 |
| T4 | plus a variant: one format, many types | 77 |

### 3.3 Capability demand

| construct in the C++ codec | formats | section below |
| --- | --- | --- |
| a concrete-subtype cast or dispatch | 158 | §9.7 |
| a branch | 140 | §9.4, §9.8 |
| a quality mark | 116 | §9.4 |
| a cursor query | 105 | §9.5 |
| a sub-byte field | 86 | §9.1 |
| a loop | 85 | §9.6 |
| padding | 51 | §9.5 |
| a little-endian field | 23 | §9.2 |
| a raw byte range | 15 | §9.5 |

### 3.4 The four waves

**Wave 1 — the link layer and the protocol elements, about 30 formats.** The
Ethernet family, the 802.1 tag headers, `Ieee8022LlcHeader`,
`Ieee8022SnapHeader`, `PppHeader`, `PppTrailer`, `MplsHeader`, the
`protocolelement/` headers, `GenericPhyHeader`, `ApskPhyHeader`,
`ShortcutMacHeader`, `AckingMacHeader`, `ApplicationPacket`.

**Wave 2 — the internet core, about 55 formats.** IPv4 with options, IPv6 with
its six extension headers, UDP, TCP with options, ARP, the ICMP family, the
ICMPv6 family and the IGMP family.

**Wave 3 — the wireless and bridged link layers, about 80 formats.** IEEE
802.11 (36), the 802.11 PHY headers (21), 802.15.4, CSMA/CA, B-MAC, X-MAC,
LMAC, gPTP, the 802.1D BPDUs and MRP (17).

**Wave 4 — the routing and application protocols, about 100 formats.** OSPFv2
and OSPFv3, BGP, PIM, AODV, DYMO, RIP, EIGRP, LDP, RSVP-TE, DSDV, GPSR, DHCP,
SCTP, RTP and RTCP, MIPv6, QUIC.

## 4. The design

### 4.1 Three concerns, three places

- **What a value is** — the field's type. `Port`, `Ipv4Address`, `EtherType`,
  `Checksum16`, `U13`. How it prints follows from this and is never declared: a
  checksum reads as hex because it is a checksum.
- **What the layout is** — the struct, in field order. Width comes from the
  value type.
- **What the codec computes and checks** — `@header`, which emits the same
  struct plus a small table beside it.

Byte order is a property of the protocol, not of a field. IP and Ethernet are
network order throughout, so it is the default and never written. IEEE 802.11
is little-endian throughout, so its headers state it once.

### 4.2 The rule that divides the type from the macro

**The type carries what is a value. The macro carries what is an expression
over sibling fields.**

| in the type | in the macro |
| --- | --- |
| meaning and width — `Port`, `U13`, `Ipv6Address` | `derive`, `check` |
| structural kind — `Bytes`, `Rest`, `Repeated`, `Options`, `Optional`, an embedded header | `length`, `count`, `until`, `when` |
| | the defaults |

A `Bytes` field is a byte run whatever its length, so the kind is in the type;
how long it is this time is an expression, so it is in the macro. No function
type ever reaches a type parameter.

### 4.3 The value types

```julia
struct U{N, T <: Unsigned} <: Unsigned
    value::T
end

for n in 1:64
    @eval const $(Symbol(:U, n)) = U{$n, $(n <= 8 ? UInt8 : n <= 16 ? UInt16 :
                                            n <= 32 ? UInt32 : UInt64)}
end
```

`U4`, `U13` and `U20` read beside `UInt8` and store the smallest unsigned that
holds the width. A single-bit flag is a plain `Bool`; there is no `Bit` type,
because `Bool` already measures one bit. `I{N,T}` mirrors `U{N,T}` and
sign-extends from the declared width.

`U4` is checked once, at construction, and never again. `U4(16)` raises an
`InexactError`. The design this replaces accepted any `UInt8` in a 4-bit field
and wrote the low four bits, so a version of 16 went onto the wire as 0.

An IPv4 header costs about 28 bytes in memory against 20 on the wire, and stays
`isbits`, so a vector of them allocates once.

The named types carry meaning: `Port`, `Checksum16`, `MacAddress`,
`Ipv4Address`, `Ipv6Address`, `EtherTypeOrLength`, `IpProtocol`. Each is a
value type of its own, so a header cannot take a port where it wants a length,
and one text form serves the REPL, the tests, the packet diagram and the
editor.

### 4.4 What a value type must answer

Three methods, and the last two have a default:

```julia
measure_field(::Type{T})::Int                       # the width in bits
write_field(io::BitWriter, ::Type{T}, value, width::Int, order::Symbol)
read_field(io::BitReader, ::Type{T}, width::Int, order::Symbol)::T
```

A type of 64 bits or fewer may answer `encode_field` and `decode_field`
instead, and inherit the pair above.

### 4.5 The generic codec

`encode_header` and `decode_header` recurse over `fieldtypes(H)`, which unrolls
at compile time. There is one implementation, in ordinary Julia, that a
debugger can step through. `describe_layout` reads the same tuple, so the codec
and the description cannot disagree — they are one thing.

A header written by hand and a header written through `@header` are the same
type with the same methods. A format may start as a bare struct and grow a
check later without any caller noticing.

### 4.6 A header is total; a draft is not

No field is `Union{T, Nothing}`. A finished header is a value that is true
about a packet, and a maybe on every field would cost the union tag, lose
`isbits`, and be paid at every call site that reads it.

A field is omitted, not set to nothing, and the declaration says which may be
omitted: a field with a default is optional, a field without one is required.
The fields a model fills in later are the lengths and the checksums, and those
carry a default of zero.

For genuine incremental construction there is a second type:

```julia
draft = start_draft(Ipv4Header)
set_field!(draft, :source, "10.0.0.1")
is_set(draft, :protocol)          # false
ip = build_header(draft)          # errors on a required field still unset
```

`Draft{H}` is mutable, its fields are `Union{T, Nothing}`, and it is derived
generically from `fieldnames(H)`. A hole is a state of the thing that builds a
header, never a state of a header.

## 5. The naming rule

**A function name starts with a verb.** This plan applies the rule to every
name it introduces and to every name it rewrites.

| old | new |
| --- | --- |
| `field_width` | `measure_field` |
| `field_encode` / `field_decode` | `encode_field` / `decode_field` |
| `field_write` / `field_read` | `write_field` / `read_field` |
| `field_base` | gone — the value type prints itself |
| `field_text` | `format_field` |
| `field_bits` | `encode_field` |
| `field_value` | `get_field` |
| `header_layout` | `describe_layout` |
| `build_header_layout` | gone — `describe_layout` is generic |
| `to_bytes` / `from_bytes` | `encode_header` / `decode_header` |
| `with_field` | `set_field` |
| `internet_checksum` | `compute_internet_checksum` |
| `ones_complement_checksum` | `compute_ones_complement` |
| `sign_extend` | `extend_sign` |
| `pad_bits` | `measure_padding` |
| `serialize` / `deserialize` | keep — both are verbs |

New names, all verb-first: `start_draft`, `set_field!`, `is_set`,
`build_header`, `list_variants`, `matches_variant`, `select_variant`,
`list_options`, `find_option_type`, `ends_option_list`, `classify_display`,
`measure_header`, `measure_payload`.

**Out of scope, and inconsistent.** The chunk and packet API keeps its nouns —
`chunk_length`, `quality`, `peek`, `slice`, `sequence`,
`minimum_chunk_length`. Those are not part of this redesign, and renaming them
reaches every package. Raise it as a change of its own.

## 6. UDP — RFC 768

No expressions and two defaults, so `@header` carries the defaults alone.

```julia
@header UdpHeader begin
    source_port      :: Port
    destination_port :: Port
    length           :: U16        = 8
    checksum         :: Checksum16 = 0
end
```

`length` counts the header and the data together, and `checksum` covers a
pseudo-header built from the IP addresses. Neither is visible from the header,
so the UDP module sets both — which is what INET does, and what makes a capture
round-trip byte for byte.

## 7. IPv4 — RFC 791

The only one of the three with expressions.

```julia
@header Ipv4Header begin
    version         :: U4          = 4     check(version == 4)
    ihl             :: U4          = 5     derive(cld(measure_header(h), 32))
    dscp            :: U6          = 0
    ecn             :: U2          = 0
    total_length    :: U16
    identification  :: U16         = 0
    reserved        :: Bool        = false
    dont_fragment   :: Bool        = false
    more_fragments  :: Bool        = false
    fragment_offset :: U13         = 0
    time_to_live    :: U8          = 64
    protocol        :: IpProtocol
    header_checksum :: Checksum16  = 0     derive(checksum_mode == CHECKSUM_COMPUTED ?
                                                  compute_internet_checksum(h) :
                                                  header_checksum)
    checksum_mode   :: Model{ChecksumMode} = CHECKSUM_DECLARED
    source          :: Ipv4Address
    destination     :: Ipv4Address
    options         :: Options{Ipv4Option} until(offset == Bytes(4) * ihl)
    @check ihl >= 5
end
```

Three decisions, taken and confirmed:

- The three flag bits are three `Bool` fields, because RFC 791 §3.1 names them
  one at a time rather than as a 3-bit number.
- `dscp` and `ecn` follow RFC 2474 and RFC 3168, not RFC 791's `Type of
  Service`.
- `total_length` has no derive. It counts the payload, which the header cannot
  see, so the IP module sets it. `header_checksum` does have one, because
  RFC 791 defines it over the header alone.

## 8. Ethernet MAC — IEEE 802.3

No expressions and no defaults, so no macro.

```julia
struct EthernetMacHeader
    destination    :: MacAddress
    source         :: MacAddress
    type_or_length :: EtherTypeOrLength
end
```

Clause 3.2.6 makes the third field two readings of one field: a value up to
1500 is a length, 1536 and above is an EtherType. INET splits it into two chunk
classes; this keeps one field, and `EtherTypeOrLength` answers `is_length` and
`is_type`.

The frame check sequence is a chunk of its own, because 802.3 puts it after the
data and the MAC header does not contain it.

## 9. One example for each case

### 9.1 A sub-byte width

```julia
    version :: U4
    ihl     :: U4
```

### 9.2 Byte order

The 802.11 Duration field. The header states the order once, not each field.

```julia
@header Ieee80211MacHeader byte_order = :le begin
    …
end
```

### 9.3 A signed field, a wide field, a field that is not a number

`Ieee80211MacHeader`'s `short AID = -1`, an IPv6 address, a gPTP correction.

```julia
    aid                  :: I12          = -1
    source               :: Ipv6Address
    correction_field     :: ClockTime
    source_port_identity :: PortIdentity
```

### 9.4 A derive, a check, and quality

```julia
    version :: U4 = 4  check(version == 4)
    ihl     :: U4 = 5  derive(cld(measure_header(h), 32))
```

A derive computes on write and keeps what arrived on read, so a foreign
sender's disagreement stays visible. A check marks on read and throws on write:
a packet that arrived malformed is data, and a header the model built wrong is
a bug. A failed read check returns the header in a `MarkedFields` envelope, and
`peek` refuses it until the caller passes `incorrect = true`.

### 9.5 A byte tail, padding, and the cursor

```julia
    body :: Bytes  length(Bytes(count))
    tail :: Rest
    @pad to Bytes(4) fill 0x00
```

`Rest` must be the last field. Inside an expression, `offset` is where the
codec is and `remaining` is what the window has left. `remaining` exists on the
read side alone, because a writer has no window to have a remainder of.

A header with any of these is variable-length: `chunk_length(h)` answers,
`is_fixed_length(H)` is false, and `chunk_length(H)` raises an error naming
`minimum_chunk_length` instead.

### 9.6 A vector

The IGMPv3 source list.

```julia
    number_of_sources :: U16                    derive(count_sources(h))
    source_list       :: Repeated{Ipv4Address}  count(number_of_sources)
```

### 9.7 A variant

ICMP. Two small methods, ordinary Julia, no registry and no macro.

```julia
struct IcmpEchoRequest
    base            :: IcmpHeader
    identifier      :: U16
    sequence_number :: U16
end

list_variants(::Type{IcmpHeader}) = (IcmpEchoRequest, IcmpEchoReply, IcmpPtb)
matches_variant(::Type{IcmpEchoRequest}, base) = base.type == ICMP_ECHO_REQUEST
```

`select_variant` is generic: it walks `list_variants` and takes the first that
matches. With no match the base type comes back, marked misrepresented, so an
unknown subtype still re-serializes byte for byte.

The base header is an **embedded field**, not a supertype. Julia has no struct
inheritance and does not need one — the five-level 802.11 chain is four levels
of embedding, and `getproperty` forwards through it.

### 9.8 A conditional field

The 802.11 fourth address, present only when both distribution-system bits are
set. The value type becomes `Union{MacAddress, Nothing}`.

```julia
    address4 :: Optional{MacAddress}  when(from_ds && to_ds)
```

### 9.9 A list of type-length-value options

TCP options — the shape that also covers IPv4, IPv6, DHCP, SCTP, MIPv6 and BGP.
It is the largest gap in INET itself: `SERIALIZER_REMAINING_GAPS.md` names four
families that lose bytes for want of it.

```julia
abstract type TcpOption end

struct TcpOptionMaxSegmentSize <: TcpOption
    kind             :: Constant{U8, TCPOPTION_MAXIMUM_SEGMENT_SIZE}
    length           :: Constant{U8, 0x04}
    max_segment_size :: U16
end

list_options(::Type{TcpOption})           = (TcpOptionEnd, TcpOptionNop, …)
find_option_type(::Type{TcpOption}, code) = …     # falls back to the raw member
ends_option_list(::Type{TcpOption}, code) = code == TCPOPTION_END_OF_OPTION_LIST
```

An option the library does not know becomes a raw member that keeps its code,
its length and its bytes, so the list round-trips in the order the sender used.
That is the property INET's DHCP, SCTP and MIPv6 models lack.

The generic loop must stop when the reader passes the end of the window, and
mark the header incorrect. The C++ branch fixed exactly that bug twice, in the
IPv6 TLV reader and in the BGP length reader. Write it once, in the codec, and
no declaration can get it wrong.

### 9.10 A wire-only and a model-only field

```julia
    signature     :: Constant{U8, 0x4E}
    checksum_mode :: Model{ChecksumMode} = CHECKSUM_DECLARED
```

`Constant` is a zero-size singleton, so it is a struct field that stores
nothing. It is on the wire; a `Model` field is in the struct and never travels.

## 10. How a reflective view shows a header

A view that recurses on `fieldnames` would gain a level for every field, so a
value type answers `classify_display`:

- `:scalar` — `U4`, `Bool`, `Checksum16`. Never opened; the inside says
  nothing.
- `:openable` — `Ipv4Address`, `MacAddress`, `EtherTypeOrLength`. Shown as its
  text and opened on request, because the parts are real.
- `:composite` — an embedded header or an options list. The default, so an
  ordinary struct is unaffected.

The type also gives the editor what it could not derive before: the edit range
of a `U4` is 0 to 15, a `Bool` is a checkbox, an `IpProtocol` is a menu, and a
`Constant` field is not editable at all.

The packet diagram is unaffected: it reads `describe_layout`, never
`fieldnames`.

## 11. What survives the redesign

The branch `headers` holds four landed commits with 2054 passing assertions.

**Keep.** `BitIO.jl` — byte order, byte runs, padding, the cursor.
`Checksum.jl` — the mode, RFC 1071, the functional field update. The quality
path through `peek`, including the second gate on what the deserializer said.
`tool/inventory_headers.jl` and the generated inventory. Most of the assertions
in `phase10_header_language.jl`: they test behaviour, not syntax.

**Replace.** `Header.jl` — the macro no longer emits a codec. `FieldTypes.jl` —
`field_base` goes, the value types arrive, the names change.
`HeaderLayout.jl` — `describe_layout` becomes generic. The four files in
`protocol/`.

**Rewrite first.** `protocol/Ipv6.jl` landed against the old syntax. It is the
first header to convert, because it exercises a wide field, a check and a
sub-byte field at once.

## 12. The phases

Each phase ends with a green test and a commit. The command is
`julia --project=package/packet/test -e 'using InetPacketTest; test_packet()'`.

| phase | delivers | gate |
| --- | --- | --- |
| 0 ✅ | the inventory tool and its generated inventory | the inventory reproduces §2 |
| 1 ◐ | the value types, and the generic codec over `fieldtypes` | `EthernetMacHeader` is a plain struct that round-trips |
| 2 | `@header`: defaults, `derive`, `check` | `Ipv4Header` without options round-trips; a version of 5 marks incorrect |
| 3 | `Draft`, `start_draft`, `build_header` | a required field left unset fails at `build_header`, not on the wire |
| 4 | variable length: `Bytes`, `Rest`, `@pad` | a byte tail round-trips and `peek` finds it |
| 5 | `Repeated` | an IGMPv3 report round-trips |
| 6 | `Options` and the TLV family | IPv4, TCP and IPv6 options round-trip in order, with an unknown code preserved |
| 7 | variants and embedding | an ICMP echo request decodes from an `IcmpHeader` window |
| 8 | the round-trip corpus, Wave 1 and Wave 2 | green over about 85 formats |
| 9 | Wave 3 and Wave 4 | green over the inventory |
| 10 | the protocol dispatch table and a pcap reader | optional; only if a capture must be read |

Phases 1 to 7 are the language. Phases 8 and 9 are the inventory. Do not start
Phase 8 before Phase 7 is green: a header declared against a language that then
changes is a header written twice.

**Phase 1 is part done.** `InetPacket` is green at 1918 assertions: the value
types, the generic codec and the five rewritten wire formats all work, and
`EthernetMacHeader` is a plain struct that round-trips. What remains is the
rename downstream. The field names followed the standards — `dst` became
`destination`, `src_address` became `source`, `ttl` became `time_to_live` — and
three places still read the old ones:

- `package/linklayer/main/t1s/MacFsm.jl` reads `hdr.dst`. That file is
  generated, so the change belongs in `tool/generate_mac_fsm.jl`.
- `package/linklayer/test/` builds frames through the old names.
- `package/inet/test/packetdiagram.jl` and its golden figure name
  `src_address`; the figure has to be re-recorded.

Finish that before Phase 2.

## 13. How to test

1. **The round-trip corpus.** For each declared header, build an instance with
   distinct, byte-asymmetric values and check
   `encode_header(decode_header(H, bytes)) == bytes`, and that the length
   agrees. This is the C++ `serializer_chunk_roundtrip` test, and it catches an
   asymmetry between the reader and the writer — the defect class the whole C++
   branch is about. It is cheaper here, because `describe_layout` gives the
   field list for free.
2. **Golden vectors.** One hand-written byte string per family, from the RFC or
   from the branch's `tests/unit/pcap/` corpus, with the field values it must
   produce. This catches a layout that is self-consistent and wrong.
3. **Layout assertions.** The total width and the offset of two or three named
   fields per header. Cheap, and it fails with a readable message.

## 14. Decisions

| question | the position |
| --- | --- |
| what a declaration follows | the standard — RFC, IEEE. INET is the second opinion, not the source |
| where display lives | in the value type, never in a declaration |
| where byte order lives | on the header, not on a field |
| what a derive receives | the header alone. A value the header cannot see is set by the model |
| whether a checksum is computed | no. `CHECKSUM_DECLARED` stays the default, as in INET |
| whether a field may be `nothing` | no. A field is omitted, and `Draft` holds a genuine hole |
| how a header is updated | `set_field`, returning a new header. Headers stay immutable |
| inheritance | replaced by embedding |
| what `@header` is for | defaults and expressions. It never emits a codec, and the struct alone is a working header |
| whether to keep a byte cache | no. Prove the round trip instead — the cache is what hid the defect the C++ branch spent 60 commits finding |
| how much of the inventory to port | all 206 formats that have a serializer, over four waves |

## 15. Open

- **The editor's leaf rule.** Whether `projectured-julia`'s generic object
  projection already has a rule to hook `classify_display` into. A prerequisite
  for the view, not for the codec.

## 16. Out of scope

- **The 95 model-only classes.** No wire format exists to port.
- **IPsec ESP.** The trailer sits inside the ciphertext, so it cannot
  round-trip from a capture without the keys.
- **`Ieee802154MacHeader`.** INET's model is a placeholder with a hard-coded
  frame control field. Declare the real 802.15.4 format or declare nothing.
- **The 802.11 block-ack request.** INET models it in a non-standard 38-byte
  layout. Follow the standard's 20 bytes and record the difference.
- **Renaming the chunk and packet API.** `chunk_length`, `quality`, `peek` and
  `slice` keep their nouns; changing them reaches every package.
- **The C++ compatibility path.** Nothing here reads or writes an INET C++
  chunk.
