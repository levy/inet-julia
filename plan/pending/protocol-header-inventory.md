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

Status: **IN PROGRESS**. Phases 0 to 7 are done, Waves 1 to 3 are in — IEEE 802.11 included — and Wave 4 has begun. 313 wire formats are declared and every one round-trips. The repository is green:
3129 passes with the seven pre-existing capture and runner errors and nothing
else. §12 marks each phase as it lands.

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

**Wave 2 is done — 65 formats.** IPv4 and IPv6, UDP, TCP, ARP, the ICMP family,
the IPv4 and TCP option lists, the six IPv6 extension headers with their TLV
option family, the ICMPv6 family with the neighbour discovery messages and their
option family, MLD version 1 and version 2, and the IGMP family with RGMP.

Three differences from INET, all because the standard is clearer than the code
and the user's rule is to follow the standard:

* **`Ipv6AuthenticationHeader`** — INET's is a stub that writes zero octets and
  carries a `// TODO`. This is RFC 4302 section 2, so it has an SPI, a sequence
  number and an integrity check value. Its length octet counts four-octet units
  minus two, which no other IPv6 extension header does.
* **`Ipv6EncapsulatingSecurityPayloadHeader`** — the same stub, and INET writes
  a next-header octet at the front. RFC 4303 section 2 puts no next header at
  the front of ESP at all: it travels in the trailer so that it is encrypted
  with the payload. This declares the eight octets the RFC draws.
* **MLD lives in the ICMPv6 family.** INET gives the four MLD types a
  serializer of their own and makes its ICMPv6 serializer throw on them. RFC
  2710 and RFC 3810 make them ICMPv6 messages, and one type octet is all a
  reader has, so they are members here like any other.

Two members of `Ipv6RoutingHeader` deserve a note. RFC 8200 section 4.4 gives
every routing header the same four octets and leaves the rest to the routing
type; type 0 was deprecated by RFC 5095 and type 2 belongs to Mobile IPv6, so
what this declares is RFC 8754's Segment Routing Header, which is also what
INET writes.

IPv4 and TCP are now variable-length, and `ihl` and `data_offset` derive from
the header's own width — so a datagram that carries options gets the right
value without anyone setting it. `has(pk, T)` and the packet-level `peek`
therefore ask `minimum_chunk_length` rather than `chunk_length`.

**Wave 3 — the wireless and bridged link layers, about 80 formats.** IEEE
802.11 (36), the 802.11 PHY headers (21), 802.15.4, CSMA/CA, B-MAC, X-MAC,
LMAC, gPTP, the 802.1D BPDUs and MRP (17).

**Wave 4 — the routing and application protocols, about 100 formats.** OSPFv2
and OSPFv3, BGP, PIM, AODV, DYMO, RIP, EIGRP, LDP, RSVP-TE, DSDV, GPSR, DHCP,
SCTP, RTP and RTCP, MIPv6, QUIC.

### 3.5 What Wave 2 added to the language

Three gaps showed up only once a real format needed them.

1. **A repeated element that decides its own length.** `Repeated{T}` measured a
   list as `count × measure_field(T)`, which no IGMPv3 group record can answer:
   each record carries a source list of its own. Such a list now fills its
   window and reads elements until it is full, and the count field beside it
   becomes a `derive`. The loop refuses an element that reads no bits, for the
   reason the option loop does.
2. **An option list with no window.** The neighbour discovery options run to
   the end of the ICMPv6 message and nothing inside the message says where they
   stop — the IPv6 payload length does. A list with no `until` clause therefore
   takes what is left, as `Rest` does.
3. **A variant that the length tells apart.** RFC 3376 section 7.1 makes an
   IGMP query version 1, 2 or 3 by its length and its second octet, and RFC
   3810 section 8.1 does the same for MLD. `matches_variant` gained a
   three-argument form that also receives how many bits the message has. Every
   member that does not need it defines the two-argument form, and the
   three-argument form calls it.

One refactor came out of the same work. `measure_read` had four methods that
dispatched on the field's type and one that dispatched on the header and the
field name. Neither kind is more specific than the other, so a field that had
both a clause and a type-specialised method would have been an ambiguous call —
latent until a list with no clause arrived. There is now one `measure_read`,
which calls `measure_default(T, offset, remaining)`. The type answers there,
where a clause cannot collide with it.

Two edges are recorded rather than fixed:

* **A derived field keeps its stored value.** `decode(encode(h))` does not
  equal `h` when `h` was built with a stale derived field, because the writer
  computes the derived value and the struct keeps what it was given. The bytes
  round-trip, which is what the corpus proves, and the tests compare bytes.
