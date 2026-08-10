# The protocol header inventory, and the language it needs

INET defines its wire formats twice: a `.msg` file declares the field model, and
a hand-written `*Serializer.cc` declares the bit layout. The two can drift, and
they do. `@header` in `inet-julia` fuses them: one declaration gives the struct,
the codec and the layout descriptor, so drift is impossible.

This plan does two things. First, it takes the inventory of every wire format
INET declares as a `FieldsChunk`, and it says which ones `@header` can already
express. Second, it names every capability that is missing, groups the missing
capabilities into seven categories, and designs each one.

Status: **IN PROGRESS**. Phase 0 is done. §7 marks each phase as it lands.

## 1. What the plan delivers

1. A machine-built inventory of every `FieldsChunk` in INET, with its wire
   format, its serializer and the capabilities its codec needs.
2. A design for the missing `@header` capabilities, in seven categories.
3. An implementation order, from the capability that the most formats need to
   the capability that the fewest need.
4. A round-trip test corpus that proves each declared header, in the same way
   the C++ branch proves its serializers.

## 2. Where the facts come from

Source: the `inet-cpp` branch `remotes/origin/topic/bz/serializertest`, head
`547ba383fe`, merge base `b52bc21a34`. That branch is the right reference
because it repaired the serializers until they round-trip. Before it, a
`FieldsChunk` built by deserialization cached the original wire bytes and the
serializer replayed the cache, which hid every asymmetry between the reader and
the writer. With the cache cleared, the pcap corpus went from 1219 differing
frames to 30. The branch also records what is still broken, in
`tests/unit/SERIALIZER_REMAINING_GAPS.md`.

Method: parse the 231 `.msg` files for the class graph, walk the graph down from
`FieldsChunk`, and read the 69 `*Serializer.cc` files for the bit layout and the
control flow of each codec.

[`tool/inventory_headers.jl`](../../tool/inventory_headers.jl) does that parse
and writes [`package/packet/doc/inventory.md`](../../package/packet/doc/inventory.md).
The generated file holds the per-family and the per-format tables; this plan
states only the headline figures, so the two cannot drift.

| fact | count |
| --- | --- |
| `.msg` files under `src/inet/` | 229 |
| classes that derive from `FieldsChunk` | 301 |
| … of them with a registered serializer | 206 |
| … of them with no wire format at all | 95 |
| `Register_Serializer` declarations | 214 |
| serializer classes that carry them | 95 |
| lines of hand-written serializer code | 12408 |

The generator reads `src/inet/` alone. A doc snippet and a unit-test fixture
each declare a `TcpHeader` and a `UdpHeader` of their own, so a parse that reads
them too cannot say which declaration it kept.

The 95 classes with no serializer are model-only: QUIC (23), EIGRP (13),
RSVP-TE (9), LDP (7), IPsec (3) and the abstract bases of the families that do
have one. They state a field model that no code turns into bytes.

## 3. The inventory

### 3.1 What a `.msg` file does not say

The `.msg` file is **not** the wire format. `Ipv6Header` declares its fields in
the order `version, srcAddress, destAddress, payloadLength, trafficClass,
flowLabel, hopLimit, protocolId`, but `Ipv6HeaderSerializer` writes them in the
order `version(4), trafficClass(8), flowLabel(20), payloadLength(16),
protocolId(8), hopLimit(8), srcAddress(128), destAddress(128)`.

This is the single most important fact for the port. The inventory must join
each `.msg` class to its serializer, and the `@header` declaration must be
written from the **serializer**. A port that reads the `.msg` files alone
produces headers that are the wrong shape.

The `.msg` file still carries three things the serializer does not:

- the field names and the model types;
- the sub-byte widths, as `@bit(N)`. The branch added 32 of these to
  `FieldsChunk` classes so that its round-trip test would stop overflowing them;
- the fixed `chunkLength`, declared by 135 of the 301 classes.

### 3.2 The five tiers

Group the 206 classes that have a serializer by what their codec needs. The tier
is a property of the serializer class, so a family that shares one codec shares
one tier. The generated inventory lists the tier of every format and the tier
mix of every family.

| tier | what the codec needs | classes |
| --- | --- | --- |
| T0 | fixed widths, big-endian, nothing else | 16 |
| T1 | plus padding, byte order or validation | 14 |
| T2 | plus a length that depends on the data | 10 |
| T3 | plus repetition: arrays or option lists | 89 |
| T4 | plus a variant: one wire format, many concrete types | 77 |

`@header` today covers **T0 only**, and only when every field is 64 bits or
narrower and unsigned.

### 3.3 Capability demand

How many of the 206 classes need each construct. A class needs a construct when
the serializer that serves it uses that construct.

| construct in the C++ codec | classes | category below |
| --- | --- | --- |
| a concrete-subtype cast or dispatch | 158 | E2 |
| a branch (`if`) | 140 | B3, E3 |
| a quality mark (`markIncorrect`, …) | 116 | B3 |
| a cursor query (`getPosition`, `getRemainingLength`) | 105 | C1, C4 |
| a sub-byte field | 86 | have it |
| a loop | 85 | D1, D2 |
| padding (`writeByteRepeatedly`) | 51 | C3 |
| a call to a shared codec helper | 41 | D2, F1 |
| a little-endian field | 23 | A2 |
| a raw byte range | 15 | C2 |

The 23 little-endian classes are the whole of IEEE 802.11 plus
`Ieee802154MacHeader`. The 15 raw-byte classes are the option-carrying headers:
IPv4, TCP, SCTP, DHCP, CFM and the eight 802.11 management frames.

The four largest families are `linklayer/ieee80211` (36 formats, 31 with a
codec), `transportlayer/quic` (23, none), `physicallayer/wireless` (21, 11) and
`networklayer/icmpv6` (19, 18). The generated inventory has the other 63
families.

### 3.4 The four waves

Port the inventory in four waves. Each wave is a set of formats a user of
`inet-julia` can actually run.

**Wave 1 — the link layer and the protocol elements (about 30 formats).** The
Ethernet family (`EthernetMacAddressFields`, `EthernetTypeOrLengthField`,
`EthernetPadding`, `EthernetControlFrameBase`, `EthernetPauseFrame`), the 802.1
tag headers (`Ieee8021qTagTpidHeader`, `Ieee8021qTagEpdHeader`, and the `ae` and
`r` pairs), `Ieee8022LlcHeader`, `Ieee8022SnapHeader`, `Ieee802EpdHeader`,
`PppHeader`, `PppTrailer`, `MplsHeader`, and the `protocolelement/` headers
(`SequenceNumberHeader`, `FragmentNumberHeader`, `AcknowledgeHeader`,
`HopLimitHeader`, `ChecksumHeader`, `SubpacketLengthHeader`, `ProtocolHeader`,
the three `Destination*Header`), plus `GenericPhyHeader`, `ApskPhyHeader`,
`ShortcutMacHeader`, `ShortcutPhyHeader`, `AckingMacHeader` and
`ApplicationPacket`. Mostly T0 to T2.

