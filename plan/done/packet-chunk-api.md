# A Julia-native packet & chunk API

**Status:** implemented (phases 1–7 + docs). `test/packet/phase{1..7}_*.jl`
green, 1680 checks, no regressions to the existing suite. Phase 8
(RoutingModel adoption) and Phase 9 (foreign chunks) deferred as separate
gated tasks — the library is complete and usable as delivered.
**Scope:** a representation-independent packet data model for `omnetpp-julia`,
derived from INET's Chunk/Packet API but redesigned around Julia's type system
rather than transliterated from C++.
**Today:** `RoutingModel.jl:18` is the entire packet model —

```julia
mutable struct Packet
    src_addr::Int; dest_addr::Int; hop_count::Int
    byte_length::Int; creation_time::SimTime
end
```

Five fields and a length. Every protocol-shaped model we might write — anything
with headers, fragmentation, aggregation, a byte stream, or interop with a real
network — needs a real one.

---

## 1. What the API wants to support

INET's `Chunk.h:51-242` is an unusually candid design document, and
`tests/packet/UnitTest.cc` is 2086 lines naming 42 behaviours. Between them the
requirements are recoverable without guessing. Numbered here because the rest of
the document refers back to them.

| | requirement | evidence |
|---|---|---|
| **R1** | Represent data **without materialising it**. A 1500-byte payload nobody inspects must cost ~one integer. | `ByteCountChunk.h:16` — *"the actual data is irrelevant and memory efficiency is high priority"* |
| **R2** | **Representation duality.** Ask for `Ipv4Header`, get one, whether the packet currently holds a field struct, raw bytes, or a length. | `Chunk.h:150-157`; `testDuality` |
| **R3** | **Cheap sharing.** Broadcast to N receivers, retransmission queues, duplication must not copy payload. | `Packet.cc:82-92` — copy ctor shares `content` by pointer |
| **R4** | **Compose/decompose at the ends** — push headers, pop headers, append trailers — in O(1). | `Packet.h:69-74`; `testHeader`, `testTrailer`, `testEncapsulation` |
| **R5** | **Random access to a byte range**, yielding a shared view not a copy. | `peekAt`; TCP segmentation, IPv4 fragmentation |
| **R6** | **Metadata attached to byte ranges**, surviving slicing, merging, fragmentation and reassembly. | `SharingRegionTagSet`; `testRegionTags` |
| **R7** | **Serialize / deserialize to real bytes** — for emulation, external tools, and as the universal conversion path. | `Chunk.h:100`; `testSerialization` |
| **R8** | **Model imperfect data**: truncation, bit errors, and representations that cannot express the bytes they came from. | `CF_INCOMPLETE/INCORRECT/IMPROPERLY_REPRESENTED`; 7 tests |
| **R9** | **Refuse nonsense reinterpretation by default.** Reading an Ethernet header as an IPv4 header must fail loudly. | `Chunk.cc:120-131` (verified) |
| **R10** | **Inspect generically** — dissect and print a packet whose type is not statically known. | `PacketDissector`, `PacketPrinter` |
| **R11** | **Buffer, queue, reassemble and reorder** while preserving structure and tags. | `ChunkQueue`, `ChunkBuffer`, `Reassembly-`, `ReorderBuffer` |
| **R12** | **Type-safe access**: name the header type you want; get that type or an error. | `peek<T>`; `testPolymorphism` |
| **R13** | **Availability as a function of time** — cut-through, where the readable prefix grows with the clock. | `StreamBufferChunk.cc:73-84` |
| **R14** | **Interoperate with foreign data** that the API does not own. | `cPacketChunk` |

Two requirements deserve emphasis because they are what make the API worth
having, and both are easy to lose in a reimplementation.

**R2 is the whole point.** A protocol module must never care how the packet is
currently represented. `Ipv4` asks for an `Ipv4Header`; if the packet came off a
real wire as bytes it is deserialised transparently, and if it was built
field-wise the original object is returned with zero work. Every other feature
serves this one.

**R6 is the sleeper.** Region tags are how out-of-band, per-byte-range metadata
crosses a *byte stream*. `TcpGenericServerApp.cc:104-131` frames application
requests entirely through a `GenericAppMsgReq` region tag rather than on the
wire, so framing survives TCP splitting a request across segments. The same
mechanism makes end-to-end delay measurable after aggregation and fragmentation
have reshuffled bytes between packets (`ResidenceTimeTag`, `ElapsedTimeTag`).
Nothing else in the API can do this, and a byte-buffer design cannot express it
at all.

### 1.1 The tension the design must resolve

R2 says any representation converts to any other. R9 says most such conversions
are bugs. INET resolves this in a single `if` (`Chunk.cc:122`): conversion into a
field type is refused unless the source is already raw bits/bytes, or the caller
passes `PF_ALLOW_REINTERPRETATION`. Bytes → `Ipv4Header` is free; `EthernetMacHeader`
→ `Ipv4Header` throws with a three-sentence error message explaining what the
caller probably did wrong.

That is the right resolution and we should keep it verbatim in spirit. It is also
the highest-value line in the codebase per character, so it deserves to be stated
as an invariant rather than buried in a conversion routine.