* **A count beside a window-filling list is not checked on read.** An IGMPv3
  report that says two records and carries three reads back as three. A `check`
  clause cannot express it: the corpus builds a header whose fields are all
  distinct, so a checked count would fail the check rather than the round trip.

### 3.6 What Wave 3 landed, and what IEEE 802.11 still needs

**Done — 67 formats.**

* The five headers that state their own length: `AckingMacHeader`,
  `ShortcutMacHeader`, `GenericPhyHeader`, `ShortcutPhyHeader` and
  `ApskPhyHeader`. The plan called this a language gap and it is not one. The
  `until` clause gives the offset a field ends at, which is what a filler needs,
  and the length derives from the octets beside it.
* The two IEEE 802.1D bridge protocol data units.
* The IEEE 802.15.4 MAC header, which is the first little-endian header.
* B-MAC, X-MAC and the CSMA/CA MAC — eleven frames.
* The seven gPTP messages of IEEE 802.1AS.
* The seventeen MRP records of IEC 62439-2.

Two facts came out of the work.

1. **A header whose only variable field is padding is not variable.** Padding is
   as wide as the distance from its offset to a boundary, and that offset is
   known unless a field above it is variable. `is_fixed_length` and
   `minimum_chunk_length` now walk with the offset. Before the fix,
   `chunk_length(MrpOption)` refused an eight-octet record and
   `minimum_chunk_length` reported six.
2. **INET keeps two record types in one class where the layout is shared.** MRP
   Link Down and Link Up, and the two MRP test sub-records, are each one class
   with two codes. A record type is a record type, so each is two members here.

**Left — IEEE 802.11, 36 MAC formats and 21 physical-layer formats.** It needs
one thing the language does not have, and the plan should say so plainly.

Section 4.1 states that byte order is a property of the protocol and belongs to
the header. IEEE 802.11 disproves it. `Ieee80211MacHeaderSerializer` makes ten
little-endian writes and thirteen big-endian ones **in the same header**: the
duration field and the sequence control field are little-endian, and the
addresses and the block acknowledgement fields are not. A per-header
`byte_order` cannot say that.

The fix that fits the design is a value type, not a clause. Byte order stays out
of the macro, because it is not an expression over sibling fields; it becomes
part of what a value is. IEEE 802.11 names both fields, so both get a name:
`Ieee80211Duration` for the duration and identifier field, and a sequence
control type for the fragment and sequence numbers. Each answers `write_field`
and `read_field` with its own order, and the header keeps one declared order for
everything else.

Two more things IEEE 802.11 will need, both already in the language:

* the fourth address, present only when both distribution-system bits are set,
  and the quality-of-service control, present only for a QoS subtype — that is
  the `when` clause and `Optional`;
* the action frame whose category this library does not model, which keeps its
  body verbatim — that is a raw member, as an unknown option is.

One discrepancy is already known and stays out of scope: INET's
`Ieee80211BlockAckReq` is 38 octets where IEEE 802.11 draws 20.

### 3.7 Wave 4, and the one shape BGP still needs

**Done — 67 formats.** RIP, the eight AODV control packets, the DSDV hello, the
eighteen PIM formats, and BGP's header, KEEPALIVE, OPEN and NOTIFICATION with
its optional parameters, the seven RTP and RTCP formats, DHCP with its options, the three application payloads, and the nine Mobile IPv6 messages.

Three findings, none of which needed a language change:

1. **A list with no window keeps turning up.** RFC 2453 clause 3.6 says a RIP
   message's entry count is what the datagram length leaves, and a PIM Hello's
   options run to the end of the message. Both are the shape the neighbour
   discovery options introduced.
2. **An address form the standard defines once should be a header.** RFC 7761
   clause 4.9.1 gives PIM three encoded address forms and eight messages reuse
   them. Declaring each once, as gPTP's timestamp and port identity already
   are, replaces twenty-four repeated fields with three headers.
3. **INET reverses a list where the standard does not.**
   `AodvControlPacketsSerializer` writes the unreachable node list backwards.
   RFC 3561 clause 5.3 draws it in order, and a reader that reverses on the way
   in but not on the way out turns the list around at every hop.

**Left — about 30 formats.** The IEEE 802.11 management bodies and the
twenty-one physical-layer formats of Wave 3, and SCTP's seven extension chunks.

