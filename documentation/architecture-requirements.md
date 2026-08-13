# Architecture requirements — the network model library

The internal invariants and conventions the `inet-julia` code must respect:
rules that break silently when violated, stated so an audit can check them file
by file. For what the library must let a user *do*, see
[requirements.md](requirements.md) (`IR-…` IDs). For the package graph and the
rule for where new material belongs, see [architecture.md](architecture.md).

Two upstream documents bind transitively and are not restated here:

- the simulator's architecture requirements — `OAR-…` in
  `../omnetpp-julia/documentation/architecture-requirements.md`. Every protocol
  model runs on the event path of that engine, so its determinism, event-path
  and observation rules apply to code in this repository verbatim.
- the ProjecturEd architecture requirements — `PAR-…` in
  `../projectured-julia/documentation/architecture-requirements.md`. The
  package/layer/slice/module division, naming, import and docstring disciplines
  apply to this repository as to any repository in the family.

This document adds only what is specific to the network-model layer. Each rule
has a permanent ID (`IAR-…`): never reused, names the rule not its section, and
is its own heading, so it can be cited as
[IAR-EDIT-THE-MACHINE](architecture-requirements.md#iar-edit-the-machine).

**A prefix names the repository that owns the rule**, so a citation says which
document to open without a link:

| repository | product | architectural |
| --- | --- | --- |
| projectured-julia | `PR-` | `PAR-` |
| omnetpp-julia | `OR-` | `OAR-` |
| **inet-julia** | **`IR-`** | **`IAR-`** |

## Index

### Packages and placement

| ID | Rule |
| --- | --- |
| [IAR-ONE-WAY-KERNEL-DEP](#iar-one-way-kernel-dep) | The library depends on the simulator; the simulator never depends back |
| [IAR-PACKET-DEPENDS-ON-THE-DOCUMENT-SUBSTRATE](#iar-packet-depends-on-the-document-substrate) | `InetPacket` depends on the document substrate and nothing else |
| [IAR-LOWEST-PACKAGE](#iar-lowest-package) | New material sinks to the lowest package; a package is earned, not convenient |
| [IAR-COMMON-IS-NEUTRAL](#iar-common-is-neutral) | `common` holds only infrastructure independent of what it serves |
| [IAR-ACYCLIC-GROWTH](#iar-acyclic-growth) | The package graph grows edges only while staying a DAG |

### Element and protocol conventions

| ID | Rule |
| --- | --- |
| [IAR-CONTRACT-BY-GENERICS](#iar-contract-by-generics) | The packet protocol is a generic-function vocabulary, not a type hierarchy |
| [IAR-DERIVE-DONT-TRANSLITERATE](#iar-derive-dont-transliterate) | Derive from INET; keep the standard verbatim, drop the accidents |
| [IAR-PROTOCOL-IS-A-SLICE](#iar-protocol-is-a-slice) | A protocol is a slice with its own model wrapper |

### Generated code

| ID | Rule |
| --- | --- |
| [IAR-EDIT-THE-MACHINE](#iar-edit-the-machine) | Generated files are never hand-edited |
| [IAR-GENERATOR-IS-A-TOOL](#iar-generator-is-a-tool) | Generators live in `tool/`; generated output is committed, deliberately |

### Observation and recording

| ID | Rule |
| --- | --- |
| [IAR-SEAMS-ARE-DECLARED](#iar-seams-are-declared) | Observation attaches only at declared seams, from outside the model |
| [IAR-ZERO-COST-RECORDING](#iar-zero-cost-recording) | `recorder === nothing` short-circuits; recording off costs nothing |
| [IAR-NO-SIGNAL-REGISTRY](#iar-no-signal-registry) | Statistics are direct calls, never a registry or listener architecture |

### Verification

| ID | Rule |
| --- | --- |
| [IAR-GOLDEN-HASHES](#iar-golden-hashes) | Protocol behaviour is pinned by absolute hashes |
| [IAR-INET-COMPARISON](#iar-inet-comparison) | The comparison against C++ INET stays runnable |
| [IAR-TESTS-IN-PHASES](#iar-tests-in-phases) | A package's suite is phase files mirroring the build waves |

## Packages and placement

### IAR-ONE-WAY-KERNEL-DEP

**The library depends on the simulator; the simulator never depends back.**
`Inet` packages import `OmnetppSimulator` (and `ProjecturedKernel`); nothing in
`omnetpp-julia` may name anything in this repository — not a type, not a
module, not a catalog entry. The seam points the other way: the simulator
declares open generics and this library adds methods (the module kernel in
`omnetpp-julia`'s `model/module/` is extended here, never edited from here).
This is the same split as C++ INET over OMNeT++, and it is what keeps the
simulator's own test environments runnable with no network models installed.
When the extraction happened, `T1sModel` left the simulator's
`default_simulation_catalog()` for `Inet`'s own `inet_simulation_catalog()`
(`package/inet/main/Catalog.jl`) for exactly this reason.

### IAR-PACKET-DEPENDS-ON-THE-DOCUMENT-SUBSTRATE

**`InetPacket` depends on `ProjecturedKernel` and nothing else.** No simulator,
no external packages — `package/packet/main/Project.toml` names one dependency,
and says why.

The packet and chunk API is a data model, and in this system a data model is a
**document**: its values are navigable, selectable and reactive, so an inspector,
a projection and a reference reach a live packet without a mirror of it.
`ProjecturedKernel` is the document substrate and carries no `[deps]` of its own,
so the edge adds one leaf package to the graph rather than the editor stack. The
kernel is the substrate and not the editor — cells, documents, references,
operations and the projection interface — and nothing in it opens a window.

The separate package is what makes this checkable rather than merely intended:
the resolver enforces it on every instantiation. A change that needs the
*simulator* from inside `InetPacket` is still in the wrong package.

### IAR-LOWEST-PACKAGE

**New material sinks to the lowest package; a package is earned, not
convenient.** Every piece of code lives in the lowest package of the DAG whose
API it hard-references (the upstream rule [PAR-LOWEST-PACKAGE] applied here). A
new package is earned only by a genuinely different dependency or consumer set
— it costs a `Project.toml`, a UUID and a `[sources]` entry in everything
downstream. A second protocol is a slice inside `linklayer`, not a new package;
a helper both stacks need sinks to `common` or below.

### IAR-COMMON-IS-NEUTRAL

**`common` holds only infrastructure independent of what it serves.** The
lookup mechanism (`package/common/main/lookup/`) finds the module behind a gate
without knowing what is being looked up — that neutrality is why it lives in
`common` and not in `queuing`: a future consumer (another protocol package)
must be able to use it without depending on `queuing`. Today `queuing` is its
only consumer; the placement is for the consumers it does not have yet.
Anything added to `common` must pass the same test: it may know the simulator's
vocabulary, never a protocol's.

### IAR-ACYCLIC-GROWTH

**The package graph grows edges only while staying a DAG.** Edges may be added
as models grow — `linklayer → queuing` is expected when modular Ethernet
arrives — but never an edge that closes a cycle, and never an edge from a lower
package to a higher one. The direction of every planned edge is written down in
[architecture.md](architecture.md) before it is added.

## Element and protocol conventions

### IAR-CONTRACT-BY-GENERICS

**The packet protocol is a generic-function vocabulary, not a type hierarchy.**
The roles an element can play are open generic functions —
`can_push_packet` / `push_packet!`, `can_pull_packet` / `pull_packet!` and
their families, declared bodiless in `package/queuing/main/contract/` — and an
element participates by adding methods, not by inheriting an interface type.
This is the INET module-interface idea re-expressed the Julia way: multiple
dispatch is the registration ([PAR-FRAMEWORKS-SINK]), and no
`IPassivePacketSink`-style interface classes exist to transliterate.

### IAR-DERIVE-DONT-TRANSLITERATE

**Derive from INET; keep the standard verbatim, drop the accidents.** What the
defining standard specifies — states, transitions, timers, timing constants,
statistics semantics — survives verbatim and reviewably
([IR-FAITHFUL-PROTOCOLS]). What is an accident of the C++ implementation —
interface classes that exist for the C++ type system, dead variables, message
priority tie-breaking machinery, mutability flags Julia's immutability makes
meaningless — is dropped, deliberately and with the drop recorded in the plan
that did it. The test for which side a detail falls on: would a reviewer
holding the standard miss it?

### IAR-PROTOCOL-IS-A-SLICE

**A protocol is a slice with its own model wrapper.** A protocol groups
everything about itself — frames, machines, wiring, its `AbstractModel` wrapper
(`t1s/T1sModel.jl`) — as one slice under its package (`t1s/` in `linklayer`).
Slices of one package may depend on each other only acyclically. The wrapper is
the protocol's public face to the simulation lifecycle; nothing outside the
slice reaches around it into the machines.

## Generated code

### IAR-EDIT-THE-MACHINE

**Generated files are never hand-edited.** A generated file opens with a
provenance header naming its source machine — *"Generated from the state
machine `Mac` — edit the machine, not this file."*
(`package/linklayer/main/t1s/MacFsm.jl:1`, likewise `PlcaFsm.jl`) — and every
change to it goes through editing the machine document in the generator script
and re-running it. Hand-editing generated output creates a fork the next
regeneration silently destroys. Corollary: generated code shares a namespace
with the hand-written code beside it (`Mac.jl` beside `MacFsm.jl`), so renaming
a hand-written helper the generated code calls is not free — regenerate in the
same change.

### IAR-GENERATOR-IS-A-TOOL

**Generators live in `tool/`; generated output is committed, deliberately.**
The generator scripts (`tool/generate_mac_fsm.jl`,
`tool/generate_plca_control_fsm.jl`) build the machine as a ProjecturEd `fsm`
document and emit the runnable module; they run in their own environment
(`tool/Project.toml`) so the library itself never depends on the editor stack.
The generated file is committed source — there is no build step
([OR-NO-BUILD-STEP] in spirit): a fresh checkout runs without running any
generator. Regeneration is a deliberate act whose diff is reviewed like any
other change, gated by [IAR-GOLDEN-HASHES].

## Observation and recording

### IAR-SEAMS-ARE-DECLARED

**Observation attaches only at declared seams, from outside the model.** A
stack's observation points are its existing wiring slots — the closure structs
and resolved module references it already uses to communicate — wrapped at
simulation-preparation time, never by editing protocol code. A communication
path that is not a wiring slot (a direct method call) is either promoted to a
declared seam or documented as unobservable — it is never faked with an ad-hoc
tap. This instantiates [OAR-DETERMINISM-NEUTRAL-RECORDING] and
[OAR-ZERO-COST-WHEN-OFF] for the network layer: nothing is wrapped when no
capture is attached.

### IAR-ZERO-COST-RECORDING

**`recorder === nothing` short-circuits; recording off costs nothing.** Every
statistics-emission site begins with the `recorder === nothing && return` guard
(e.g. `package/linklayer/main/t1s/T1sModel.jl:458`) so an unrecorded run pays
one pointer comparison, no allocation, no formatting. New emission sites follow
the same shape. The guard is also the determinism boundary: nothing behind it
may touch anything the result hash sees ([OAR-DETERMINISM-NEUTRAL-RECORDING]).

### IAR-NO-SIGNAL-REGISTRY

**Statistics are direct calls, never a registry or listener architecture.** A
module that has something to record calls its recorder directly with a named
value. There is no signal registration, no listener subscription, no
string-keyed indirection between the emission site and the sink — the INET
`@signal`/`@statistic`/`cListener` architecture is exactly the machinery this
library exists to not need ([IR-NATIVE-EXPRESSION]). If a new consumer needs a
value, it takes a sink; the emitting module does not change.

## Verification

### IAR-GOLDEN-HASHES

**Protocol behaviour is pinned by absolute hashes.** Each protocol scenario
pins an absolute result hash (the T1S `:notraffic` and `:bestcase` pins in
`package/linklayer/test/`), not merely agreement between two engines —
instantiating [OAR-ABSOLUTE-HASH-PINS]. Any change intended to be
behaviour-preserving — a refactor, a regeneration, an observation feature —
must reproduce the pinned hashes bit-for-bit; a change that means to alter
behaviour updates the pin in the same commit with the reason in the message.

### IAR-INET-COMPARISON

**The comparison against C++ INET stays runnable.** The vector-comparison
harness (`package/linklayer/test/T1sVectorComparison.jl` and the
`phase8_compare_harness.jl` checks) must keep working in both modes: against
INET reference `.vec` files when they are present, and against closed-form
analytical pins when they are not — skipping gracefully, never failing for a
missing reference. Producing the reference files is a manual step and stays
one; the harness being runnable is the requirement.

### IAR-TESTS-IN-PHASES

**A package's suite is phase files mirroring the build waves.** Each test
package is a `runtests.jl` including numbered `phaseN_*.jl` files that
correspond to how the feature was built and are individually meaningful (`Method
definition … overwritten` warnings from phase files sharing helper names are
expected and benign). A new feature adds a phase file rather than growing an
existing one; the smallest-suite rule of the repository's CLAUDE.md picks the
package, the phase structure keeps failures locatable within it.

---

Cited upstream rules: `AR-…` resolve in
`../projectured-julia/documentation/architecture-requirements.md`; `OAR-…` in
`../omnetpp-julia/documentation/architecture-requirements.md`; `OR-…` in
`../omnetpp-julia/documentation/requirements.md` or
`../omnetpp-julia/documentation/deferred-requirements.md`; `IR-…` in
[requirements.md](requirements.md).

[PAR-LOWEST-PACKAGE]: ../../projectured-julia/documentation/architecture-requirements.md#par-lowest-package
[PAR-FRAMEWORKS-SINK]: ../../projectured-julia/documentation/architecture-requirements.md#par-frameworks-sink
[OAR-FRESH-BUILD-PER-EXECUTION]: ../../omnetpp-julia/documentation/architecture-requirements.md#oar-fresh-build-per-execution
[OAR-DETERMINISM-NEUTRAL-RECORDING]: ../../omnetpp-julia/documentation/architecture-requirements.md#oar-determinism-neutral-recording
[OAR-ZERO-COST-WHEN-OFF]: ../../omnetpp-julia/documentation/architecture-requirements.md#oar-zero-cost-when-off
[OAR-ABSOLUTE-HASH-PINS]: ../../omnetpp-julia/documentation/architecture-requirements.md#oar-absolute-hash-pins
[OR-NO-BUILD-STEP]: ../../omnetpp-julia/documentation/deferred-requirements.md#or-no-build-step
[IR-FAITHFUL-PROTOCOLS]: requirements.md#ir-faithful-protocols
[IR-NATIVE-EXPRESSION]: requirements.md#ir-native-expression
[IAR-ZERO-COST-RECORDING]: #iar-zero-cost-recording
[IAR-GOLDEN-HASHES]: #iar-golden-hashes