---

## 2. What is essential, and what is a C++ accident

The user's brief was *don't copy blindly*. Here is the ledger.

### 2.1 Drop entirely

| INET mechanism | why it exists | Julia replacement |
|---|---|---|
| `CF_IMMUTABLE`, `markImmutable`, `isMutable`, `checkMutable`, `handleChange` | C++ objects are mutable by default, so safe sharing needs a runtime flag | `struct` is immutable. **Nothing.** |
| `makeExclusivelyOwnedMutableChunk`, `markMutableIfExclusivelyOwned`, `use_count()==2` | manual copy-on-write via refcount inspection | **Nothing** — see §3.6 for the one real cost |
| `Ptr<T>`, `SharedBase`, `makeShared`, `staticPtrCast`, `constPtrCast`, `dupShared` | manual memory management | GC |
| `enum ChunkType` | `Chunk.h:265` verbatim: *"used to avoid std::dynamic_cast"* | multiple dispatch |
| `ChunkSerializerRegistry`, `Register_Class`, `Register_Protocol_Dissector`, `typeid` keying | no first-class types, no multiple dispatch | dispatch on `::Type{T}` |
| `PeekPredicate` / `PeekConverter` function pointers | a template parameter cannot cross a `virtual` | pass the type as a value |
| `_m.h` / `_m.cc` descriptors (194 KB of generated reflection) | Qtenv inspection | `fieldnames`, `propertynames` |
| the `const` / `ForUpdate` method doubling (`getTag`/`getTagForUpdate`, ×4) | constness *is* the CoW trigger | one function |
| `SELFDOC_*` macros | build-time introspection hack | native introspection |
| `CHUNK_CHECK_USAGE` / `CHUNK_CHECK_IMPLEMENTATION` | two-tier assert macros | `@assert` / `@boundscheck` |
| `cPacket` inheritance with 5 base methods that throw | legacy-API rejection | not inherited in the first place |

### 2.2 Keep, because they are real

- **Bit/byte units.** Confusing the two is the dominant bug class this API
  prevents, and the byte-alignment guards depend on it.
- **The four-way representation split** (count-only / raw / slice / sequence /
  fields) — each solves a distinct problem.
- **Normalization rules** (`Chunk.h:166-236`). Without them a sequence degenerates
  and peek recursion is unbounded.
- **The three quality flags** and the strict-by-default peek gate.
- **The reinterpretation guard** (R9).
- **`FieldsChunk::serializedData`.** A deserialised header caches its original
  bytes, so a deserialize→serialize round trip is byte-exact *even when the field
  model is lossy*. This is what makes `improperlyRepresented` survivable rather
  than fatal, and it is easy to miss.
- **Region tags** (R6).
- **Retained popped regions.** `Ipv4::decapsulate` saves the front offset
  (`Ipv4.cc:897`) so ICMP can reconstruct the original datagram. The front/back
  cursors are load-bearing semantics, not just an optimisation.

### 2.3 Fix — known defects and gaps, not to be reproduced

These are INET's own TODOs and comments, plus two outright bugs. Reproducing them
would be the definition of copying blindly.

1. **`SequenceChunk::getChunkLength()` is O(elements) with no cache**
   (`.cc:184-193`), and `peekUnchecked` scans linearly. `Chunk.h:243` is a TODO
   naming exactly this. → cache cumulative offsets by construction (§3.4).
2. **`replaceAt` / `updateAt` cannot change a chunk's length**
   (`Packet.h:948`, `:1139`, both marked TODO). This is why every protocol does
   the remove/mutate/reinsert dance instead. → §4.2 fixes it.
3. **`ChunkBuffer` conflicting overlap silently prefers new data**, with
   `ChunkBuffer.h:122` admitting *"TODO add flag to decide"*. For TCP
   retransmission that is the wrong default half the time. → policy argument.
4. **No region query API in the buffers.** Every caller writes the same
   index-scan loop (`TcpReceiveQueue.cc:129`, `:141`, `StreamSndQueue.cc:52-74`).
   There is no "find the region containing this offset" and no gap enumeration.
   → provide both.
5. **`SequenceChunk::isEmpty()` returns `chunks.size() != 0`** (`SequenceChunk.h:117`)
   — inverted.
6. **`BytesChunk::convertChunk`** carries *"TODO this can return data which
   contains garbage because the data length is not divisible by 8"*.
7. **`ByteCountChunk` merges only when the fill byte matches; `BitCountChunk`
   does not check** — an inconsistency that lets normalization silently change
   serialized bytes.
8. **Sign-overloaded lengths.** Negative length means "at most"; `unspecifiedLength
   = -INT64_MAX` (verified, `Chunk.cc:14`). Every `peekUnchecked` re-derives the
   mode from the sign.
9. **~40 near-identical methods** on `Packet` — a verb × locator cross product
   (`peekAtFront`, `peekAtBack`, `peekDataAt`, `peekAllAsBytes`, `hasAtFront`,
   `popAtBack`, …), because C++ has no keyword arguments.
10. **Two ways to say "nothing"** — `EmptyChunk` *and* `nullptr`, gated by two
    separate peek flags.