**BGP's UPDATE is the one still to declare, and carefully.** The header, the
KEEPALIVE, the OPEN and the NOTIFICATION are in. UPDATE has two shapes nothing
else in the inventory has.

* **A prefix whose length field counts bits.** A withdrawn route is a length
  octet and then that many BITS of prefix, padded up to a whole octet. The
  language already says it — `length(Bytes(cld(prefix_length, 8)))` — but a
  declaration that writes four octets where the standard writes two is a
  declaration that reads no capture, so it wants a byte-string test.
* **A field whose own length field changes width.** A path attribute's flags
  octet carries an Extended Length bit, and that bit decides whether the
  attribute's length is one octet or two. Every other length field in the
  inventory has a fixed width.

  The language can say it with what it has:

  ```julia
      extended_length :: Bool = false
      ...
      length_high :: Optional{U8} = nothing
          when(extended_length)
      length_low  :: U8 = 0
  ```

  A `when` clause already decides presence on both sides, so the two octets
  appear exactly when the bit says. What that costs is a reader helper —
  `measure_attribute_length` — because the value is then split across two
  fields. The alternative is a value type that carries its own width, and a
  width that another field decides is not what a value is. The `when` clause is
  the right tool; it just needs writing down before someone reaches for a
  second `length` clause.

### 3.8 OSPFv2 — a variant family inside a variant family

**Done — 19 formats.** The five packets with their shared twenty-four octets,
the five LSA bodies with their shared twenty, and the small headers they repeat:
the router link, its TOS entry, the summary TOS entry, the external metric, the
link state request entry, and the options octet.

This is the first format where a variant family is the ELEMENT TYPE of a list. A
link state update carries many LSAs and each one says its own type and its own
length, so `Repeated{Ospfv2Lsa}` is the field. It needed nothing new in the
codec: `is_fixed_length` already answers `false` for an abstract type, so a
family is a variable-width field, and `deserialize` already routes an abstract
type to `deserialize_variant`. One line went into `fill_asymmetric`, so the
round-trip corpus fills a family with the first member it lists.

Two decisions came out of it.

1. **A family used as an element type needs a member that claims everything, not
   a fallback.** `deserialize_variant` wraps the fallback in `mark_misrepresented`,
   and a `MarkedFields` is not a member of the family — so it cannot go into the
   list's vector. `Ospfv2RawLsa` is therefore an ordinary member that matches any
   type, which is what `BgpParameterRaw` and `Ipv6NdOptionRaw` already are in an
   option family. The mark is for a family at the top of a chunk, where the
   packet family still uses it.
2. **A length in a shared header can be derived after all.** `BgpCommon` says a
   shared header cannot measure the member that embeds it, and that is true of
   the header alone. The member can: it derives the whole base with the measured
   length written in, using `set_field`. An LSA needs it — its body ends where
   `lsa_length` says, so a length a model set by hand would make the LSA
   unreadable. The OSPF packet uses it too. **BGP's `total_length` should get the
   same treatment**; it is the one length left in the inventory that a model can
   still set wrong.

Three departures from INET, all in the file that departs:

* `Ospfv2PacketSerializer` reads an LSA of an unknown type, marks the packet
  incorrect and reads **no body**. The stream then sits in the middle of that
  LSA, so every later LSA in the same update is garbage. `Ospfv2RawLsa` keeps
  the octets and leaves the stream where the next LSA starts.
* INET throws on LS type 7. RFC 3101 clause 2.2 gives the NSSA external LSA the
  same body as the type 5 AS external LSA, so one member reads both.
* INET serialises the router LSA's TOS entry and the summary LSA's TOS entry
  from one `Ospfv2TosData` struct and writes them differently — appendix A.4.2
  puts a zero octet and a sixteen-bit metric where appendix A.4.4 puts a
  twenty-four-bit one. They are two headers here.

One reading note: INET writes the options octet through `serializeOspfOptions`,
a helper, so a compact read of the serializer shows `helloInterval` next to
`routerPriority` and hides the octet between them. Version 3 does the same.

### 3.9 OSPFv3 — a field as wide as another field says

**Done — 22 formats.** The five packets, the eight LSA bodies, and the small
headers they repeat: the router link, the two address prefixes, the prefix
options and the twenty-four-bit options.

It needed nothing new. The one shape version 2 does not have is the address
prefix of RFC 5340 appendix A.4.1, which is written as a whole number of
thirty-two-bit words — so a prefix of sixty-five bits takes twelve octets and a
prefix of nothing takes none. A `length` clause already says it:

```julia
    address :: Octets = UInt8[]
        length(Bytes(measure_prefix_bytes(prefix_length)))
```