**Wave 2 — the internet core (about 55 formats).** `Ipv4Header` with its
options, `Ipv6Header` with its six extension headers, `UdpHeader`, `TcpHeader`
with its options, `TransportPseudoHeader`, `ArpPacket`, the `IcmpHeader` family
(4), the `Icmpv6Header` family (19) and the `IgmpMessage` family (10). This wave
needs every category below except F.

**Wave 3 — the wireless and the bridged link layers (about 80 formats).** IEEE
802.11 (36), the 802.11 PHY headers (21), `Ieee802154MacHeader`, CSMA/CA (4),
B-MAC (3), X-MAC (3), LMAC (3), gPTP (7), the 802.1D BPDUs (3) and MRP (17).

**Wave 4 — the routing and the application protocols (about 100 formats).**
OSPFv2 and OSPFv3 (12), BGP (4), PIM (8), AODV (5), DYMO (2), RIP (1), EIGRP
(13), LDP (7), RSVP-TE (9), DSDV, GPSR, DHCP, SCTP, RTP and RTCP (7), MIPv6 (9),
QUIC (23).

## 4. The missing capabilities

Seven categories. Each one states what INET does, how many formats need it, and
the design. Appendix A gives one worked example for each case, with the real
INET code beside the declaration that replaces it.

### Category A — the value of one field

#### A1. Sub-byte widths — present

`name :: UInt8 | 4` works today. 86 classes need it. Nothing to do.

#### A2. Byte order

`BitWriter` and `BitReader` are most-significant-bit first, which is network
order. IEEE 802.11 writes its Duration, Sequence Control and BA Control fields
little-endian; 23 classes need it.

**Design.** A fourth pipe segment, a symbol: `| le` or `| be`, with `be` the
default. The macro passes the order to the field codec. A little-endian field
must be a whole number of bytes; the macro rejects it otherwise, at expansion
time.

```julia
duration :: UInt16 | 16 | le
```

#### A3. Signed integers

`field_decode` is defined for `Unsigned`, `Bool` and `Base.Enum`. The `.msg`
files declare 97 `int`, 25 `short`, 6 `long` and 8 sized signed fields.

**Design.** Add `field_width`, `field_encode` and `field_decode` for `Signed`.
`field_decode` sign-extends from the declared width, which is why the width must
reach the decoder — see A4.

#### A4. A field wider than 64 bits

`field_encode(::Type{T}, value)::UInt64` is the whole protocol. An
`Ipv6Address` is 128 bits and cannot pass through it. 12 fields are
`Ipv6Address` and 20 are `L3Address`, which is 32 or 128 bits by variant.

**Design.** This is the one breaking change in the plan. Replace the encode and
decode pair with a write and read pair that own the stream:

```julia
field_write(io::BitWriter, ::Type{T}, value, width::Int, order::Symbol)
field_read(io::BitReader,  ::Type{T}, width::Int, order::Symbol)::T
```

Keep `field_encode` and `field_decode` as the default implementation of the new
pair, so every existing field type keeps working with no change:

```julia
field_write(io, ::Type{T}, v, w, order) = write_bits!(io, field_encode(T, v), w, order)
field_read(io, ::Type{T}, w, order)     = field_decode(T, read_bits!(io, w, order))
```

`Ipv6Address` then defines the new pair directly and writes two 64-bit halves.

The layout descriptor has the same 64-bit limit in `field_bits`. Add
`field_text(::Type{T}, value, base)::String`, which the descriptor calls when
the width is above 64. `field_bits` keeps its meaning for narrow fields, which
is what the packet diagram uses.

#### A5. A field that is not a number

The `.msg` files declare 11 `string`, 14 `simtime_t`, 3 `clocktime_t`, 11 `B`
and 3 `b` length fields, 25 `VariableLengthInteger` (the QUIC variable-length
integer), 6 `SequenceNumberCyclic`, 2 `BitVector` and 2 `double`.

**Design.** Every one of these is a field type that answers the A4 protocol.
Declare them in `FieldTypes.jl` as the plan's Phase 1 work, one struct and one
method set each. A `VariableLengthInteger` has a width that its own first two
bits decide, so its `field_read` ignores the declared width and its
`field_width` returns the minimum. That makes the header variable-length, which
is category C.

#### A6. A field on the wire that is not a field of the struct, and the reverse

INET writes literal zeros for reserved bits and reads them back into nothing.
`Ieee80211MpduSubframeHeader` writes a constant `0x4E` delimiter signature.
INET also holds model state that never reaches the wire: `ChecksumMode` (17
fields) and `FcsMode` say whether a checksum is declared, computed or disabled.

**Design.** Two rules, both about width.

- `reserved :: UInt8 | 4 | const(0x00)` — a **wire-only** line. It takes width
  on the wire, the macro emits no struct field, and the reader discards the
  bits. `const` names the value the writer emits.
- `checksum_mode :: ChecksumMode | 0 = CHECKSUM_DECLARED` — a **model-only**
  field. A zero width means the field is in the struct and not on the wire. One
  rule covers `ChecksumMode`, `FcsMode` and every other piece of model state.

### Category B — a value the codec computes

#### B1. A length field

`ihl`, `data_offset`, `total_length`, `payloadLength` and the DHCP and OSPF
length fields all restate a length the codec already knows. INET computes them
in the module, asserts them in the serializer, and gets them wrong when a model
forgets.

**Design.** A `derive` clause. On write, the codec computes the value and
ignores the struct field. On read, the codec reads the wire value and stores it,
because a foreign sender may disagree and the model must keep what arrived.

```julia
ihl :: UInt8 | 4 | derive(cld(header_bits(h), 32)) = IPV4_MIN_IHL
```

`h` names the header under construction. Inside a `derive`, the fields declared
above the line are bound as locals, so a length may refer to them.

Pair `derive` with `check` (B3) when the model must notice a disagreement:

```julia
total_length :: UInt16 | derive(bytes(chunk_length(h))) | check(total_length >= 20)
```

#### B2. A checksum and a frame check sequence

49 references to a checksum across the serializers. INET's rule is a mode:
`CHECKSUM_DECLARED` writes the stored value, `CHECKSUM_COMPUTED` requires the
model to have computed it, `CHECKSUM_DISABLED` writes zero. `inet-julia` today
declares and never computes, which is INET's default.

**Design.** A `checksum` clause names the algorithm and, through the algorithm,
what the algorithm covers.

```julia
header_checksum :: UInt16 | 16 | hex | checksum(internet_checksum) = 0x0000
```

The clause is a `derive` with two differences. It obeys the `checksum_mode`
model-only field of A6, and the algorithm receives the bytes already written
before the field plus the bytes written after it. That needs the cursor of C4.
A transport checksum also needs a pseudo-header, which the caller supplies:
`checksum(internet_checksum, over = pseudo_header(h))`.