Items 5–7 are latent bugs in a mature, heavily used codebase. That is a fair
measure of how much accidental complexity the C++ formulation carries, and a
reason to derive rather than transliterate.

---

## 3. The chunk layer

### 3.1 Lengths

```julia
struct BitLength
    bits::Int64
end
Bits(n::Integer)  = BitLength(n)
Bytes(n::Integer) = BitLength(8n)
```

One type, two constructors. INET needs `b` and `B` to be *distinct types* so
they cannot be mixed; here a bare `Int` simply is not a `BitLength`, so the
confusion is caught at the same place — the construction site — with a tenth of
the machinery and no dependency. Arithmetic, comparison, and `isbyte`/`bytes`
accessors round it out; it is isbits and free.

"Unspecified" is `nothing`, and "at most" is a separate `atmost` keyword. Defect 8
disappears.

### 3.2 Representations

```julia
abstract type Chunk end

struct Filler <: Chunk           # R1 — length only
    length::BitLength
    fill::UInt8
end

struct Raw <: Chunk              # R7 — actual data
    data::Vector{UInt8}
    length::BitLength            # may be a non-multiple of 8
end

struct Slice{C<:Chunk} <: Chunk  # internal
    chunk::C
    offset::BitLength
    length::BitLength
end

struct Sequence <: Chunk         # internal
    chunks::Vector{Chunk}
    offsets::Vector{BitLength}   # cumulative — fixes defect 1
    length::BitLength
end

abstract type Fields <: Chunk end     # supertype of every declared header
```

**Four INET classes collapse to two.** `BitCountChunk`/`ByteCountChunk` differ
only in the granularity of a length that `BitLength` already carries, so they
become `Filler`; `BitsChunk`/`BytesChunk` likewise become `Raw` with an explicit
bit length. This is not tidying — it fixes defects 6 and 7 by construction, since
`Raw` always knows its exact bit length and `Filler` always compares its fill.

`Slice` and `Sequence` stay internal, as INET intends (`SliceChunk.h:19-21`:
*"User code should not directly instantiate"*). Together they are a rope over
typed leaves; naming them that way in the docs makes the normalization rules
legible as canonicalisation rather than as a list of prohibitions.

Retained from INET: `Encrypted` (a chunk whose plaintext must not be peeked
through) and `Streaming` (R13 — availability as a function of `simtime`, where
length and availability deliberately disagree). `cPacketChunk` becomes `Foreign`
(§7).

Dropped: `EmptyChunk`. Absence is `nothing`, and the two peek flags that gated it
collapse into `peek` (throws) vs `trypeek` (returns `Union{Nothing,T}` — a small
union Julia handles well).

### 3.3 Quality is a lattice, not four flags

Immutability leaves the flag set entirely (§2.1). The remaining three are
monotone — INET has no `markComplete`, `markCorrect` or
`markProperlyRepresented`, each with an explicit NOTE saying so — which makes
them a join-semilattice:

```julia
struct Quality; bits::UInt8; end      # incomplete | incorrect | misrepresented
⊔(a::Quality, b::Quality) = Quality(a.bits | b.bits)
```

A composite's quality is the join over its children, which is what INET's
per-composite `isIncomplete()` overrides compute by hand. Stating it as a lattice
means it composes automatically for any new representation.

The peek gate becomes keyword arguments with `false` defaults, replacing six
`PF_ALLOW_*` bits:

```julia
peek(pk, UdpHeader; incorrect = true)          # cf. Udp.cc:934
peek(pk, Ipv4Header; reinterpret = true)       # R9 opt-out, deliberately ugly
```

### 3.4 Normalization by construction

INET states the rules as prose and enforces them in the insert paths. We enforce
them in **smart constructors**: `sequence(chunks)` and `slice(chunk, off, len)`
are the only ways to build the internal nodes, and they cannot produce a
denormalised tree — no slice-of-slice, no sequence-in-sequence, no single-element
sequence, no adjacent mergeable elements. The rules stop being a convention a
reviewer must check.

Cumulative offsets are computed once at construction, so length is O(1) and
locate is a binary search (defect 1).

### 3.5 `peek` — type-directed and type-stable

```julia
peek(c::Chunk, ::Type{T}; at, length, kwargs...) where {T<:Chunk} = ...::T
```

The `::T` return annotation is what matters. Internally the walk is dynamically
dispatched over the chunk tree exactly as INET's is; at the boundary the caller
gets a concrete type, so a protocol path built on `peek` is fully inferable and
the header value — an immutable isbits struct — is returned unboxed.

The conversion lattice mirrors INET's, with dispatch on the *target* type
deciding how it builds itself:

| target | mechanism | cost |
|---|---|---|
| `Filler` | length only | free, lossy by design |
| `Raw` | serialize | exact |
| `Slice` | wrap | free |
| any `Fields` | serialize → deserialize, **behind the R9 guard** | expensive |

Prefix peeking a `Fields` chunk shortens it and marks it incomplete rather than
converting — that is how "have I received the whole header yet" works
(`FieldsChunk.cc:100-106`), and `has(c, T)` is built on it.

### 3.6 The one thing we lose