**What that revealed: a `length` clause whose field is not derivable needs a
`check` on BOTH fields.** Every other length field in the inventory is derived
from the data beside it, so the two cannot disagree. A prefix length cannot be:
a prefix of thirty-three bits and one of sixty-four both take two words, so the
octets do not say which it was. The pair is therefore a model invariant, and a
`check` states it — on both fields, because either one can be the wrong one.
The round-trip corpus pins a checked field to its declaration, so the pair it
builds is consistent by construction.

Two departures from INET:

* **INET does not keep the LS type.** `encodeLsType` computes the scope bits
  from the function code on the way out and drops the U bit entirely; on the way
  in it puts the whole high octet into a field it calls the options and keeps
  only the low octet as the type. An LSA with the U bit set does not survive its
  serializer, and neither does one whose scope is not the default for its code.
  RFC 5340 appendix A.4.2.1 makes the sixteen bits one field with three parts,
  and that is what is declared.
* **INET serialises five of the nine function codes and throws on the rest.**
  The inter-area router LSA (4), the AS external LSA (5) and the NSSA LSA (7)
  are declared. The AS external LSA is also the inventory's best use of the
  `when` clause: three of its fields are there only when a bit says so, and one
  of the three is conditional on a value rather than a flag.

### 3.10 BGP's UPDATE — the two shapes §3.7 named

**Done — 14 formats.** The UPDATE message, the prefix, the path attribute header
and its nine members.

Both shapes §3.7 predicted worked, and the language needed no change.

* **A prefix whose length counts bits.** `length(Bytes(measure_prefix_octets(
  prefix_length)))` says it, and a /24 writes three octets where a naive
  declaration would write four. RFC 4760 clauses 3 and 4 use the same shape for
  an IPv6 prefix, so one header serves both; INET declares two structs that emit
  the same octets.
* **A length field whose own width changes.** The `Optional{U8}` high octet with
  a `when(extended_length)` clause is exactly right, and `measure_attribute_length`
  reads the pair as one number.

**One thing §3.7 did not foresee: the high octet must default to zero, not to
absent.** A member derives its whole base to write the measured length, and the
derive calls `measure_header`, which walks the STORED fields — so the stored base
must already satisfy its own `when` clause. A base built with the extended bit
set and no high octet fails that walk before the derive can fix it. Defaulting
the octet to zero makes every base a caller can build self-consistent, and a
reader still gives the octet back absent when the bit was clear, because then it
was never on the wire.

**`total_length` is now derived on all four messages**, which §3.8 named as the
last length a model could still set wrong. `BgpCommon`'s docstring said a shared
header cannot measure the member that embeds it; that is true of the header and
not of the member, and the member is where the derive goes.

The VoIP stream packet is declared with them. It is the last of INET's own
formats and the only one whose FIELD LIST depends on what it carries: a voice
packet has a data length and a silence packet does not. The `when` clause reads
the type octet beside it, and the same rule the BGP high octet found applies —
the field defaults to zero rather than to absent, because the header derives its
own length and the derive walks the stored fields.

### 3.12 SCTP — where a length and a width are different numbers

**Done — 34 formats.** The packet, the fifteen chunks of RFC 4960 and RFC 3758,
the nine parameters and the six error causes.

SCTP is type-length-value at three levels: a packet is a list of chunks, a chunk
may carry a list of parameters, and a chunk may carry a list of error causes.
Two things separate it from every other option list in the inventory, and the
language already said both.

* **The code is sixteen bits.** A parameter and an error cause each name
  themselves with two octets, which is what `measure_option_code` is for — it
  had never been overridden before. A chunk names itself with one octet and its
  flags mean something different in each chunk, so a chunk is a variant and not
  an option.
* **A length and a width are different numbers.** RFC 4960 clause 3.2.1 says a
  parameter's length field does NOT count the padding that takes the parameter
  up to a multiple of four. Every other length in the inventory is the header's
  own width. Here the length derives from the fields it covers and a `Pad`
  field after them reaches the boundary, so the two numbers differ by up to
  three: a Supported Address Types parameter with one family says six and
  occupies eight.

That second point is why `measure_header(h) ÷ 8` is not the universal derive.
The right question is "how many octets does this length field cover", and only
sometimes is the answer "all of them".

