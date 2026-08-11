# A packet is a document

Every packet type — the envelope, the chunks, the declared headers — becomes a
ProjecturEd document. `InetPacket` gains one dependency, `ProjecturedKernel`,
and gains with it the thing the whole substrate is built on: a value that can be
looked at, navigated, selected into and edited, without a mirror of it existing
somewhere else.

This is the everything-is-a-document requirement of the substrate applied to the
data the network carries. [IR-MACHINES-ARE-DOCUMENTS](../../documentation/requirements.md#ir-machines-are-documents)
already says it for protocol logic. This plan says it for protocol data.

Status: **PENDING**. Nothing is implemented.

> **Two constraints from the owner, 2026-08-11, and §4 changes to meet them.**
>
> 1. **No reactive instance on the hot path. Period.** Not a budget, not a
>    percentage — a rule. A reactive field access allocates **16 bytes**; a
>    native or immutable one allocates nothing. Nothing a simulation touches is
>    reactive, whatever the measured share turns out to be.
> 2. **No selection field on the hot path.** The injected
>    `Union{Nothing, Reference, SelectionDocument}` takes a chunk leaf from
>    **isbits at 16 bytes to a heap object at 24**, and adds 8 bytes to the
>    envelope. Every hot-path type declares `selection::Nothing`.
>
> Both are measured in §3.2. The second costs selectability, which §4.2 works
> through — it is not free, and it is not negotiable either.
>
> The document naming also changed under this plan's feet. `FooMut` is now
> `MFoo`, `AbstractFoo` is `AFoo`, the cell layout is `ACFoo`, and the spellings
> are `RCFoo` / `ICFoo` / `MCFoo` / `DCFoo`. A declaration now says what its bare
> name means. `DocumentMacro.jl` is **no longer sealed**. See
> `../../../projectured-julia/plan/pending/document-layouts-and-names.md`.

## 1. Why — four workarounds that disappear

The packet diagram of [packet-headers-and-diagram.md](../done/packet-headers-and-diagram.md)
is finished and works. Four things in it exist only because a packet is not a
document, and all four go away here.

1. **A page cannot splice a packet.** A marker's value arrives inside a
   `WidgetCard`, and a card renders its content only when the content is a
   `Document` — `w.content isa Document` in
   [`WidgetToGraphics.jl`](../../../projectured-julia/package/visual/main/widget/WidgetToGraphics.jl).
   So the page splices `packet_diagram(pk)`, a second document that stands for
   the packet.
2. **A packet cannot announce a change.** It holds no cells, so §8.3 of that
   plan had to write a rule down: *a document that holds a packet announces a
   change by writing the field, not by mutating the packet.* A rule a caller
   must remember is a mechanism that is missing.
3. **No edit crosses the first stage.** `map_reference_backward` returns
   `nothing` because a packet has no reference steps to name (§8.4). Give it
   steps and editing a header field in the figure becomes ordinary work.
4. **`dissect` describes what cannot describe itself.**
   [`Inspect.jl`](../../package/packet/main/Inspect.jl) builds a parallel tree of
   labels and lengths because the chunk tree is not walkable by the generic
   machinery. A document tree is.

The gain is larger than the four. **Observability** is the point: a live packet
in a running simulation becomes a thing an inspector can open, a reference can
point into, and a projection can watch — with no shadow, no sync and no
snapshot.

## 2. The requirement this changes

[IAR-PACKET-DEPENDS-ON-NOTHING](../../documentation/architecture-requirements.md#iar-packet-depends-on-nothing)
says `InetPacket` carries no `[deps]` at all. Rewrite it:

> ### IAR-PACKET-DEPENDS-ON-THE-DOCUMENT-SUBSTRATE
>
> **`InetPacket` depends on `ProjecturedKernel` and nothing else.** No
> simulator, no external packages — `package/packet/main/Project.toml` names one
> dependency, and says why. The packet and chunk API is a data model, and in
> this system a data model is a **document**: its values are navigable,
> selectable and reactive, so an inspector, a projection and a reference reach
> them without a mirror. `ProjecturedKernel` is the document substrate and
> carries no runtime dependencies of its own, so this edge costs one leaf
> package. A change that needs the *simulator* from inside `InetPacket` is still
> in the wrong package.

Two facts make the edge cheap, and both belong in the rewritten requirement.

- `ProjecturedKernel`'s own `Project.toml` has no `[deps]` section. The edge
  adds one package to the graph, not the editor stack. `ProjecturedBase`,
  `ProjecturedVisual` and the backends stay out.
- The kernel is the substrate, not the editor: cells, documents, references,
  operations and the projection interface. Nothing in it opens a window.

Update the dependency table and the `packet` row of
[architecture.md](../../documentation/architecture.md) in the same change.

## 3. What being a document costs

`@document` rewrites a struct into a **cell layout** `ACFoo` with one cell per
field, a native `MFoo` layout, and an abstract **family** `AFoo` both share. It also injects a
`selection` field. Two independent axes decide the cost.

**The cell kind, per field.** `ImmutableCell{T}` is a plain immutable wrapper
with a concrete field type: it inlines into its parent and is read-only, so a
field declared with it costs nothing at run time. `MutableCell{T}` is a plain
box. `ReactiveCell{T}` adds the dependency bookkeeping that makes a write
invalidate what read it.

**The selection field.** The injected form is `Union{Nothing, Reference}`, and
a node carrying it is **selectable**. Declaring `selection::Nothing` by hand
instead keeps the struct isbits and makes it a **value** — a leaf nobody can put
a caret in. `StyleText` is the worked example:

```julia
@document ImmutableCell [DC] struct StyleText
    font::StyleFont
    color::StyleColor
    selection::Nothing
end
```

### 3.1 What a bare name means now

A declaration says which layouts it emits and which one its bare name is. That is
what this plan needs, and it did not exist when the plan was written:

```julia
@document ImmutableCell [DC] struct Filler …    # bare name = the immutable value
@native_document struct Packet …                # bare name = the plain mutable struct
```

`[DC]` binds the bare name to the default spelling, so `Filler(64)` builds an
immutable document and every existing call site keeps its spelling. `StyleText`
is the worked example and now reads:

```julia
@document ImmutableCell [DC] struct StyleText
    font::StyleFont
    color::StyleColor
    selection::Nothing
end
```

Measured for a leaf of that shape:

```
bare name builds  : ACPFiller{ImmutableCell{Int64}, ImmutableCell{UInt8}, ImmutableCell{Nothing}}
isbitstype        : true          ← still inlines, as the plain struct did
write is refused  : MethodError   ← immutability preserved
copy_document     : round-trips immutable, and gives a real reactive copy
sync + invalidate : a reader goes stale on a change and stays valid on a no-op
```

So §4's whole immutable column is proven: a chunk leaf becomes a document at no
run-time cost and without weakening its immutability.

### 3.2 The reactive envelope is the expensive one

The instinct in §3.1 below is right about chunks and wrong about the envelope.
Measured, one million accesses each:

| layout | 1M reads | 1M writes |
| --- | --- | --- |
| native / plain mutable struct | 16 bytes | 16 bytes |
| reactive cell | 16 000 000 bytes | 15 991 824 bytes |

**A reactive field access allocates 16 bytes.** That is the dependency
bookkeeping, and it is what makes a write invalidate a reader. Allocations count
exactly, so this is not a flaky wall-clock ratio.

And the injected `selection` field costs more than it looks:

| | isbits | sizeof |
| --- | --- | --- |
| chunk leaf, injected selection | **false** | 24 |
| chunk leaf, `selection::Nothing` | **true** | 16 |
| envelope, injected selection | — | 24 |
| envelope, `selection::Nothing` | — | 16 |

The injected field is `Union{Nothing, Reference, SelectionDocument}`, a union over
heap types, and a struct carrying it cannot be isbits. A chunk with it stops
inlining into its parent and becomes a heap object — the opposite of what R1 and
structural sharing are for. So every hot-path type declares `selection::Nothing`
by hand.

A simulation moves millions of packets, and `pushfirst!`, `trim!` and `peek`
touch envelope fields on every hop. **The hot path must not get slower**, so the
envelope the simulation holds cannot be reactive.

### 3.3 The arithmetic that matters

The instinct is that selectable chunks will cost the simulation allocations.
Check it before believing it: `Sequence.chunks` is a `Vector{Chunk}`, an
**abstract** element type, so every chunk already sits behind a pointer the
moment it enters a sequence. A `Filler` in a packet is a heap object today.

So the real question is only about values that never enter a sequence — a header
peeked in a hot loop, a `Filler` in a local. Phase 0 measures it rather than
guessing, and the answer decides §4's `selection` column, not the other way
round.

R1 is safe either way. "A 1500-byte payload costs one integer" is about not
materialising bytes, and a `Filler` holds a length whether or not it is isbits.

## 4. Type by type

The recommendation, to be confirmed by the phase 0 measurement.

| type | kind | selection | why |
| --- | --- | --- | --- |
| `Filler` | immutable | `::Nothing` | isbits or nothing: the injected field takes it to 24 bytes on the heap |
| `Raw` | immutable | `::Nothing` | the same |
| `Slice` | immutable | `::Nothing` | the same; and see §5.1 — it loses its type parameter |
| `Sequence` | immutable | `::Nothing` | the same |
| `MarkedFields` | immutable | `::Nothing` | the same; and see §5.1 |
| every `@header` type | immutable | `::Nothing` | a header is peeked in a hot loop |
| `Packet` | **native** | `::Nothing` | reactive costs 16 bytes per access; the field costs 8 per packet |
| `BitLength`, `Quality` | — | — | stay plain values, like a number. A reference names the field that holds one |
| `TagSet`, `RegionTagSet` | mutable | yes | phase 5; they are dictionaries and want their own shape |

The chunks are immutable-kind because they are immutable by design: structural
sharing is what makes `dup` O(1), and a read-only cell states that in the type.

### 4.2 What no selection field costs

A type with `selection::Nothing` is a **value**: it can be read, navigated,
copied and drawn, but it cannot *hold* a selection. Nothing in the packet tree
can, because every type in it is on the hot path.

That does not stop a reference from *naming* a place inside a packet —
`pk.content.chunks[2].ttl` is still a path, and §1.3's wall still comes down.
What it stops is the packet tree storing "what is selected inside me". That state
has to live in the document that **holds** the packet: a diagram, a page, or
whatever the editor opens the packet from. `StyleText` is the precedent — a value
document, not selectable, and a projection maps a click to the field that holds
one.

This wants deciding before phase 6, because §1's promise that "an edit crosses
the first stage" now depends on the holder's selection rather than the packet's.
It is the same shape as `StyleText`, so it is a known problem, not a new one.

**And it has a fix, in `projectured-julia`, for later.** Let the injected
selection's *type* follow the variant's cell kind rather than the schema:

| variant | `selection` |
| --- | --- |
| `RCFoo`, reactive | `Union{Nothing, Reference}` — selectable, as today |
| `ICFoo`, `MCFoo`, `MFoo` | `Nothing` — zero size, isbits preserved |

The field stays in every variant, so its position never moves and
`copy_document`, `sync_document!` and `_declared_value_types` are untouched —
they walk positions. Only the declared type differs. Both halves are already
measured: `selection::Nothing` keeps a leaf isbits at 16 bytes, and a reactive
variant is selectable by default.

Then the editor's reactive copy of a packet is selectable while the simulation's
native one is not, no schema declares `selection::Nothing` by hand, and §4.2
stops costing anything. The rule must key on the **kind**, not the layout:
`ICFoo` is a cell layout and must stay isbits.

This belongs to `projectured-julia` on its own terms, not to this plan. Written
down here because it is what would retire §4.2.

### 4.1 The envelope: what the measurement forces

The row above said **reactive**, so that `pushfirst!` would invalidate whatever
read it. §3.2 measured what that costs: 16 bytes per field access, on a struct
the simulator touches on every hop. That is not affordable, and the hot path is
not negotiable.

So the envelope is `@native_document`: the bare name is the plain `mutable
struct` it already is, byte for byte, and `ACPacket` is the cell layout an editor
holds. Three of §1's four workarounds still go away, because a native document is
still a `Document`:

| §1 | goes away with a native envelope? |
| --- | --- |
| 1. a page cannot splice a packet | **yes** — a card renders any `Document` |
| 2. a packet cannot announce a change | **no** — a native envelope holds no cells |
| 3. no edit crosses the first stage | **yes** — a reference names a schema, not a layout |
| 4. `dissect` describes what cannot describe itself | **yes** — a native document is walkable |

Only the second needs cells, and it is the one the editor gets by holding
`copy_document(ReactiveCell, pk)` and syncing. That is a shadow, which §11
rejected — but §11 rejected a shadow of a *foreign* object that must be kept in
step by hand. This one is `sync_document!`, one generic call, and it is what
every other observed simulation object in these repositories already does.

**Open, and Phase 0 decides it.** If the envelope turns out *not* to be on the
hot path — if `pushfirst!` and `trim!` run once per hop rather than per event,
and 16 bytes there is affordable — then the reactive envelope buys observability
with no shadow at all, and §1.2 goes away too. Phase 0 must count envelope field
accesses per simulated event before this is settled either way.

## 5. Two constraints in the macro

### 5.1 `@document` does not take type parameters

`cell_struct_plan` reads the struct name as `name_expr.args[1]` and then builds
`Expr(:curly, plan.name, …)` for the cell parameters. A name that is already a
`curly` — `Slice{C<:Chunk}` — produces `Slice{C}{C1,C2}`, which is not a type.
No `@document struct Foo{…}` exists anywhere in `projectured-julia`.

Two types are parametric today:

```julia
struct Slice{C<:Chunk} <: Chunk       # chunk::C, offset, length
struct MarkedFields{H<:Fields} <: Chunk   # header::H, quality
```

**Drop both parameters and let the smart constructor type the cell.** The cell
layout already carries one type parameter per field, and that parameter recovers
exactly what `Slice{C}` gave you — measured:

```
plain Slice{Filler}, today                          isbits=true   sizeof=24
plain Slice, parameter dropped                      isbits=false  sizeof=16
ACSlice{ImmutableCell{Chunk}, …}   bare ctor        isbits=false  sizeof=16
ACSlice{ImmutableCell{ACFiller{…}}, …} typed cell   isbits=true   sizeof=24
```

The last row is byte-identical to the first. `ACSlice{ImmutableCell{ACFiller{…}}, …}`
**is** `Slice{Filler}`, with a cell wrapper around each field.

The difference between the two middle rows is only how the value was wrapped. The
bare constructor wraps a raw value in its *declared* type, `ImmutableCell{Chunk}`,
which is abstract. The smart constructor wraps it in the value's own type instead:

```julia
slice(chunk, offset) = Slice(ImmutableCell{typeof(chunk)}(chunk), offset, nothing)
```

That is one line, in the place the chunk model already reserves for building a
composite, and it needs no change to `@document`.

What is genuinely lost is the two places the parameter was used —
`_try_merge(a::Slice{C}, b::Slice{C})` and the peek that hands a `MarkedFields`
back as its header type. Both already compare `a.chunk === b.chunk` or dispatch on
the value.

**One caveat, measured.** A *kind-converting* copy widens the cell back to the
declared type:

```
copy_document(slice)                 isbits=true   sizeof=24    ← kind-preserving keeps it
copy_document(ImmutableCell, slice)  isbits=false  sizeof=16    ← widens to ImmutableCell{Chunk}
```

`_kinded_value_type` prefers the declared type when the value conforms to it. That
lands on the editor side — `_pure_snapshot` is such a call — and not on the hot
path, which builds through the smart constructor. Check in phase 2 that no hot
path calls the kinded form; `dup` is the one to look at, and it shares content
rather than copying it.

Measured, so the failure mode is known rather than guessed:

```
@document ImmutableCell [DC] struct PSlice{C <: PChunk} <: PChunk
REFUSED : MethodError: Cannot `convert` an object of type Expr to an object of type Symbol
```

It does not degrade quietly — it fails to parse, at the declaration.

Warning: do not extend `@document` to carry type parameters as part of this
plan. `CellStructPlan.jl`, `CellStruct.jl` and `CellStructModule.jl` are
**sealed** in `projectured-julia`. `DocumentMacro.jl` is no longer sealed, but it
is unsealed pending review of a different change, and riding a second one in
would make that review harder rather than easier. Extending the macro is a
separate, deliberate change on `projectured-julia`'s own terms.

### 5.2 A sequence's children want to be a collection

`Sequence.chunks::Vector{Chunk}` is the tree an inspector walks, so it should be
a `CellVector` — a change to the smart constructors in
[`Chunk.jl`](../../package/packet/main/Chunk.jl), which are the only way a
`Sequence` is built and so the only place to change.

`offsets` is a derived cache of cumulative bit offsets. Keep it a plain vector
built by the same constructor: it is not structure a reader navigates, and
making it a collection would put a caret in a number nobody edits.

## 6. What `@header` emits

One line changes in the macro, and every declared header follows:

```julia
Base.@__doc__ @document ImmutableCell [DC] struct $(name) <: $(M).Fields
    $(struct_fields...)
end
```

Everything else the macro emits is unchanged — `chunk_length`, `serialize`,
`deserialize`, `header_layout`, the keyword constructor, `show`.

Two consequences to handle in the same phase:

- `@document` generates its own constructors, and `@header` generates a keyword
  constructor of its own. Check they do not collide; `@document`'s keyword form
  may already be what the header wants, in which case `@header` stops emitting
  one. Do not let two methods of the same signature meet — a method overwrite is
  fatal at precompile time.
- A header's fields are read through `getproperty` now. `h.ttl` still works; a
  `getfield(h, :ttl)` anywhere reads the **cell**, not the value.
  `field_bits(h, spec)` in [`HeaderLayout.jl`](../../package/packet/main/HeaderLayout.jl)
  uses `getfield` and must change to `getproperty`.

## 7. What retires

- `refresh_packet_diagram!` and the announcement rule of §8.3 — a write to a
  packet's cell invalidates what read it.
- The `packet` back-pointer field on `PacketDiagram`, and with it the
  `ComputedCellVector` over a packet cell. The diagram becomes an ordinary
  projection output over a reactive input.
- `packet_diagram_document_entry` and the two-entry table: a page splices the
  packet again, and `Packet => …` is the only entry needed.
- The `marker_packet` conversion in
  [`Packets.jl`](../../package/inet/example/Packets.jl).
- `dissect` **may** retire. It is the tree view's source today, and a document
  tree is walkable by the generic machinery, so `packet_syntax` could project
  the packet directly. Decide in phase 6, with the demo page as the evidence:
  `dissect` also carries labels and quality that a generic walk would not
  produce.

## 8. Staged build

Work in a git worktree, created as a **sibling** of `inet-julia`. Commit at the
end of each phase and mark it here.

### Phase 0 — measure first — **DONE**

Scripts: `packet-phase0.jl` and `packet-phase0b.jl`, beside this file. Re-run them
at the end to fill the right-hand column of every table.

**isbits, as things are today.**

| type | isbits | sizeof |
| --- | --- | --- |
| `Filler` | **true** | 16 |
| `Slice{Filler}` | **true** | 32 |
| `Raw` | false | — (holds a `Vector`) |
| `Sequence` | false | — (holds a `Vector`) |
| `Packet` | false | — (mutable) |

Only `Filler` and `Slice` are isbits, and those two are what §5.1 is about. `Raw`
and `Sequence` hold vectors and are heap objects already, so the injected
selection would cost them nothing — but they take `selection::Nothing` anyway,
for one rule rather than two.

**Hot paths, allocations per call.**

| | bytes/call |
| --- | --- |
| `build_ethernet_frame` | 1216 |
| `dup(frame)` | 176 |

**A whole T1S run, 200 µs.**

| scenario | allocations | envelope reads | writes | total accesses |
| --- | --- | --- | --- | --- |
| `notraffic` | 508 688 | 0 | 0 | 0 |
| `bestcase` | 370 432 | 1371 | 160 | **1531** |

The counts are measured, not estimated: `packet-phase0b.jl` gives `Packet` a
temporary `getproperty`/`setproperty!` pair that tallies. That pair lives in the
script and is never committed to the package.

**Open question 0, answered: 6.6 %.** At 16 bytes an access, a reactive envelope
would add 24 496 bytes to a `bestcase` run that allocates 370 432 — **6.6 % more
allocation**, and nothing at all on a run that carries no packets.

So the envelope is not heavily on the hot path, and the microbenchmark of §3.2
overstated the case in isolation. It changes nothing: **the envelope is native**,
and 6.6 % is recorded so that nobody re-opens this having only seen §3.2's
larger-looking number. The rule is not a budget.

### Phase 0 — what it asked for — **DONE**

- [ ] Record the allocation count and time of the hot paths as they are today:
      `build_ethernet_frame`, `peek(pk, Ipv4Header)`, `pushfirst!`, `dup`, and
      one full T1S `bestcase` run.
- [ ] Record `isbits` for every chunk type.
- [ ] **Count envelope field accesses per simulated event.** This is what decides
      §4.1: at 16 bytes each, a reactive envelope is affordable only if the count
      is small. Nothing else settles it.
- [ ] Write the numbers into this plan.

Gate: none. This is the baseline every later phase is compared against, and it
is worthless if it is taken after the change.

Beware a folded loop. A microbenchmark of a plain struct whose result is unused
optimises away completely and reports zero — an earlier attempt at the §3.2
numbers printed 0.0000 s for two million iterations before the objects were put
somewhere the compiler could not see through. Measure allocations, keep the
result, and disbelieve a zero.

### Phase 1 — the chunk leaves — **DONE**

`InetPacket` gained its one dependency, `Chunk` became `<: Document`, and
`Filler` and `Raw` became `@document ImmutableCell [DC] struct` with
`selection::Nothing`.

The hot path did not move:

| | phase 0 | after phase 1 |
| --- | --- | --- |
| `Filler` isbits / sizeof | true / 16 | **true / 16** |
| `build_ethernet_frame` | 1216 bytes | **1216 bytes** |
| `dup(frame)` | 176 bytes | **176 bytes** |

`test_packet()` 1892 / 1892.

Two things went right that were worth checking. Both leaves keep their
hand-written keyword constructors — `Filler(len; fill, quality)` takes one
positional argument, and the macro's keyword form is zero-positional and is
gated on a programmer-declared default, which neither leaf has. And Rule Y emits
only the arity that fills the injected `selection`, so `Filler(len, fill, qual)`
still resolves to the same three-argument call every site already writes.

`Pkg.resolve()` is needed after adding the dependency; without it the package
loads against a manifest that does not know about the edge.

### Phase 1 — what it asked for — **DONE**

- [ ] `Filler` and `Raw` become `@document ImmutableCell [DC] struct`, so the
      bare name stays the immutable value every call site already builds.
- [ ] Fix every construction site and the smart constructors.
- [ ] `test_packet()` passes; `Filler` still holds a length rather than bytes.

### Phase 2 — the composites — **PENDING**

- [ ] `Slice` and `MarkedFields` lose their type parameters and become
      documents. The `slice` smart constructor wraps its chunk in
      `ImmutableCell{typeof(chunk)}`, which is what keeps them isbits (§5.1).
- [ ] Check that no hot path calls `copy_document(K, ·)` on a chunk, which would
      widen the cell back to the declared type.
- [ ] `Sequence` becomes a document whose `chunks` is a `CellVector`.
- [ ] The smart constructors keep every normalisation rule they enforce today:
      no slice-of-slice, no sequence-in-sequence, no singleton, no adjacent
      mergeables.

Gate: the normalisation tests of `phase1_chunks.jl` pass unchanged. They are the
specification of the composites, and this phase must not touch them.

### Phase 3 — the headers — **PENDING**

- [ ] `@header` emits `@document ImmutableCell [DC] struct`.
- [ ] Resolve the constructor overlap of §6.
- [ ] `field_bits` reads through `getproperty`.

Gate: the golden byte vectors of `phase9_protocol_headers.jl` are unchanged. A
header's wire form has nothing to do with how the struct stores its fields, and
a changed byte means the codec was disturbed.

### Phase 4 — the envelope — **PENDING**

- [ ] `Packet` becomes `@native_document struct` — the bare name is the plain
      mutable struct it already is.
- [ ] `dup` stays O(1): a fresh envelope pointing at the same content.
- [ ] `pushfirst!`, `push!`, `popfirst!`, `trim!` write cells.

Gate: `test_packet()`, `test_queuing()` and `test_linklayer()` pass, and the T1S
`notraffic` and `bestcase` hash pins reproduce bit for bit.

### Phase 5 — the tags — **PENDING**

- [ ] `TagSet` and `RegionTagSet` become documents.

They are keyed collections rather than trees, so they may want a shape of their
own. This phase may be deferred without blocking the rest; a packet whose tags
are plain values is still navigable everywhere else.

### Phase 6 — the diagram, simplified — **PENDING**

- [ ] Delete the `packet` back-pointer, `refresh_packet_diagram!` and the
      document entry; the marker splices the packet again.
- [ ] `map_reference_backward` names a place inside the packet, so the wall of
      §8.4 comes down.
- [ ] Decide `dissect`'s fate (§7) with the demo page as the evidence.
- [ ] The demo page's prose says what is true again: nothing converts the packet.

Gate: the golden figure `packetdiagram-figure.txt` is unchanged. The figure is
drawn from `header_layout`, which this plan does not touch, so a changed
character means something else moved.

### Phase 7 — what the packet can now do — **PENDING**

- [ ] A test that opens a live packet in an inspector and walks it.
- [ ] A test that a reference names a header field and evaluates to its value.
- [ ] A test that writing a field through the reference changes the packet, and
      that a projection over it re-renders.

This phase is the reason for the whole plan. Without it the change is a
refactor; with it, observability is a runnable check.

### Phase 8 — documentation and the seal list — **PENDING**

- [ ] Rewrite the requirement (§2) and the architecture table.
- [ ] Rewrite the `packet.md` sections that say a chunk is a plain struct.
- [ ] Say in `packet-diagram.md` what came down.
- [ ] Move this plan to `plan/done/`.

## 9. Gates, in one place

| what | how |
| --- | --- |
| behaviour unchanged | the T1S `notraffic` and `bestcase` hash pins reproduce |
| the wire unchanged | the golden byte vectors of `phase9_protocol_headers.jl` |
| the figure unchanged | `packetdiagram-figure.txt`, character for character |
| the cost understood | the phase 0 numbers, re-measured at the end and written down |
| the composites unchanged | `phase1_chunks.jl` passes without edits |
| **the hot path is not slower** | **allocations per event, against the phase 0 baseline, must not rise** |

The hot path gate is the hard one. A packet is touched on every hop of every
event, and this plan is not worth a slower simulation. Allocations are the
measure: they count exactly, and a reactive access allocates while a native or
immutable one does not, so the number moves if and only if something went onto
the hot path that should not have.

Do not gate on wall-clock time. A ratio assertion under load flakes, and what
this plan can actually change is allocations, which count exactly.

## 10. Open questions

0. ~~**Is the envelope on the hot path?**~~ **Closed, and it does not matter.**
   Phase 0 counted 1531 envelope accesses in a `bestcase` run, which a reactive
   envelope would make 6.6 % more expensive. The rule is that nothing on the hot
   path is reactive, so the envelope is native regardless of the share. The
   number is kept only so the question is not asked again.
1. **Does a header stay cheap enough?** Phase 0 answers it. If a selectable
   header costs an allocation the simulation cannot afford, the fallback is
   `selection::Nothing` on headers only: the figure then maps a click through
   the diagram document rather than into the packet, which is what it does
   today.
2. **Does `Sequence` want a `CellVector` or a `ListNode`?** A rope is a list;
   the collection layer has both, and the packet's own access pattern is binary
   search over cumulative offsets, which favours the vector.
3. **Does `dissect` survive?** §7.
4. **Do the queuing elements notice?** They hold packets and move them between
   gates. A reactive envelope means a write invalidates readers — check that no
   element reads a packet inside a cell it did not mean to make reactive.

## 11. Rejected alternatives

**A document mirror of the packet.** What exists today: `PacketDiagram` holds
the packet in a field and derives bands from it. It works, and it is a second
description of the same thing — which is the defect this repository's own
`@header` exists to remove, reintroduced one layer up.

**Reflection into a bounded shadow.** `reflect_document` plus `sync_reflection!`
would make any packet inspectable with no change to `InetPacket` at all. It is
the right tool for a foreign object — a C++ handle, a live engine — and the
wrong one here: a packet is ours, and a shadow that must be synced is a cache
with an invalidation problem, not a document.

**Teaching `@document` type parameters.** It would keep `Slice{C}` concrete —
and it turns out to be unnecessary for that, because the cell layout already has a
parameter per field and a typed cell recovers isbits exactly (§5.1). Two of the
four files are still sealed. If the parameter is ever wanted for its own sake
rather than for concreteness, the change belongs to `projectured-julia` on its own
terms rather than as a rider on this plan.

**A reactive envelope regardless.** Rejected by rule. A reactive field access
allocates 16 bytes on a struct the simulation touches, and nothing the simulation
touches is reactive. Phase 0 measured the share at 6.6 % of a `bestcase` run;
that is recorded as a fact, not as a threshold to argue against.