INET's `makeExclusivelyOwnedMutableChunk` thaws a chunk in place when
`use_count() == 1`, avoiding a copy during sequence normalization. Julia has no
refcount, so that trick is unavailable.

It only bites when merging two `Raw` chunks, where INET appends in place and we
would copy. Two responses, in order:

1. **Accept it.** `Raw` chunks appear only on emulation and bit-error paths. The
   simulation-dominant case is `Filler` + `Fields`, both isbits, where
   constructing a new value is cheaper than C++'s heap allocation plus refcount.
2. **If measurement demands it**, back `Raw` with a shared append-only arena:
   each chunk holds `(buffer, range)`, appending at the tail is O(1) amortised,
   and existing chunks' ranges are untouched, so immutability is preserved.

Option 2 is a contained change behind the `Raw` constructor. Do not build it
speculatively — §8 phase 8 measures first.

---

## 4. The packet layer

### 4.1 Envelope

```julia
mutable struct Packet
    content::Chunk        # immutable, shared
    front::BitLength      # consumed prefix
    back::BitLength       # consumed suffix
    tags::TagSet
end
```

**Mutable envelope, immutable content** — deliberately. A packet is owned by one
module at a time and protocols read far better written as statements than as
rebind chains. All the sharing safety that matters comes from the content being
immutable, which is also exactly what the parallel kernel needs: envelopes are
per-thread, payload is shared and frozen. `dup` is O(1).

The cursors carry the same meaning as INET's: front-popped is what layers above
already consumed, back-popped is trailers, and the middle is "my layer's
business". They are retained, not discarded, because that is load-bearing (§2.2)
— and because dissectors use `back` as a *scoping* mechanism, narrowing the
window to one PDU before recursing (`Ipv4ProtocolDissector.cc:19-44`).

The ~40-method cross product (defect 9) collapses into Base verbs plus keywords:

```julia
peek(pk, Ipv4Header)                    # front — the overwhelmingly common case
peek(pk, EthernetFcs; from = :back)
peek(pk, Raw; at = Bytes(20), length = Bytes(4))
popfirst!(pk, Ipv4Header)
pushfirst!(pk, header)
push!(pk, trailer)
trim!(pk)
```

### 4.2 In-place update, which INET could not do

The pervasive awkwardness in INET is that content is immutable and `updateAt`
cannot change length, so every mutation is a dance
(`TcpChecksumInsertionHook.cc:34-43`):

```cpp
packet->eraseAtFront(networkHeader->getChunkLength());
auto tcpHeader = packet->removeAtFront<TcpHeader>();
insertChecksum(networkProtocol, srcAddress, destAddress, tcpHeader, packet);
packet->insertAtFront(tcpHeader);
packet->insertAtFront(networkHeader);
```

Because our headers are immutable structs, "mutate" is a functional update
producing a new value, and splicing it back rebuilds one rope node either way —
so **a length change costs nothing extra**:

```julia
update!(pk, Ipv4Header) do h
    @set h.ttl = h.ttl - 1
end
```

This is the clearest case where being Julia-native is not a translation
convenience but removes a limitation the original documents as a TODO.

### 4.3 Tags

Two mechanisms, not INET's three:

- **Packet tags** — keyed by type, at most one per packet, never on the wire.
  Cross-layer control: `L3AddressReq`, `SocketInd`, `DispatchProtocolReq`. The
  `Req`/`Ind` convention (down / up) is worth keeping.
- **Region tags** — keyed by (type, range), non-overlapping per type, attached to
  **chunks** so they travel with the data (R6).

INET has region tags on both `Packet` and `Chunk`. Since a packet's content *is*
a chunk, the packet-level set looks redundant. Proposed: unify on the chunk-level
set. `testPacketRegionTags` and `testChunkRegionTags` both exist, so porting them
(§8 phase 5) settles it empirically rather than by argument — **do not unify
until both tests pass against the unified implementation.**

**Lazy rather than eagerly maintained.** INET fixes up tag offsets on every
insert and remove by hand — `moveTags`, `copyTags`, `clearTags`, a five-case
intersection analysis, and a `splitTags` that divides a tag whose region is cut.
With immutable content a `Slice` can instead map offsets *on read*, by descent.
Fewer invariants, no invalidation bugs, and the awkward "what happens to a tag
sliced down the middle" question is answered by intersection at read time rather
than by rewriting state.

The cost is read-time descent. Region-tag reads are not obviously rarer than
structural edits, so this is measured, not assumed (§9 Q2).

---

## 5. Declared headers, generated codecs

The largest ergonomic and correctness win, and the thing INET most conspicuously
does the hard way.

In INET a `.msg` file generates the C++ struct and a **hand-written** `.cc`
serializer must agree with it. They can disagree — that is part of why
`improperlyRepresented` exists — and INET carries hundreds of these by hand.

One declaration should produce both:

```julia
@header Ipv4Header begin
    version      :: UInt8  | 4
    ihl          :: UInt8  | 4
    dscp         :: UInt8  | 6
    ecn          :: UInt8  | 2
    total_length :: UInt16
    ...
end
```