Keep `CHECKSUM_DECLARED` the default. A model that never computes a checksum
still round-trips a capture byte for byte, which is the property the test corpus
measures.

#### B3. Validation that marks quality, not one that throws

`@header` emits `quality(h) = Q_COMPLETE` for every header, always. The C++
serializers call `markIncorrect` 77 times and `markImproperlyRepresented` 5
times, and throw 153 times. 116 classes need a quality mark.

The `Chunk` module already has the three flags and the `peek` gate that reads
them. The macro simply never sets them.

**Design.** A `check` clause. On read, a failed check marks the header
incorrect and the header still comes back, because a packet that arrived
malformed is data, not a program error. On write, a failed check throws, because
a header the model built wrong is a bug.

```julia
version :: UInt8 | 4 | check(version == 4) = IPV4_VERSION
```

Add a header-level form for a check that spans fields:

```julia
@check ihl >= IPV4_MIN_IHL
```

The generated `quality` method stops being a constant. It reads a hidden
model-only field that the reader fills, which A6 already allows.

### Category C — a length that depends on the data

#### C1. An instance-dependent `chunk_length`

The macro emits `chunk_length(::Type{H})` and `chunk_length(::H)` as the same
constant sum. 105 classes have a codec that asks the stream where it is, which
means their length is not a constant.

This is the deepest change in the plan, because `peek` depends on the type-level
method. [`PeekFields.jl`](../../package/packet/main/PeekFields.jl) calls
`chunk_length(T)` six times: to default the window, to detect a prefix peek, to
mark the source incomplete, and twice to refuse a window of the wrong size.

**Design.** Split the two methods.

- `chunk_length(h::H)` stays, and becomes a sum of the constant widths plus one
  call for each variable part.
- `chunk_length(::Type{H})` is replaced by two type-level questions:
  `minimum_chunk_length(H)`, always known, and `is_fixed_length(H)`, a `Bool`
  the macro computes at expansion time.

`peek(c, T)` then takes two paths. For a fixed-length header, the path of today,
unchanged. For a variable-length header with no explicit `length`, give the
reader the whole remaining window, deserialize, and take the length from the
value that comes back: the reader knows its own final position. The prefix-peek
rule becomes: a window shorter than `minimum_chunk_length(T)` is incomplete; a
window that the deserializer over-runs is incomplete.

Every fixed-length header keeps the behaviour it has today. Phase 3 must prove
that with the existing tests before it adds a variable-length header.

#### C2. A tail of raw bytes

15 classes read or write a raw byte range: the option-carrying headers and the
802.11 management frames, which keep their trailing information elements as
bytes.

**Design.** A field whose type is `Vector{UInt8}` and whose length comes from a
clause:

```julia
body :: Vector{UInt8} | length(Bytes(total_length) - header_length(h))
elements :: Vector{UInt8} | rest              # to the end of the window
```

`rest` is only legal as the last line of a header, and it makes the header
variable-length.

#### C3. Padding and alignment

51 classes pad. INET writes `writeByteRepeatedly(value, n)` and reads
`readByteRepeatedly`.

**Design.** A wire-only line, in the position where the padding sits:

```julia
@pad to Bytes(4) fill 0x00
```

`to` aligns to a boundary measured from the start of the header. A second form,
`@pad Bytes(n)`, writes a fixed count. Padding takes width and is not a struct
field, so it follows the A6 wire-only rule.

#### C4. A cursor

B2, C2 and C3 all need the codec to ask how many bits it has written or read so
far. `BitWriter` has `bit_count` and `BitReader` has `bit_pos`, so the state is
there.

**Design.** Bind two locals inside every generated codec: `offset`, the bits
consumed or produced since the start of **this** header, and `remaining`, the
bits left in the window. Both are `BitLength`. A clause may name either. This
is what makes `until(offset == Bytes(4) * ihl)` readable in D2.

### Category D — repetition

#### D1. A vector of values

85 classes loop. The simple half of that is a vector of a fixed element type
with a count another field carries: the IPv4 record-route addresses, the IGMPv3
group records, the OSPF LSA headers, the RIP entries.

**Design.**

```julia
addresses :: Vector{Ipv4Address} | count(number_of_addresses)
records   :: Vector{GroupRecord} | count(number_of_records)
```

The element type may be any field type of category A, or another header — see
F1. The field makes the header variable-length.

#### D2. A list of type-length-value options

This is the largest single gap, and it is the gap the C++ branch itself has not
closed. `SERIALIZER_REMAINING_GAPS.md` names four families as "L" effort and
says all four need the same fix: an ordered TLV list with typed members and a
raw catch-all. The four are the MIPv6 mobility options (9 differing frames), the
SCTP INIT parameters (9), the DHCP options (4) and the IPv6 hop-by-hop and
destination options. IPv4 options, TCP options, BGP path attributes, the 802.11
information elements, the MRP TLVs and the OSPF LSAs are the same shape.

A fixed struct of known options cannot preserve the order the sender used and
cannot hold a code it does not know. Both losses break a byte round trip. Build
the Julia model as an ordered list from the start, and this whole class of gap
never opens.

**Design.** Three parts.

**Part one — the family.** One macro declares the common prefix, the catch-all
and the stop rule:

```julia
@tlv_family Ipv4Option begin
    code   :: UInt8
    length :: UInt8 | when(code > 1)     # END and NOP carry no length octet
    @raw   Ipv4OptionRaw                 # any code with no member type
    @stop  code == IPOPTION_END_OF_OPTIONS
end
```

The macro emits an abstract type `Ipv4Option`, a registry from the code to the
member type, and a `deserialize(::Type{Ipv4Option}, io)` that reads the prefix,
looks the code up, and falls back to the raw member. The raw member keeps the
code, the length and the bytes, so an unknown option survives a round trip
unchanged.

**Part two — the members.** A member is a header that extends the family and
names its code:

```julia
@header Ipv4OptionRouterAlert <: Ipv4Option | code(IPOPTION_ROUTER_ALERT) begin
    alert :: UInt16
end
```

A member registers itself when it is declared. A member in another package
therefore works with no change to the family, which is what `Register_Serializer`
gives INET.

**Part three — the list in a header.**

```julia
options :: Options{Ipv4Option} | until(offset == Bytes(4) * ihl)
```

`until` is the stop rule for the list; `@stop` inside the family is the stop rule
for the option that ends a list early. Both are needed: IPv4 stops at the header
length, and a `END_OF_OPTIONS` inside that length stops it sooner.

The list must also refuse to loop forever. The C++ branch fixed exactly that bug
twice, in the IPv6 TLV reader and in the BGP length reader. The generated loop
must stop when the reader passes the end of the window, and mark the header
incorrect. Write that once, in the macro, and no declaration can get it wrong.