**What is not declared.** INET carries seven chunk types beyond RFC 4960 and RFC
3758: AUTH (RFC 4895), ASCONF and ASCONF-ACK (RFC 5061), NR-SACK, PKTDROP,
RE-CONFIG (RFC 6525) and I-FORWARD-TSN. Its serializer is 2208 lines and this
declaration was written from RFC 4960 with the constants checked against INET,
not from a full audit of those lines. The seven are the honest remainder.

### 3.11 Open: a check on an embedded header

A `check` marks on read. `mark_incorrect` returns a `MarkedFields`, which is not
a subtype of the header it wraps — so a header that ANOTHER header embeds cannot
carry a check: a malformed packet becomes an error where it should become a
mark. The same applies to a variant family used as the element type of a list.

Three places already work around it. `BgpOpen` puts its version check on itself
rather than on `BgpCommon`. `Ospfv2Common` and `Ospfv3Common` carry no version
check at all, where INET marks. `BgpAttributeHeader` carries neither of RFC 4271
clause 4.3's two flag rules.

The fix is for `MarkedFields` to be transparent where a header is expected —
either by making the field types accept it, or by having the codec lift a mark
from a field to the header that holds it. The second is the better one: a
malformed option inside a packet makes the packet malformed, which is what
INET's `markIncorrect` on the enclosing chunk already says.

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

A clause sits on its own line, under the field it belongs to. Julia will not
parse two expressions side by side on one line, so the one-line form this plan
first proposed is a syntax error; a clause of any length wraps better on a line
of its own anyway. Found in Phase 2.

```julia
@header Ipv4Header begin
    version         :: U4          = 4
        check(version == 4)
    ihl             :: U4          = 5
        derive(cld(measure_header(h), 32))
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
    header_checksum :: Checksum16  = 0
        derive(checksum_mode == CHECKSUM_COMPUTED ?
               compute_internet_checksum(h, :header_checksum) : header_checksum)
    checksum_mode   :: Model{ChecksumMode} = CHECKSUM_DECLARED
    source          :: Ipv4Address
    destination     :: Ipv4Address
    options         :: Options{Ipv4Option}
        until(offset == Bytes(4) * ihl)
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
    body    :: Octets
        length(Bytes(count))
    tail    :: Rest
    padding :: Pad{Bytes(4), 0x00}
```

Two names changed in Phase 4. The byte run is `Octets`, not `Bytes`, because
`Bytes(n)` is already the `BitLength` constructor — and "octets" is the word the
RFCs use. And padding is a field type rather than a `@pad` line: its boundary
and its fill are both values a type parameter holds, so it needs no clause and
no macro at all. `Pad` and `Constant` fields default to themselves, so a caller
never names one.

`Rest` needs no clause either — the type says everything about it.

Inside a `length` clause, `offset` is where the codec is and `remaining` is
what the window has left, and the clause may name only the fields ABOVE it:
nothing below has been read yet. On the write side there is no window to have a
remainder of, so the width comes from the value.

A header with any of these is variable-length: `chunk_length(h)` answers,
`is_fixed_length(H)` is false, and `chunk_length(H)` raises an error naming
`minimum_chunk_length` instead.

### 9.6 A vector

The IGMPv3 source list.

```julia
    number_of_sources :: U16
        derive(Base.length(source_list))
    source_list       :: Repeated{Ipv4Address}
        count(number_of_sources)
```

`count` gives a number of elements and `length` gives a number of bits; the
codec wants bits, so a count is multiplied by the width of one element where
the method is emitted.

### 9.7 A variant

ICMP. Two small methods, ordinary Julia, no registry and no macro.

A variant is a **family**, the same shape an option family has: an abstract
type and three methods. The base is a member of it, and it is also the
fallback.

```julia
abstract type IcmpMessage <: Fields end

@header IcmpHeader <: IcmpMessage begin        # the base, and the fallback
    type     :: U8
    code     :: U8         = 0
    checksum :: Checksum16 = 0
end

@header IcmpEchoRequest <: IcmpMessage begin
    base            :: IcmpHeader
    identifier      :: U16
    sequence_number :: U16
end

list_variants(::Type{IcmpMessage}) = (IcmpEchoRequest, IcmpEchoReply)
variant_base(::Type{IcmpMessage})  = IcmpHeader
matches_variant(::Type{IcmpEchoRequest}, base) = base.type == ICMP_ECHO_REQUEST
```

The family is abstract so that `peek(pk, IcmpMessage)` can return a member and
still keep its promise about the type it gives back. That is why the base and
the family are two names: one abstract type cannot also be a concrete header.