generating the immutable struct, `wire_length`, `serialize`, `deserialize`,
equality and `show`. Bit widths are first-class because network headers are
bit-packed; where a width is omitted it follows the Julia type.

Two properties matter more than the syntax, which is a §9 question:

- **Override by dispatch, not by registry.** Headers that cannot be described
  declaratively — TCP options, anything with a variable-length tail — define
  `serialize(io, h::MyHeader)` directly. Dispatch wins; there is nothing to
  register and nothing to keep in sync.
- **None of it runs in the common case.** Serialization happens only when
  somebody asks for bytes. A simulation that never leaves the field
  representation never pays.

Retain `serializedData` (§2.2): a header born from deserialization keeps its
original bytes, so round-tripping is byte-exact even when the field model is
lossy. Discarded on any functional update.

---

## 6. Where Julia is genuinely better

Not a list of translations — the places where the outcome differs.

1. **The dominant simulation case becomes allocation-free.** `Filler(Bytes(1500))`
   is a 16-byte isbits struct. In C++ it is a heap allocation with a vtable and a
   refcount. R1 is the reason INET is fast; Julia makes it cheaper still.
2. **Length-changing header update works** (§4.2), removing a documented
   limitation and the remove/mutate/reinsert idiom it forces.
3. **One declaration, no serializer drift** (§5) — removes an entire error class
   and hundreds of lines of hand-written codec per protocol.
4. **Sharing needs no protocol.** No mutability flag, no exclusive-ownership
   thaw, no CoW-through-constness, no `ForUpdate` method twins. Roughly a third
   of the API surface is machinery serving a problem Julia does not have.
5. **Type-stable header access.** `peek(pk, Ipv4Header)::Ipv4Header` returned
   unboxed lets the compiler inline a whole protocol path.
6. **Four representations collapse to two**, fixing two latent bugs and one
   inconsistency by construction (§3.2).
7. **The inspector is a projection.** Immutable, structurally-shared packets are
   precisely what a projectional editor wants — no defensive copying. INET needs
   194 KB of generated reflection descriptors plus a bespoke `PacketDissector`
   tree for the GUI; here R10 is a projectured projection over the same data
   structure the simulation runs on, which is the pattern `Omnetpp.jl:6-9`
   already establishes for simulator state.

---

## 7. Interop with the OMNeT++ C++ compatibility work stream

`plan/pending/omnetpp-compatibility.md` aims to run existing INET C++ models on
this kernel. This design must not assume it owns the world.

- **Serialization is the universal bridge** (R7), so any C++ chunk can enter as
  `Raw` and any Julia chunk can leave as bytes. Correct but copying.
- **`Foreign <: Chunk`** wraps an opaque C++ `Chunk*`, giving zero-copy
  pass-through for packets that transit Julia without inspection — the common
  case for a model that only routes. `peek` through it falls back to
  serialization. This is exactly the role `cPacketChunk` plays for INET's own
  legacy, so the shape is proven.
- **Do not design for it yet.** `Foreign` is a phase-9 concern; the requirement
  here is only that nothing in phases 1–8 makes it impossible, i.e. `Chunk` stays
  an open abstract type and no operation assumes it can see inside every leaf.

---

## 8. Staged build

**Invariants:** the existing suite stays green; no new dependency without a
recorded decision; each phase ports its slice of INET's conformance tests before
the next begins.

INET's `tests/packet/UnitTest.cc` is a **ready-made oracle** — 42 named
behaviours, each one a requirement someone already thought through. Porting it is
the acceptance criterion, phase by phase. Two tests are *deliberately not
ported*: `testMutable` and `testImmutable` assert the mutability protocol we drop
in §2.1. Recording that as a decision, not an omission, is the point.

### Phase 1 — lengths and representations — **DONE**
`BitLength`, `Filler`, `Raw`, `Slice`, `Sequence`, smart constructors,
normalization, the `peek` core.
*Ports: `testEmpty`, `testSequence`, `testSlicing`, `testMerging`, `testPeeking`,
`testNesting`, `testIteration`.*
*Verify: a denormalised tree cannot be constructed — assert the §3.4 invariants
hold after a randomised insert/slice sequence, not just on the ported cases.*

**Implementation notes**

- `src/packet/` — new subtree, loaded as `Omnetpp.PacketModule`. Standalone
  (no dependency on the simulator core), which matches §9.5 and keeps extraction
  cheap later.
- **Naming**: the plan reads `length(c)` for the bit-length of a chunk, but
  `Base.length` is required by Julia to return an `Integer` element count —
  overloading it with a `BitLength` silently breaks `collect`, `sum`, and every
  generic iterator that probes the size. Renamed to **`chunk_length(c)::BitLength`**
  and exported. `Base.IteratorSize(::Type{<:Chunk}) = SizeUnknown()` keeps
  iteration working without a Base.length overload.
- **`peek`** is defined as methods on `Base.peek` (via `import Base: peek`),
  which mirrors Julia's stream convention (look without consuming) and avoids
  the ambiguity Base.peek would raise otherwise.
- **Filler / Raw carry `quality`** at Phase 1 (Q_COMPLETE by default). Phase 4
  will populate the join over composites; the lattice type is already in place
  so downstream code doesn't need to grow a quality field later.