### Category E — one wire format, many concrete types

#### E1. A header that extends another header

More than a third of the 300 classes extend another chunk class, and the child's
wire format is the parent's fields followed by its own. `Ieee80211DataHeader`
extends `Ieee80211DataOrMgmtHeader` extends `Ieee80211TwoAddressHeader` extends
`Ieee80211OneAddressHeader` extends `Ieee80211MacHeader`.

**Design.** `@header X <: Y` copies `Y`'s field list in front of `X`'s own, at
expansion time. The struct is flat; Julia has no inheritance of fields and the
plan does not fake one. `Y` must be declared before `X`, which the `include`
order already guarantees. The layout descriptor of `X` therefore lists the
inherited fields too, and the packet diagram needs no change.

#### E2. A variant

158 classes are served by a codec that reads a discriminator and then casts to a
concrete type. `IcmpHeader` reads `type` and returns an `IcmpEchoRequest`.
`GptpBase` reads `messageType` and returns one of seven. `MobilityHeader` reads
`mobilityHeaderType` and returns one of eight.

**Design.** A member declares the condition that selects it:

```julia
@header IcmpEchoRequest <: IcmpHeader | when(type == ICMP_ECHO_REQUEST) begin
    identifier      :: UInt16
    sequence_number :: UInt16
end
```

The member registers itself against its base, as a TLV member does. The base's
generated `deserialize` reads the base fields, then walks its member registry
and takes the first member whose condition holds. With no match, the base type
comes back, marked misrepresented — which is exactly what INET's
`markImproperlyRepresented` means, and what the round-trip test needs so an
unknown subtype still re-serializes byte for byte.

`serialize` needs no dispatch: the concrete type has its own method.

This design also removes the `Register_Serializer(Base, XSerializer)` pattern,
where one C++ serializer class holds a `switch` over twenty chunk classes. Each
Julia member owns its own codec.

#### E3. A conditional field

415 `if` statements sit in the serializers. Many are E2 dispatch, but many are a
field that is present only under a condition: the 802.11 fourth address, present
only when both the To-DS and the From-DS bits are set; the 802.11 QoS control,
present only for a QoS subtype; the SRv6 fields of the IPv6 routing header.

**Design.** A `when` clause on a field line:

```julia
address4 :: MacAddress | when(to_ds && from_ds)
```

The struct field type becomes `Union{MacAddress, Nothing}`, and `nothing` means
the field was absent. The layout descriptor must therefore carry an offset that
depends on the instance — see §6.

### Category F — composition

#### F1. A field whose type is another header

`EthernetMacHeader` is, in INET, `EthernetMacAddressFields` followed by
`EthernetTypeOrLengthField`. An OSPF Link State Update carries a list of LSAs,
each an LSA header followed by a body. 53 classes call a shared codec helper for
this reason.

**Design.** A field whose declared type is a `Fields` subtype is embedded: its
codec runs in place, its width is its own `chunk_length`, and the layout
descriptor splices its fields in with their offsets shifted. No new syntax; the
macro recognises the type.

`Vector{H}` where `H <: Fields` composes F1 with D1, which is what an LSA list
needs.

#### F2. A header that owns a payload — out of scope

INET's `@packetData` and the owned-pointer fields let a chunk hold another
chunk. `Packet` in `inet-julia` already models that, with `Sequence` and the
push and pop verbs. A header does not need it. One `.msg` field uses
`@packetData` and four use `@owned`; handle those four by hand.

### Category G — around the language

#### G1. A protocol dispatch table

`peek(pk, Ipv4Header)` needs the caller to name the type. To read a capture, or
to write a general dissector, the code must go from `EtherType(0x0800)` to
`Ipv4Header` without being told. INET has `ProtocolDissector` and
`ProtocolGroup` for this.

**Design.** Deferred to a phase of its own, and only if a pcap reader is wanted.
The registry is small: a `Dict` from a protocol and a code to a header type,
filled beside each `@header`. Name it here so the inventory phases do not invent
a private one.

#### G2. A round-trip corpus

The C++ branch's central lesson is that a byte cache hides asymmetry between the
reader and the writer. `inet-julia` has no such cache, and `packet.md` lists
`SerializedFields{H}` as unshipped. **Do not ship it.** Prove the round trip
instead.

**Design.** A test that walks every declared header type, builds an instance with
byte-asymmetric field values, and checks `serialize` then `deserialize` then
`serialize` gives the same bytes and the same length. That is the C++
`serializer_chunk_roundtrip` test, and it is cheaper in Julia because the field
list is reflectable through `header_layout`.

#### G3. The layout descriptor under a variable length

`build_header_layout` computes a fixed offset for each field, once, at
declaration time. A conditional field (E3), a list (D2) or a byte tail (C2)
makes the offset depend on the instance.

**Design.** Keep the constant `HeaderLayout` as the description of the type: it
answers "what fields does an `Ipv4Header` have". Add
`header_layout(h::Fields)`, which returns the layout of one **instance**, with
real offsets, real widths and the members a list actually holds. The packet
diagram switches to the instance form. The type form keeps its meaning for the
fixed prefix, which is what a reader needs before any bytes arrive.

## 5. The syntax, complete

One line for each field. Segments are separated by `|`. A segment is a width, a
display base, a byte order, or a clause call. A trailing `= expr` is the default.

```
name :: Type | width | base | order | clause(expr) … = default
```

| clause | category | meaning |
| --- | --- | --- |
| `const(v)` | A6 | wire-only; write `v`, discard on read |
| `derive(expr)` | B1 | write the computed value, read and keep the wire value |
| `checksum(f)` | B2 | a `derive` that obeys `checksum_mode` |
| `check(expr)` | B3 | mark incorrect on read, throw on write |
| `length(expr)` | C2 | the length of a byte field |
| `rest` | C2 | to the end of the window; last line only |
| `count(expr)` | D1 | the element count of a vector field |
| `until(expr)` | D2 | the stop rule of an option list |
| `when(expr)` | E3 | the field is present only when `expr` holds |
| `code(v)` | D2 | the code that selects a TLV member |

Header-level lines start with `@`:

| line | category | meaning |
| --- | --- | --- |
| `@check expr` | B3 | a check across fields |
| `@pad to Bytes(n) fill v` | C3 | padding, in the position it is written |

Two macros beside `@header`:

| macro | category | meaning |
| --- | --- | --- |
| `@header X <: Y \| when(expr)` | E1, E2 | inherit `Y`'s fields; register as a variant |
| `@tlv_family X begin … end` | D2 | an option family with a registry and a catch-all |

Inside a clause, three names are bound: `h`, the header; every field declared
above the line; and `offset` and `remaining`, the cursor of C4.

Worked example, the full IPv4 header:

```julia
@header Ipv4Header begin
    version         :: UInt8  | 4 | check(version == 4)               = IPV4_VERSION
    ihl             :: UInt8  | 4 | derive(cld(header_bits(h), 32))   = IPV4_MIN_IHL
    dscp            :: UInt8  | 6                                     = 0x00
    ecn             :: UInt8  | 2                                     = 0x00
    total_length    :: UInt16
    identification  :: UInt16 | 16 | hex                              = 0x0000
    flags           :: UInt8  | 3                                     = 0x00
    frag_offset     :: UInt16 | 13 | dec                              = 0x0000
    ttl             :: UInt8                                          = IPV4_DEFAULT_TTL
    protocol        :: IpProtocol
    header_checksum :: UInt16 | 16 | hex | checksum(internet_checksum) = 0x0000
    src_address     :: Ipv4Address
    dst_address     :: Ipv4Address
    options         :: Options{Ipv4Option} | until(offset == Bytes(4) * ihl)
    @pad to Bytes(4) fill IPOPTION_END_OF_OPTIONS
    checksum_mode   :: ChecksumMode | 0                               = CHECKSUM_DECLARED
    @check ihl >= IPV4_MIN_IHL
end
```

### An alternative the user may prefer

The clauses ride on `|` because `|` is already the segment separator and Julia
parses the chain with no trouble. The cost is that a long line reads as a chain
of pipes. The alternative is one clause for each line, under the field:

```julia
    ihl :: UInt8 | 4 = IPV4_MIN_IHL
        @derive cld(header_bits(h), 32)
```

That reads better and parses as easily, but it separates a field from its own
facts and it makes the block two-dimensional. The plan takes the pipe form.
Change it in Phase 1 if the first ten headers read badly; after Phase 1 the cost
of a change grows with every declaration.

## 6. What changes outside the macro

| file | change | category |
| --- | --- | --- |
| [`FieldTypes.jl`](../../package/packet/main/FieldTypes.jl) | the `field_write` and `field_read` pair; signed integers; the new field types | A3, A4, A5 |
| [`BitIO.jl`](../../package/packet/main/BitIO.jl) | a byte order argument; a byte-range read and write; a repeated write | A2, C2, C3 |
| [`HeaderLayout.jl`](../../package/packet/main/HeaderLayout.jl) | an instance layout beside the type layout; `field_text` for a wide field | G3, A4 |
| [`PeekFields.jl`](../../package/packet/main/PeekFields.jl) | the variable-length path; `minimum_chunk_length` | C1 |
| [`Chunk.jl`](../../package/packet/main/Chunk.jl) | nothing; the three quality flags already exist | B3 |
| [`Header.jl`](../../package/packet/main/Header.jl) | every category | — |

None of these files is sealed. [`SEALING.md`](../../SEALING.md) lists all four
`packet/main` files as `⬜`.

`Header.jl` grows from 194 lines to an estimated 700. Split it when it passes
about 400 lines: `Header.jl` keeps the parse and the emit, and a new
`HeaderClause.jl` holds one function for each clause. The split is a rule of the
architecture, not a preference — a leaf file states one thing.

## 7. The phases

Each phase ends with a green test and a commit. The test command is
`julia --project=package/packet/test -e 'using InetPacketTest; test_packet()'`.

| phase | delivers | gate |
| --- | --- | --- |
| 0 ✅ | `tool/inventory_headers.jl`, and the generated inventory it writes | the inventory reproduces the numbers of §2 |
| 1 | A2 to A6: the value protocol, byte order, signed, wide, model-only, wire-only | the five headers of today round-trip unchanged; `Ipv6Header` is declarable |
| 2 | B1 to B3: `derive`, `checksum`, `check`, real `quality` | a malformed IPv4 version marks incorrect and does not throw |
| 3 | C1 to C4: instance length, byte tail, padding, cursor | every fixed header behaves as before; `peek` finds a variable header |
| 4 | D1: vector fields | an IGMPv3 report round-trips |
| 5 | D2: TLV families | IPv4 options, TCP options and IPv6 options round-trip, in order, with an unknown code preserved |
| 6 | E1 to E3: inheritance, variants, conditions | an ICMP echo request deserializes from an `IcmpHeader` window |
| 7 | F1: embedded headers | `EthernetMacHeader` declares as two embedded parts and gives the same bytes |
| 8 | G2, and Wave 1 and Wave 2 of §3.4 | the round-trip corpus is green over about 85 formats |
| 9 | Wave 3 and Wave 4 | the corpus is green over the inventory |
| 10 | G1: the protocol dispatch table, and a pcap reader | optional; do it only if a capture must be read |

Phases 1 to 7 are the language. Phases 8 and 9 are the inventory. Do not start
Phase 8 before Phase 7 is green: a header declared against a language that then
changes is a header written twice.

## 8. How to test

Three levels, each cheaper than the one below it.

1. **The round-trip corpus (G2).** For each declared header, build an instance
   with distinct, byte-asymmetric values, then check
   `to_bytes(from_bytes(H, to_bytes(h))) == to_bytes(h)` and that the length
   agrees. This is the C++ `serializer_chunk_roundtrip` test, and it catches an
   asymmetry between the reader and the writer, which is the defect class the
   whole C++ branch is about.
2. **The golden vectors.** For each header, one hand-written byte string from
   the RFC or from a capture, and the field values it must produce. This catches
   a layout that is self-consistent and wrong, which the round trip cannot.
   Take the byte strings from the branch's `tests/unit/pcap/` corpus.
3. **The layout assertions.** For each header, assert the total width and the
   offset of two or three named fields. Cheap, and it fails with a readable
   message when a width is mistyped.

Level 2 is the only one that needs work for each header. Budget one golden
vector for each **family**, not for each class: a variant family shares its
prefix, so one vector for the base plus one for each member that adds fields.

## 9. Decisions to confirm

The plan takes a position on each of these. State a different one and the plan
changes.

| question | the plan's position |
| --- | --- |
| how much of the inventory to port | all 205 formats that have a serializer, over four waves; the 95 model-only classes are out of scope until a model needs them |
| where the declarations live | `package/packet/main/protocol/`, one file for each protocol, as today |
| whether to keep a byte cache | no. Prove the round trip instead. A cache hides the defect the C++ branch spent 60 commits finding |
| whether a check throws or marks | it marks on read and throws on write |
| whether a checksum is computed | no. `CHECKSUM_DECLARED` stays the default, as in INET |
| the clause syntax | pipe segments, with the sub-line form as the named alternative |
| what a variant returns with no match | the base type, marked misrepresented |
| whether `InetPacket` may name a protocol | yes, as today. A declaration is not behaviour, and the package still depends on nothing |

## 10. Out of scope

- **The 95 model-only classes.** QUIC, EIGRP, RSVP-TE, LDP and IPsec declare a
  field model that no C++ code serializes. There is no wire format to port.
- **IPsec ESP.** The trailer sits inside the ciphertext, so the format cannot
  round-trip from a capture without the keys. The C++ branch marks it
  impossible.