`select_variant` is generic: it walks `list_variants` and takes the first that
matches. The reader reads the base, rewinds, and reads again as the member —
so a member declares every field once, the base's included, and no case can
forget to copy them. With no match the base comes back, marked misrepresented,
so an unknown subtype still re-serializes byte for byte.

The base header is an **embedded field**, not a supertype. Julia has no struct
inheritance and does not need one — the five-level 802.11 chain is four levels
of embedding.

Embedding landed in Phase 5, because `Repeated{H}` wants it: a field whose type
is a header runs that header's codec in place, and that is three methods. An
embedded `EthernetMacHeader` gives byte-identical output to the flat one, which
is the proof.

### 9.8 A conditional field

The 802.11 fourth address, present only when both distribution-system bits are
set; and the second octet of an IEEE 802.2 control field, present only when the
low two bits are not both set.

```julia
    control_high :: Optional{U8} = nothing
        when(control & 0x03 != 0x03)
```

The clause decides presence on BOTH sides. A struct that says absent where the
clause says present is a header the model built wrong, and the writer says so
rather than emitting a shorter one — the two could otherwise disagree, and the
reader would then read a field the writer never wrote.

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
find_raw_option(::Type{TcpOption})        = TcpOptionUnknown
ends_option_list(::Type{TcpOption}, code) = code == TCPOPTION_END_OF_OPTION_LIST
```

A member states its own code through its first `Constant` field, so nothing
says it twice: `option_code` comes from the declaration. `find_option_type` is
generic — it walks `list_options` and falls back to the raw member.

`until` gives the offset the list ENDS at, counted from the start of the
header, not a predicate. The width is then what is left between here and there,
which is a number the reader has before it starts.

**Phase 6 found one thing the plan did not say.** A derived length normalises
padding. A TCP segment whose sender padded to eight bytes where four would do
re-encodes to four, because `data_offset` is derived from what the options
need. Byte preservation therefore holds where the padding is minimal and not
otherwise; preserving it needs the length read from the wire rather than
derived, which is the choice `total_length` already makes. Decide that per
format, when the format arrives.

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
| 1 ✅ | the value types, and the generic codec over `fieldtypes` | `EthernetMacHeader` is a plain struct that round-trips |
| 2 ✅ | `@header`: defaults, `derive`, `check` | `Ipv4Header` without options round-trips; a version of 5 marks incorrect |
| 3 ✅ | `Draft`, `start_draft`, `build_header` | a required field left unset fails at `build_header`, not on the wire |
| 4 ✅ | variable length: `Octets`, `Rest`, `Pad` | a byte tail round-trips and `peek` finds it |
| 5 ✅ | `Repeated`, and the embedding it needs | an IGMPv3 report round-trips |
| 6 ✅ | `Options` and the TLV family | IPv4, TCP and IPv6 options round-trip in order, with an unknown code preserved |
| 7 ✅ | variants | an ICMP echo request decodes from an `IcmpHeader` window |
| 8 ✅ | the corpus ✅, Wave 1 ✅, Wave 2 ✅ | green over 91 formats |
| 9 ◐ | Wave 3 ✅, Wave 4 started — §3.7 | green over 223 formats |
| 10 | the protocol dispatch table and a pcap reader | optional; only if a capture must be read |

Phases 1 to 7 are the language. Phases 8 and 9 are the inventory. Do not start
Phase 8 before Phase 7 is green: a header declared against a language that then
changes is a header written twice.

Phases 1 to 3 landed together with the rename they forced. The field names now
follow the standards — `dst` became `destination`, `src_address` became
`source`, `ttl` became `time_to_live` — and the MAC FSM generator, the
linklayer tests, the packet demo and the packet diagram all read the new ones.
The golden figure was re-recorded: it draws RFC 791's three flag bits as
`r|d|m`, and `version` as `4` rather than `0100`, because a `U4` prints as the
number it is.

## 13. How to test

1. **The round-trip corpus.** ✅ `RoundTrip.jl`. `@header` registers every
   header it declares, `fill_asymmetric` builds an instance whose every field
   is distinct — reading `fieldtypes`, so no per-header recipe — and
   `check_round_trip` checks that encode, decode and encode again give the same
   bytes and the same length. This is the C++ `serializer_chunk_roundtrip`
   test, and it catches an asymmetry between the reader and the writer, the
   defect class the whole C++ branch is about.

   A field a `check` clause pins keeps its declared value: a header that fails
   its own check tests the check, not the round trip. And the corpus walks the
   headers declared in `PacketModule`, because a probe header in a test file is
   registered too and its clauses want values a generic fill cannot invent.
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
