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
no drift possible between them. Bit widths are first-class:

    @header Ipv4Header begin
        version      :: UInt8  | 4
        ihl          :: UInt8  | 4
        dscp         :: UInt8  | 6
        ecn          :: UInt8  | 2
        total_length :: UInt16
        # …
    end

Yields `struct Ipv4Header <: Fields`, `chunk_length(::Ipv4Header) =
Bytes(20)`, `serialize(io::BitWriter, h)`, `deserialize(::Type{Ipv4Header},
io::BitReader)`, and a nice `show`. Headers whose codec cannot be described
declaratively (TCP options, variable-length tails) just define
`serialize`/`deserialize` directly — dispatch wins.

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