- **`Ieee802154MacHeader`.** INET's model is a three-field placeholder with a
  hard-coded frame control field, and the branch documents that it is not the
  on-the-wire format. Declare the real 802.15.4 format or declare nothing.
- **The 802.11 block-ack request.** INET models it in a non-standard 38-byte
  layout. The Julia declaration must follow the standard 20-byte format, which
  means it will not match INET's bytes. Record that as a deliberate difference.
- **The C++ compatibility path.** Nothing here reads or writes an INET C++
  chunk. That is the `Foreign` work named in
  [`packet.md`](../../package/packet/doc/packet.md).

## Appendix A — an example for each case

One case for each capability of §4. The first block is the real INET code, from
the branch of §2. The second block is the `@header` declaration that replaces
it. Every C++ snippet is quoted, not paraphrased.

### A1. Sub-byte widths — present

`Ipv4Header.msg` states the widths in the model, and the serializer packs them.

```cpp
// networklayer/ipv6/Ipv6HeaderSerializer.cc
stream.writeUint4(ipv6Header->getVersion());
stream.writeUint8(ipv6Header->getTrafficClass());
stream.writeNBitsOfUint64Be(ipv6Header->getFlowLabel(), 20);
```

```julia
version       :: UInt8  | 4
traffic_class :: UInt8  | 8
flow_label    :: UInt32 | 20
```

Works today. Nothing to do.

### A2. Byte order

IEEE 802.11 is little-endian. The Sequence Control field packs a 4-bit fragment
number and a 12-bit sequence number, then writes the pair little-endian.

```cpp
// linklayer/ieee80211/mac/Ieee80211MacHeaderSerializer.cc
uint16_t packSequenceControl(uint8_t fragmentNumber, uint16_t sequenceNumber)
{
    return (fragmentNumber & 0xF) | ((sequenceNumber & 0xFFF) << 4);
}
void writeSequenceControl(MemoryOutputStream& stream, uint8_t fragmentNumber, uint16_t sequenceNumber)
{
    stream.writeUint16Le(packSequenceControl(fragmentNumber, sequenceNumber));
}
```

```julia
sequence_control :: SequenceControl | 16 | le
```

`SequenceControl` is a field type of category A5 that holds the two numbers. The
`le` segment moves the byte swap out of the declaration.

### A3. Signed integers

`Ieee80211MacHeader` uses `-1` as "no association identifier".

```cpp
// linklayer/ieee80211/mac/Ieee80211Frame.msg
short AID = -1;          // "id" (Association ID) in the Duration/ID field (-1=no ID)
```

```julia
aid :: Int16 | 16 = Int16(-1)
```

`field_decode` sign-extends from the declared width, so a 12-bit signed field
also comes back correct.

### A4. A field wider than 64 bits

Two cases. An IPv6 address is 128 bits, and a gPTP port identity is 80.

```cpp
// networklayer/ipv6/Ipv6HeaderSerializer.cc
stream.writeIpv6Address(ipv6Header->getSrcAddress());
stream.writeIpv6Address(ipv6Header->getDestAddress());
```

```cpp
// linklayer/ieee8021as/GptpPacket.msg
PortIdentity sourcePortIdentity @bit(80);
```

```julia
src_address          :: Ipv6Address
dst_address          :: Ipv6Address
source_port_identity :: PortIdentity | 80
```

Neither fits in the `UInt64` that `field_encode` returns. Both work once
`Ipv6Address` and `PortIdentity` define `field_write` and `field_read`.

### A5. A field that is not a number

gPTP carries a 64-bit correction as a clock time, and DHCP carries two
NUL-padded strings.

```cpp
// linklayer/ieee8021as/GptpPacket.msg
clocktime_t correctionField @bit(64) = 0;
```

```cpp
// applications/dhcp/DhcpMessage.msg
string sname;   // optional server host name
string file;    // boot file name (unused in the simulation)
```

```julia
correction_field :: ClockTime | 64 = ClockTime(0)
sname            :: FixedString | 64 * 8
file             :: FixedString | 128 * 8
```

`ClockTime` and `FixedString` are field types, declared once in
`FieldTypes.jl`. A `FixedString` pads with NUL to its declared width.

### A6. A field on the wire that is not a field of the struct, and the reverse

Both halves appear in one header. `Ieee80211MacHeader` holds `MACArrive`, which
the MAC module uses and the wire never sees. `Ieee80211MpduSubframeHeader`
writes a constant delimiter signature that no field holds.

```cpp
// linklayer/ieee80211/mac/Ieee80211Frame.msg
simtime_t MACArrive;    // FIXME remove it, technical data, used inside of MAC module
```

```cpp
// linklayer/ieee80211/mac/Ieee80211MacHeaderSerializer.cc
stream.writeUint4(0);
stream.writeUint4(mpduSubframe->getLength() >> 8);
stream.writeUint8(mpduSubframe->getLength() & 0xFF);
stream.writeByte(0);
stream.writeByte(0x4E);
```

```julia
# model only: in the struct, not on the wire
mac_arrive :: SimTime | 0 = SimTime(0)

# wire only: on the wire, not in the struct
reserved  :: UInt8  | 4  | const(0x00)
length    :: UInt16 | 12
crc       :: UInt8  | 8  | const(0x00)
signature :: UInt8  | 8  | const(0x4E)
```

The C++ deserializer of this header carries a comment about a defect the
declaration cannot have: the old code read the high nibble, shifted it right by
8, and lost bits 8 to 11 of the length.

### B1. A length field

The TCP data offset counts 32-bit words of header. INET computes it in the
serializer and throws when the model disagrees.

```cpp
// transportlayer/tcp_common/TcpHeaderSerializer.cc
if (tcpHeader->getHeaderLength().get<B>() % 4 != 0)
    throw cRuntimeError("invalid Tcp header length=%s: must be dividable by 4 bytes", …);
tcp.th_offs = tcpHeader->getHeaderLength().get<B>() / 4;
…
ASSERT(tcpHeader->getHeaderLength() == TCP_MIN_HEADER_LENGTH + B(optionsLength));
```

```julia
data_offset :: UInt8 | 4 | derive(cld(header_bits(h), 32)) = TCP_MIN_DATA_OFFSET
```

The write path computes the value, so the assertion has nothing to catch. The
read path keeps what arrived, so a foreign sender's value is still visible.

### B2. A checksum and a frame check sequence

INET refuses to serialize when the mode says the value is not computed.

```cpp
// transportlayer/tcp_common/TcpHeaderSerializer.cc
if (tcpHeader->getChecksumMode() != CHECKSUM_COMPUTED)
    throw cRuntimeError("Cannot serialize Tcp header without a properly computed checksum");
tcp.th_sum = htons(tcpHeader->getChecksum());
```

