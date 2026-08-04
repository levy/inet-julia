# Requirements — the network model library

Accepted, user-level requirements for `inet-julia`: what the library must let a
network modeller do, stated as observable capabilities, not as implementation.
The library is the successor of the C++ INET framework, built on the successor
simulator; the simulator's own requirements
(`../omnetpp-julia/documentation/requirements.md`, `OR-…`) bind everything here
transitively — a network model is an ordinary simulation model, so everything
the simulator promises (determinism, live documents, observation that costs
nothing when off, …) is promised for network models too. This document adds
only what is specific to the network-modelling layer.

For the internal invariants and conventions the *code* must respect, see
[architecture-requirements.md](architecture-requirements.md).

Each requirement has a permanent ID (`IR-…`). An ID names the requirement, not
its position: it is never reused, it survives regrouping and rewording, and it
is its own heading, so it can be cited as
[IR-FAITHFUL-PROTOCOLS](requirements.md#ir-faithful-protocols). The prose never
cites IDs inline; the Index below is the one table of contents.

## How to read a requirement

Each requirement opens with the rule itself in bold, then optionally: **Why.**
the consequence at stake, **In INET.** what the C++ incumbent does today,
**Problem.** the failure mode that creates, and **Better.** the capability the
successor delivers.

## Terminology

- **Chunk** — one contiguous piece of packet content in some representation
  (declared fields, raw bits, a slice of another chunk, a concatenation).
- **Packet** — the unit of traffic: a sequence of chunks plus attached
  metadata, with front/back popped regions.
- **Header** — a chunk type declared once by its fields, with encoding and
  decoding derived from the declaration.
- **Element** — one queuing building block (source, sink, queue, server,
  classifier, scheduler, filter, …) speaking the packet protocol.
- **Protocol model** — a faithful model of a standardized protocol (today:
  10BASE-T1S with PLCA), packaged with its own model wrapper.
- **Stack** — the composition of protocol modules a packet traverses in one
  node.
- **Seam** — a declared hand-off point between modules where communication can
  be observed.
- **Machine** — a protocol state machine, as data: states, events, guards,
  transitions, actions.

## Index

### Fidelity

| ID | Requirement |
| --- | --- |
| [IR-FAITHFUL-PROTOCOLS](#ir-faithful-protocols) | Protocol behaviour follows the standard's own structure |
| [IR-CROSS-VALIDATED](#ir-cross-validated) | Every protocol model is checkable against the C++ incumbent |

### Packets

| ID | Requirement |
| --- | --- |
| [IR-ANY-REPRESENTATION](#ir-any-representation) | Packet content is readable in the representation the question needs |
| [IR-DECLARED-HEADERS](#ir-declared-headers) | A header is declared once; its codecs are derived |
| [IR-IMPERFECTION-REPRESENTABLE](#ir-imperfection-representable) | Incomplete, incorrect and improper content is representable and tracked |
| [IR-TAGS-TRAVEL](#ir-tags-travel) | Metadata attaches to bit ranges and survives packet surgery |

### Composition and expression

| ID | Requirement |
| --- | --- |
| [IR-ELEMENTS-COMPOSE](#ir-elements-compose) | Elements compose into compound modules |
| [IR-NATIVE-EXPRESSION](#ir-native-expression) | Models, parameters and statistics are ordinary Julia |

### Observation

| ID | Requirement |
| --- | --- |
| [IR-OBSERVABLE-STACKS](#ir-observable-stacks) | Traffic is observable at every seam, in standard formats, at zero cost when off |
| [IR-LIVE-STATE-MACHINES](#ir-live-state-machines) | A protocol's state machine is watchable while the simulation runs |

### Documents

| ID | Requirement |
| --- | --- |
| [IR-MACHINES-ARE-DOCUMENTS](#ir-machines-are-documents) | State machines are documents; the runnable code is generated |
| [IR-TUTORIAL-IS-LIVE](#ir-tutorial-is-live) | A tutorial is a navigable document whose examples run in place |

## Fidelity

### IR-FAITHFUL-PROTOCOLS

**Protocol behaviour follows the standard's own structure.** A protocol model's
states, transitions, timers and timing constants mirror the defining document —
for 10BASE-T1S, the PLCA control, PLCA data and MAC machines of IEEE 802.3cg —
closely enough that a reviewer can hold the code against the clause and check
them off one by one.

**Why.** A network model earns trust by being checkable against something
outside itself. When the model's shape matches the standard's shape, every
divergence is visible; when the model is a free re-interpretation, divergences
hide in the translation.

**In INET.** Protocol modules implement the standards faithfully, but the state
machines live inside hand-written C++ methods, interleaved with framework
mechanics (message bookkeeping, signal emission, lifecycle plumbing), so
checking code against clause means reading past the accidents.

**Better.** The machine is separated from the mechanics: protocol-defined
states, transitions and timing survive verbatim; what gets dropped is only the
incumbent's implementation accidents. The reviewer reads the machine, not the
plumbing.

### IR-CROSS-VALIDATED

**Every protocol model is checkable against the C++ incumbent.** The library
must be able to produce the same result artifacts the incumbent produces —
vector files in the same format, the same named statistics — and carry a
comparison harness that checks them against INET reference outputs and against
closed-form analytical values, so agreement is a runnable check, not a claim.

**Why.** "Faithful" is only as strong as its test. A model whose numbers can be
laid beside the incumbent's, sample by sample, keeps its fidelity as it evolves;
one that cannot has fidelity only by assertion.

**In INET.** Regression is guarded by fingerprint tests — a hash over event
trails — which detect that something changed but say little about what, and
nothing an outside implementation can compare against.

**Better.** Cross-implementation comparison at the level of recorded vectors
and scalars: byte-exact where exactness is defined, tolerance-based where it is
not, plus analytical pins (a cycle length computable from the standard's
constants) that hold with no reference files at all.

## Packets

### IR-ANY-REPRESENTATION

**Packet content is readable in the representation the question needs.** The
same bytes on the wire must be viewable as declared header fields, as raw bits,
as a slice of a larger whole, or as a concatenation of parts — and a reader
asking for one representation must get it regardless of which representation
the writer used, with conversion happening implicitly.

**Why.** A protocol stack is precisely a disagreement about representation: the
application wrote fields, the MAC sees a payload blob, the sniffer sees bits. If
representations do not convert freely, every module pair needs a bilateral
agreement, and models stop composing.

**In INET.** This is the Chunk API's central achievement — fields chunks, bytes
chunks, bit chunks, slices and sequences, with serializers bridging them — and
it is kept, redesigned on Julia's type system rather than transliterated from
the C++ class hierarchy.

### IR-DECLARED-HEADERS

**A header is declared once; its codecs are derived.** Declaring a header type
— its fields, widths and order — must be sufficient: encoding to bits and
decoding from bits are derived from the declaration, never written by hand.

**Why.** Hand-written codec pairs drift: the writer and reader each encode the
layout separately, and the bug appears only when a foreign implementation reads
the bytes.

**In INET.** Message types are declared in `.msg` files compiled by a dedicated
message compiler into C++ classes, with serializers registered separately —
declaration and codec are related by convention, in two languages, through a
build step.

**Better.** The declaration is ordinary Julia, the derivation is immediate (no
build step, per the substrate's requirements), and declaration and codec cannot
disagree because one is computed from the other.

### IR-IMPERFECTION-REPRESENTABLE

**Incomplete, incorrect and improper content is representable and tracked.** A
packet that was truncated, corrupted, or read in a representation that cannot
carry all its meaning must still be a first-class value, and the imperfection
must travel with it — every derived chunk knows whether it is complete, correct
and properly represented.

**Why.** Networks are interesting exactly where packets go wrong. A model that
can only represent perfect packets cannot model loss, corruption or truncation
honestly — it must either crash or lie.

**In INET.** The chunk API tracks completeness, correctness and proper
representation as flags that propagate through peeking and slicing; the
successor keeps this quality lattice.

### IR-TAGS-TRAVEL

**Metadata attaches to bit ranges and survives packet surgery.** Information
*about* content — which protocol produced it, what flow it belongs to, when it
was created — attaches to regions of the packet, and stays attached, correctly
re-ranged, as the packet is sliced, merged, encapsulated and decapsulated.

**Why.** Every interesting cross-layer question (which application's bytes are
in this fragment? what is this frame's end-to-end latency?) is a question about
metadata surviving representation changes. If tags are lost at each boundary,
those questions become unanswerable.

**In INET.** Packet tags and region tags exist and are threaded through the
protocol stack; the successor keeps the mechanism with a single unified
region-tag model.

## Composition and expression

### IR-ELEMENTS-COMPOSE

**Elements compose into compound modules.** The element library — sources,
sinks, queues, servers, classifiers, schedulers, filters — must compose
arbitrarily: any active output connects to any passive input, push and pull
sides pair freely, and a composition (a priority queue built from a classifier,
queues and a scheduler) is itself an element usable anywhere an element is.

**Why.** The value of an element library is combinatorial. If composition needs
per-pair glue, the library is a list of examples, not an algebra.

**In INET.** The queueing package establishes exactly this algebra (active and
passive sources and sinks over declared module interfaces), and its tutorial
walks it in about fifty steps; the successor's element library reproduces the
semantics with the same compositional reach.

### IR-NATIVE-EXPRESSION

**Models, parameters and statistics are ordinary Julia.** Building a network
model, assigning its parameters (including volatile ones re-evaluated per
read), classifying packets, and defining what to record must all be written in
the host language — values, functions and expressions — with no embedded
configuration or declaration language in between.

**Why.** Every embedded mini-language taxes each capability twice: it must be
implemented, and its users must learn where it ends and the host language
begins. The substrate already promises the host language works as the
expression syntax; the network library must not reintroduce a DSL on top.

**In INET.** Structure lives in NED, parameters in ini files with their own
expression dialect, statistics in `@signal`/`@statistic` annotations — three
languages before the first line of C++.

**Better.** A packet filter is a Julia predicate; a service-time distribution
is a Julia closure; a recorded statistic is a Julia expression over the model's
own values.

## Observation

### IR-OBSERVABLE-STACKS

**Traffic is observable at every seam, in standard formats, at zero cost when
off.** Any declared hand-off point in any stack must be attachable for capture
— per node, per layer, per direction — without modifying protocol code, with no
cost when nothing is attached, and the captured traffic must export to standard
capture formats readable by standard tools.

**Why.** This is the network instantiation of the substrate's
observable-communication requirement: the modeller debugging a protocol wants
to see frames where they cross boundaries, with tools she already knows.

**In INET.** A dedicated recorder module writes pcap files, but it is a module
the model author must place and wire into the network description ahead of
time; observation is a modelling decision, not an inspection one.

**Better.** Observation attaches to the seams the stack already declares, at
preparation time, from outside the model — and a capture opened in a standard
packet analyzer just works.

### IR-LIVE-STATE-MACHINES

**A protocol's state machine is watchable while the simulation runs.** For any
machine in the model, the modeller must be able to open a live view — the state
diagram with the current state and last transition highlighted, transition
counts accumulating — while the simulation executes, without perturbing it.

**Why.** A protocol bug is almost always a story about a machine taking an
unexpected transition. Watching the machine run answers in seconds what log
archaeology answers in hours.

**In INET.** State is a member variable; watching it means logging it. The
graphical runtime animates messages, not protocol state structure.

**Better.** The machine is a document and the diagram is a projection of it, so
the live view is the same artifact as the specification — one thing, two
moments.

## Documents

### IR-MACHINES-ARE-DOCUMENTS

**State machines are documents; the runnable code is generated.** A protocol
state machine exists as a structured document — states, events, guards,
transitions, actions — that can be viewed as a diagram, edited as notation, and
compiled to the runnable Julia module the simulation executes. The generated
code is never edited by hand: change the machine, regenerate, and behaviour
pins (golden hashes) must come out unchanged when the change was intended to be
behaviour-preserving.

**Why.** A machine that exists only as code can be read; a machine that exists
as data can be reviewed against the standard, diagrammed, diffed, watched live
and regenerated. This is the everything-is-a-document requirement of the
substrate applied to protocol logic.

**In INET.** The machines exist as prose in the standard and as hand-written
switch statements in C++ — two artifacts, related by careful reading, drifting
independently.

**Better.** One machine document per protocol machine (today: the T1S MAC and
both PLCA machines), one generator, and a provenance header in every generated
file that says where it came from.

### IR-TUTORIAL-IS-LIVE

**A tutorial is a navigable document whose examples run in place.** Learning
material is a first-class document: prose pages with embedded models that are
not screenshots but the real thing — configurable through a form, runnable in
place, with live progress, statistics and topology, and with the diagram
derived from the model rather than drawn beside it.

**Why.** A tutorial teaches a dynamic system; static prose about a dynamic
system makes the reader simulate it in her head, which is exactly the job the
simulator exists to do.

**In INET.** Tutorials are generated web pages: prose, NED excerpts and static
figures, with the runnable configuration in separate files the reader must run
in a separate tool.

**Better.** The queueing tutorial's steps are pages of one navigable document;
each step embeds its model, its parameters and its results, live; and the
figures cannot lie about the model, because they are projections of it.