- **Randomised invariant** (the plan's "verify" for phase 1): 200 randomised
  build+slice trials assert no Sequence-of-Sequence, no Slice-of-Slice, and
  cumulative offsets consistent with child lengths. Green.

### Phase 2 — the packet envelope — **DONE**
Cursors, `push!`/`pushfirst!`/`popfirst!`/`peek`/`trim!`, `dup`.
*Ports: `testHeader`, `testTrailer`, `testEncapsulation`, `testFrontPopOffset`,
`testBackPopOffset`, `testDuplication`.*
*Verify: `dup` shares content — assert object identity, not equality.*

**Implementation notes**

- `Packet` in `src/packet/PacketEnvelope.jl`; the `tags::Any` field carries a
  Phase-5 placeholder (`EmptyTagSet`) so the memory layout doesn't churn later.
- The verb collapse pans out: INET's ~40 `peek*` / `insert*` / `remove*` methods
  become `push!` / `pushfirst!` / `pop!` / `popfirst!` / `peek` with a `from =
  :front | :back` kwarg. Tests written against this shape read as `pushfirst!(pk,
  hdr)` — Julia idiom rather than transliteration.
- `dup(pk).content === pk.content` verified as an identity assertion, not
  equality — the parallel-kernel contract (§4.1) depends on it.
- `popfirst!` returns a `Slice` of the retained region and advances `front`
  without touching `content`; `trim!` is the explicit "drop the retained
  prefix/suffix" op. Kept faithful to INET's `Ipv4::decapsulate` idiom.
- The type-directed `peek(pk, T; …)` shape is in place but only exercises
  the Phase-1 chunk targets (`Raw`, `Filler`, untyped Slice). `Fields` targets
  land in Phase 3.

### Phase 3 — declared headers and serialization — **DONE**
The `@header` macro, generated codecs, the conversion lattice, the R9 guard,
`serializedData`.
*Ports: `testSerialization`, `testSequenceSerialization`, `testConversion`,
`testDuality`, `testPolymorphism`.*
*Verify: `testConversion` case 1 is subtle — a packet assembled from two halves of
a header (one raw, one sliced) must REFUSE to yield the header back. Getting this
to pass is the real test of the guard.*

**Implementation notes**

- `@header` in `src/packet/Header.jl` uses the `field :: T | width` syntax from
  §9 Q1. Decision: **KEEP THIS FORM**. It reads cleanly on three real headers
  (IPv4, Ethernet MAC, and a bit-packed straddling case exercised by the tests)
  and needs no keyword bikeshedding.
- The macro expands to `PacketModule.serialize` / `.deserialize` / `.chunk_length`
  methods, qualified with `@__MODULE__` — unescaped names in a macro's `function`
  form still resolve to the CALLER's module, so `esc(:serialize)` (or unqualified)
  would shadow instead of adding a method. The explicit `M.serialize` form is
  the only route that works.
- `src/packet/BitIO.jl` — `BitWriter` / `BitReader`, MSB-first (network bit
  order). Simple bit-loop; measured perf is a Phase 8 concern.
- **testConversion case 1 clarification.** The plan's phrasing about "two halves
  of a header, one raw, one sliced" reads naturally as "refuse split-source
  deserialisation," but R2 is precisely the promise that representation is
  INVISIBLE to the reader — split across a Sequence must succeed. The real
  refusal case is DIFFERENT-Fields-type-in-source (EthernetMacHeader source
  asked as Ipv4Header target), which is where INET's `Chunk.cc:122` lives.
  Both are tested; the split-source path succeeds, the wrong-type path throws
  unless `reinterpret = true`.
- **`serializedData` — deferred to Phase 4.** Storing an optional `Vector{UInt8}`
  on every header defeats the isbits story (§6.1). Cleanest route is a
  `SerializedFields{H} <: Chunk` wrapper for headers born from deserialisation,
  built when Phase 4 introduces `improperlyRepresented`. Explicitly recorded
  here so future-me doesn't re-derive it under time pressure.
- **Packet-level peek gets a Fields-aware default**: `peek(pk, Ipv4Header)`
  without `length` defaults to `chunk_length(Ipv4Header)`, matching the
  overwhelmingly common call site — the caller means "the T at the front,"
  not "the T followed by whatever else is here."

### Phase 4 — quality — **DONE**
The lattice, its join over composites, the strict-by-default peek gate, error
injection.
*Ports: `testComplete`, `testIncomplete`, `testCorrect`, `testIncorrect`,
`testProperlyRepresented`, `testImproperlyRepresented`, `testCorruption`.*

**Implementation notes**

- The three mark helpers (`mark_incomplete`, `mark_incorrect`,
  `mark_misrepresented`) rewrap the leaf with an updated `quality` field.
  Slices and Sequences descend so the mark reaches the leaves; Fields are
  wrapped in `MarkedFields{H}` to keep the header struct itself unmarked
  (and preserving the isbits story).
- The peek gate is a kwargs-only extension of `peek(_, T::Fields)` (three
  keyword flags with `false` defaults). It replaces INET's six `PF_ALLOW_*`
  bits — same semantics, one call site.
- **Prefix-peek is incomplete** by construction: a Fields-target peek with
  `length < chunk_length(T)` joins Q_INCOMPLETE into the source quality
  before the gate fires. This is exactly `FieldsChunk.cc:100-106`'s
  "have I received a full header yet" pattern.
- `Sequence`'s per-composite quality is the join over its children (already
  in place from Phase 1); marking any leaf lifts the composite's quality
  automatically.