```cpp
// linklayer/ethernet/common/EthernetMacHeaderSerializer.cc
if (ethernetFcs->getFcsMode() != FCS_COMPUTED)
    throw cRuntimeError("Cannot serialize Ethernet FCS without a properly computed FCS");
stream.writeUint32Be(ethernetFcs->getFcs());
```

```julia
checksum      :: UInt16 | 16 | hex | checksum(internet_checksum, over = pseudo_header(h)) = 0x0000
checksum_mode :: ChecksumMode | 0 = CHECKSUM_DECLARED
```

With the default mode the stored value goes out unchanged, which is what a
byte-exact round trip of a capture needs.

### B3. Validation that marks quality, not one that throws

```cpp
// networklayer/ipv6/Ipv6HeaderSerializer.cc
ipv6Header->setVersion(stream.readUint4());
if (ipv6Header->getVersion() != 6)
    ipv6Header->markIncorrect();
```

```julia
version :: UInt8 | 4 | check(version == 6) = IPV6_VERSION
```

A failed check marks the header incorrect on read and throws on write. The
`peek` gate of `Chunk.jl` already refuses an incorrect chunk unless the caller
passes `incorrect = true`.

### C1. An instance-dependent `chunk_length`

A TCP header is 20 bytes plus its options. `chunk_length(TcpHeader)` cannot be a
constant, and `peek` calls it six times.

```cpp
// transportlayer/tcp_common/TcpHeaderSerializer.cc
stream.writeBytes((uint8_t *)&tcp, TCP_MIN_HEADER_LENGTH);
unsigned short numOptions = tcpHeader->getHeaderOptionArraySize();
```

```julia
minimum_chunk_length(TcpHeader)   # Bytes(20), always known
is_fixed_length(TcpHeader)        # false
chunk_length(h::TcpHeader)        # Bytes(4) * h.data_offset
```

`peek(pk, TcpHeader)` with no `length` gives the reader the whole remaining
window and takes the length from the value that comes back.

### C2. A tail of raw bytes

An 802.11 management frame keeps its trailing information elements as bytes,
because INET does not model every element.

```cpp
// linklayer/ieee80211/mgmt/Ieee80211MgmtFrameSerializer.cc
// (the mgmt frames read the remaining bytes and keep them verbatim)
```

```cpp
// networklayer/ipv4/Ipv4HeaderSerializer.cc
B bufsize = stream.getRemainingLength();
```

```julia
elements :: Vector{UInt8} | rest
```

`rest` is legal only on the last line, and it makes the header
variable-length. Keep the bytes rather than drop them: an element this library
does not model still re-serializes byte for byte.

### C3. Padding and alignment

IPv4 pads the options to the header length; TCP pads them to a 4-byte boundary.

```cpp
// networklayer/ipv4/Ipv4HeaderSerializer.cc
auto writtenLength = B(stream.getLength() - startPosition);
if (writtenLength < headerLength)
    stream.writeByteRepeatedly(IPOPTION_END_OF_OPTIONS, (headerLength - writtenLength).get<B>());
```

```cpp
// transportlayer/tcp_common/TcpHeaderSerializer.cc
if (optionsLength % 4 != 0)
    stream.writeByteRepeatedly(0, 4 - optionsLength % 4);
```

```julia
@pad to Bytes(4) fill IPOPTION_END_OF_OPTIONS    # in the IPv4 declaration
@pad to Bytes(4) fill 0x00                       # in the TCP declaration
```

### C4. A cursor

Three of the snippets above ask the stream where it is. C3 needs
`stream.getLength() - startPosition`, C2 needs `getRemainingLength`, and D2
needs both.

```cpp
// networklayer/ipv6/Ipv6ExtensionHeaderSerializer.cc
b startPos = stream.getLength();
…
b written = stream.getLength() - startPos;
if (written < b(hdrLen))
    stream.writeByteRepeatedly(0, B(b(hdrLen) - written).get());
```

```julia
# `offset` and `remaining` are bound inside every clause
options :: Options{Ipv6Option} | until(offset == Bytes(8) * (header_ext_len + 1))
```

### D1. A vector of values

An IGMPv3 query carries a source count and then that many addresses.

```cpp
// networklayer/ipv4/IgmpHeaderSerializer.cc
uint16_t numOfSources = igmpv3Query->getSourceList().size();
stream.writeUint16Be(numOfSources);
for (uint16_t i = 0; i < numOfSources; ++i)
    stream.writeIpv4Address(igmpv3Query->getSourceList()[i]);
```

```julia
number_of_sources :: UInt16 | derive(Base.length(source_list))
source_list       :: Vector{Ipv4Address} | count(number_of_sources)
```

The deserializer of this header also has to set the length by hand
(`setChunkLength(B(12) + B(numOfSources * 4))`); the declaration computes it.

### D2. A list of type-length-value options

TCP options, the shape that also covers IPv4 options, IPv6 options, DHCP
options, SCTP parameters, MIPv6 mobility options and BGP path attributes.

```cpp
// transportlayer/tcp_common/TcpHeaderSerializer.cc
stream.writeByte(kind);
if (length > 1)
    stream.writeByte(length);
auto *opt = dynamic_cast<const TcpOptionUnknown *>(option);
if (opt) { … write the raw bytes … return; }
switch (kind) {
    case TCPOPTION_END_OF_OPTION_LIST: … break;
    case TCPOPTION_NO_OPERATION:       … break;
    case TCPOPTION_MAXIMUM_SEGMENT_SIZE: {
        auto *opt = check_and_cast<const TcpOptionMaxSegmentSize *>(option);
        ASSERT(length == 4);
        stream.writeUint16Be(opt->getMaxSegmentSize());
        break;
    }
    …
```

```julia
@tlv_family TcpOption begin
    kind   :: UInt8
    length :: UInt8 | when(kind > 1)      # EOL and NOP carry no length octet
    @raw   TcpOptionUnknown
    @stop  kind == TCPOPTION_END_OF_OPTION_LIST
end

@header TcpOptionMaxSegmentSize <: TcpOption | code(TCPOPTION_MAXIMUM_SEGMENT_SIZE) begin
    max_segment_size :: UInt16
end

# in TcpHeader
options :: Options{TcpOption} | until(offset == Bytes(4) * data_offset)
```

The `switch` disappears. An option this library does not know becomes a
`TcpOptionUnknown` that keeps its kind, its length and its bytes, so the list
round-trips in the order the sender used. That is the property INET's DHCP,
SCTP and MIPv6 models lack, and the reason those three still differ on the C++
branch.

### E1. A header that extends another header

Five levels of 802.11 header, each adding fields to the one below.

```cpp
// linklayer/ieee80211/mac/Ieee80211Frame.msg
class Ieee80211MacHeader extends FieldsChunk
{
    Ieee80211FrameType type;
    bool toDS; bool fromDS; bool moreFragments; bool retry;
    …
    MacAddress receiverAddress;    // aka address1 (RA)
}
class Ieee80211OneAddressHeader extends Ieee80211MacHeader { }
class Ieee80211TwoAddressHeader extends Ieee80211OneAddressHeader
{
    MacAddress transmitterAddress; // aka address2 (TA)
}
```

```julia
@header Ieee80211TwoAddressHeader <: Ieee80211OneAddressHeader begin
    transmitter_address :: MacAddress
end
```

The macro copies the base's field list in front at expansion time. The struct
stays flat, and `header_layout` lists the inherited fields with their offsets.

### E2. A variant

ICMP. The C++ codec reads three fields, switches on the type, and then copies
those three fields into the concrete header by hand, once for each case.

```cpp
// networklayer/ipv4/IcmpHeaderSerializer.cc
switch (type) {
    case ICMP_ECHO_REQUEST: {
        auto echoRq = makeShared<IcmpEchoRequest>();
        echoRq->setType(type);
        echoRq->setCode(icmpHeader->getCode());
        echoRq->setChksum(icmpHeader->getChksum());
        echoRq->setChecksumMode(CHECKSUM_COMPUTED);
        echoRq->setIdentifier(stream.readUint16Be());
        echoRq->setSeqNumber(stream.readUint16Be());
        icmpHeader = echoRq;
        break;
    }
    case ICMP_ECHO_REPLY: {
        …the same seven lines again…
    }
```

```julia
@header IcmpHeader begin
    type     :: IcmpType
    code     :: UInt8
    checksum :: UInt16 | 16 | hex | checksum(internet_checksum) = 0x0000
end

@header IcmpEchoRequest <: IcmpHeader | when(type == ICMP_ECHO_REQUEST) begin
    identifier      :: UInt16
    sequence_number :: UInt16
end

@header IcmpEchoReply <: IcmpHeader | when(type == ICMP_ECHO_REPLY) begin
    identifier      :: UInt16
    sequence_number :: UInt16
end
```

The base reads its own fields once and then walks its member registry. The
field copying has no place to live, so it cannot be forgotten — which is the
defect the branch fixed in commit `28a8970d9d`, "copy the action-frame fields
when deserializing a DELBA".

### E3. A conditional field

An 802.11 data frame carries a fourth address only when both distribution-system
bits are set, and a QoS control field only when bit 3 of the subtype is set.

```cpp
// linklayer/ieee80211/mac/Ieee80211MacHeaderSerializer.cc
if (dataHeader->getFromDS() && dataHeader->getToDS())
    stream.writeMacAddress(dataHeader->getAddress4());
if (macHeader->getSubType() & 0x08) {
    stream.writeUint4(dataHeader->getTid());
    stream.writeBit(dataHeader->getEosp());
    stream.writeUint2(dataHeader->getAckPolicy());
    …
```

```julia
address4    :: MacAddress | when(from_ds && to_ds)
tid         :: UInt8      | 4 | when(sub_type & 0x08 != 0)
eosp        :: Bool       | 1 | when(sub_type & 0x08 != 0)
ack_policy  :: AckPolicy  | 2 | when(sub_type & 0x08 != 0)
```

An absent field is `nothing`, so the struct field type is
`Union{MacAddress, Nothing}`. The End-of-Service-Period bit is one the branch had
to add (`eb939450ec`); a declaration that lists it cannot then forget to write
it.

### F1. A field whose type is another header

INET declares the Ethernet address pair and the type field as chunks of their
own, and then repeats their bytes inside the MAC header codec.

```cpp
// linklayer/ethernet/common/EthernetMacHeaderSerializer.cc
void EthernetMacAddressFieldsSerializer::serialize(…) {
    stream.writeMacAddress(header->getDest());
    stream.writeMacAddress(header->getSrc());
}
void EthernetTypeOrLengthFieldSerializer::serialize(…) {
    stream.writeUint16Be(header->getTypeOrLength());
}
void EthernetMacHeaderSerializer::serialize(…) {
    stream.writeMacAddress(ethernetMacHeader->getDest());   // the same three
    stream.writeMacAddress(ethernetMacHeader->getSrc());    // lines, written
    stream.writeUint16Be(ethernetMacHeader->getTypeOrLength()); // a second time
}
```

```julia
@header EthernetMacAddressFields begin
    dst :: MacAddress
    src :: MacAddress
end

@header EthernetMacHeader begin
    addresses      :: EthernetMacAddressFields
    type_or_length :: EthernetTypeOrLengthField
end
```

A field whose type is a `Fields` subtype runs that type's codec in place. The
layout descriptor splices the embedded fields in with their offsets shifted, so
the packet diagram still draws `dst`, `src` and `type_or_length`.

### F2. A header that owns a payload — out of scope

```cpp
// common/packet/Packet.msg
// @packetData / @owned fields let a chunk hold another chunk
```

```julia
pushfirst!(pk, ethernet_mac_header)
push!(pk, ethernet_fcs)
```

`Packet` already models this, with `Sequence` and the push and pop verbs. One
`.msg` field uses `@packetData` and four use `@owned`; handle those four by
hand.

### G1. A protocol dispatch table

INET goes from an EtherType to the next header type through a protocol group.

```cpp
// networklayer/ipv6/Ipv6Header.msg
virtual const Protocol *getProtocol() const override {
    return ProtocolGroup::getIpProtocolGroup()->findProtocol(getProtocolId());
}
```

```julia
register_next_header(EthernetMacHeader, ETHERTYPE_IPV4 => Ipv4Header)
register_next_header(Ipv4Header, IP_PROTOCOL_UDP => UdpHeader)
```

Deferred to Phase 10. `peek(pk, Ipv4Header)` needs no table; a pcap reader does.

### G2. A round-trip corpus

```cpp
// tests/unit/serializer_chunk_roundtrip.test
// Enumerates every registered chunk-serializer type, instantiates it, fills its
// flat scalar fields with distinct, byte-asymmetric values, and checks the byte
// round-trip (serialize -> deserialize -> serialize) and the length invariant.
```

```julia
for H in declared_headers()
    h  = fill_asymmetric(H)
    bs = to_bytes(h)
    @test to_bytes(from_bytes(H, bs)) == bs
    @test chunk_length(from_bytes(H, bs)) == chunk_length(h)
end
```

`declared_headers()` reads the registry that `@header` fills, and
`fill_asymmetric` reads `header_layout`. The C++ engine needs a descriptor API
and 32 new `@bit(N)` annotations to do the same job.

### G3. The layout descriptor under a variable length

`build_header_layout` computes one fixed offset for each field, at declaration
time. A conditional field, an option list or a byte tail breaks that.

```julia
header_layout(Ipv4Header)   # the TYPE: the fixed prefix, offsets 0…159
header_layout(h)            # the INSTANCE: the prefix, then the three options
                            # this datagram actually carries, at real offsets
```

The packet diagram switches to the instance form. The type form keeps its
meaning for a reader that must describe a header before any bytes arrive.