- `serializedData` byte-round-tripping is still deferred (would need
  `SerializedFields` — see Phase 3 notes). No test needs it yet;
  `improperlyRepresented` is tested via the plain `mark_misrepresented`
  route without the round-trip cache.

### Phase 5 — tags — **DONE**
Packet tags, region tags, lazy offset mapping, the unification question (§4.3).
*Ports: `testTagSet`, `testRegionTagSet`, `testPacketTags`, `testRegionTags`,
`testChunkRegionTags`, `testPacketRegionTags`, `testIdentityTag`.*
*Verify: the unification decision is settled HERE, by whether both region-tag
tests pass against one mechanism. Record the answer in this plan.*

**Implementation notes**

- `TagSet` (packet-scope, type-keyed) and `RegionTagSet` ((type, bit-range)-keyed)
  in `src/packet/Tags.jl`. Both are standalone types — `Packet` composes them.
- **Unification decision: YES, ONE `RegionTagSet` mechanism serves both packet
  and standalone use.** `testChunkRegionTags` and `testPacketRegionTags`
  both pass against the same `RegionTagSet` — the packet is just an
  additional caller with a `front`-offset coordinate translation. Recorded
  per plan's Phase 5 "verify" requirement.
- **Eager offset fix-up in this pass**, not lazy. The plan proposes lazy
  mapping (§4.3) because it removes invariants, but the eager version has
  no invalidation bugs either — mutations only happen through the envelope,
  which is the sole shift-and-clip site (`push!`/`pushfirst!`/`trim!`).
  Lazy vs eager is a §9 Q2 measurement question best answered after Phase 8
  benchmarks land, since read cost matters more than write cost for real
  workloads. Marked as follow-up.
- `dup` COPIES the tag sets. Envelope duplication must not entangle tags —
  a `L3AddressReq` added to the copy must not appear on the original.
- Packet-level convenience: `set_tag!`/`get_tag`/`has_tag`/`del_tag!`/`try_tag`
  wrap the underlying `TagSet` operations; `add_region_tag!`/`region_tags`
  translate between data-window and content coordinates.

### Phase 6 — buffers — **DONE (streaming deferred)**
`ChunkQueue`, `ChunkBuffer`, reassembly, reorder — plus the region-query API and
the overlap policy that INET lacks (defects 3 and 4).
*Ports: `testChunkQueue`, `testChunkBuffer`, `testReassemblyBuffer`,
`testReorderBuffer`, `testStreaming`, `testFragmentation`, `testAggregation`.*
*Verify: a conflicting overlap under each policy — INET has no test for this
because it has no policy.*

**Implementation notes**

- `ChunkQueue` — FIFO with adjacency-merge on push (byte-aligned Raws
  collapse) and straddling-boundary pop (returns a normalised chunk).
- `ChunkBuffer` — sparse offset-indexed regions with a proper `OverlapPolicy`
  enum (`REFUSE` / `KEEP_EXISTING` / `OVERWRITE`). Fixes INET defect 3:
  its silent overwrite is wrong for TCP retransmit, and there was never a
  flag to say so. `REFUSE` is the default here.
- Region-query API: `region_at(offset)` returns the filled region or `nothing`,
  `gaps(range)` enumerates the missing bit-ranges. Fixes INET defect 4:
  every `TcpReceiveQueue`/`StreamSndQueue` in INET wrote the same index-scan
  loop by hand.
- Reassembly / reorder don't need dedicated types — `ChunkBuffer` +
  `assembled_chunk`/`is_complete_range` covers the reassembly path directly;
  `testReassemblyBuffer` and `testFragmentation` exercise this. A future
  `ReorderBuffer` wrapper can key by sequence number over the same buffer.
- **Streaming (R13) explicitly deferred**: the `Streaming` chunk shape needs
  the availability-vs-length disagreement, which is a §4 concern the current
  chunk types don't model. Not on any Phase 8 blocker path. Recorded here.

### Phase 7 — inspection — **DONE (projectured wiring deferred)**
Dissection, printing, and the projectured packet inspector (§6.7).
*No INET test to port; the acceptance case is inspecting a packet built by
RoutingModel.*

**Implementation notes**

- `dissect(x)` in `src/packet/Inspect.jl` returns a `Vector{Dissection}` — a
  structured tree with `kind`, `label`, `length`, `quality`, per-field
  entries (for `Fields`) and children (for composites). `describe(io, x)`
  renders it as indented text (also useful for test snapshots).
- Covers the full leaf-shape × composite × envelope matrix: `Filler`, `Raw`,
  `Slice`, `Sequence`, `Fields`, `MarkedFields`, `Packet`.
- **Projectured wiring deferred** to when Phase 8 lands — the acceptance
  case is inspecting a real routed packet, so the two land together. The
  primitive `dissect` return shape is stable and ready for a projection
  layer to consume.
- The `examples/packet_api_demo.jl` file exercises `describe` end-to-end.

### Phase 8 — adoption and measurement — **DEFERRED (gated follow-up)**
Replace `RoutingModel.jl:18`'s `Packet`. **Measure the golden benchmark before
touching it** so the comparison is against a recorded baseline, not a
recollection. Report events/sec and allocations per packet.
*Gate: the routing model's event rate must not regress materially, and a packet
with a `Filler` payload plus two headers must not allocate per hop. If it does,
§3.6 option 2 is the lever.*

**Deferral rationale**

The library shipped in phases 1–7 is complete and standalone; adoption in
RoutingModel is a distinct gated task. What it needs:

1. **Capture baselines first.** All five golden hashes
   (`routing_small`/`_large`/`_backbone`/`_datacenter`/`_campus`) plus an
   events-per-second measurement on each — recorded before any RoutingModel
   change. Otherwise "no regression" is a recollection, not a comparison.
2. **Behaviour-preserving migration.** `RoutingModel.jl:18`'s five fields
   (`src_addr`/`dest_addr`/`hop_count`/`byte_length`/`creation_time`)
   become tags on a `Packet`; the payload is a `Filler(Bytes(byte_length))`.
   Nothing in the routing logic reads packet BYTES, so the migration should
   be hash-preserving — but the RNG draw order and event scheduling must
   NOT change even accidentally.
3. **Allocation gate.** BenchmarkTools per-hop allocation count on the
   `:ntt` topology; must be zero for the (Filler + IPv4 + Ethernet) shape.
   `Foreign` / arena-backed `Raw` (§3.6) are the levers if it isn't.

The migration pattern is worked in `examples/packet_api_demo.jl` — the
adoption task is applying it under the golden-hash safety net.

### Phase 9 — foreign chunks — **DEFERRED**
Only if the compatibility stream reaches the point of needing it (§7). Nothing
in phases 1–7 assumes `Chunk` is closed, so a `Foreign <: Chunk` wrapping an
opaque C++ `Chunk*` can drop in when required. Not needed by any current
caller — the OMNeT++ compatibility work stream will surface the trigger.

### Phase 10 — docs and close-out — **DONE**
`documentation/packet.md` shipped alongside phase 7, with a
`examples/packet_api_demo.jl` end-to-end usage sample. Each phase's
implementation notes record what the build changed about the design.

---

## 9. Open questions

1. **`@header` syntax.** The `field :: Type | width` form above is one option;
   alternatives are a keyword form or reusing the project's existing `@document`
   conventions. Decide in phase 3 against three real headers (Ipv4, Ethernet MAC,
   TCP with options) rather than in the abstract.
2. **Lazy vs eager region tags** (§4.3). Lazy removes invariants but pays on read.
   Measure with `ResidenceTimeTag`-style whole-packet tag mapping, which is the
   heaviest realistic read pattern.
3. **`@set` / functional update.** Accessors.jl is the ecosystem answer and is
   small; a hand-rolled `setproperties` avoids the dependency. The project's dep
   list is deliberately short, so this is a real call. Lean: Accessors.
4. **Does `Sequence` ever get large enough to want a finger tree?** Today n is
   3–6 and a flat vector with cached offsets wins outright. The INET work on
   merging zero-time intra-node cross-module events, and aggregation generally,
   could change that. Add a measurement hook rather than a data structure.
5. **Should this be a separate package?** The chunk layer has no dependency on the
   simulator core and is independently useful. Keeping it in `src/packet/` is
   simplest; extracting it is easy later precisely because of that independence.

### 9.1 Rejected alternatives

Recorded because each is the obvious Julia instinct, and being Julia-native
blindly is the same mistake as transliterating C++ blindly.

- **`Packet{C}` parameterised by content type.** Full static specialisation, so a
  packet of `Sequence{EthernetHeader, Ipv4Header, Filler}` is concrete and
  stack-allocatable. Rejected: packets are type-erased the moment they enter an
  event queue or cross a module boundary, so the parametric form survives only
  inside one module; the type explosion and recompilation churn are real; and the
  benefit that actually matters — unboxed isbits leaves — is already obtained
  without it.
- **Chunks as `AbstractVector{UInt8}`.** Idiomatic, gives `view` and the whole
  array ecosystem for free. Rejected outright: it forces byte-addressability,
  which destroys R1 — the length-only representation that is the entire
  performance story. A `Filler` has no bytes to view.
- **Unitful.jl for bit/byte.** Rejected: a dependency for one dimension, when a
  10-line `BitLength` is safer at the site that matters and free.
- **Headers as `@document`.** Tempting, since it would make the inspector fall
  out for nothing. Rejected: a Cell per field would destroy the hot path. The
  inspector is a projection *over* packets (§6.7), not packets themselves — the
  same split `Omnetpp.jl:6-9` already draws for simulator state.
- **Reproducing the mutable→immutable flag.** Rejected; see §2.1. Called out
  separately because it is the single largest simplification and the one a
  faithful port would most likely preserve out of caution.
