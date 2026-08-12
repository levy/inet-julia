# Migrating INET C++ models to inet-julia — the module framework and the queuing package

Status: **wave 1 implemented** (design 2026-08-03, wave 1 built the same day). Phases 0a-4
are done and green; wave 2 and the blocked list remain. Built in the worktrees
`omnetpp-julia-queuing` (branch `module-kernel`) and `inet-julia-queuing` (branch
`queuing-wave1`).

## 1. Goal

Port the INET C++ simulation models to the omnetpp-julia discrete event simulator, into this
package (`Inet`). The port must read as native Julia code while keeping the useful abstractions
of INET models: modules with parameters/state/statistics, gates and connections for packet
paths, the push/pull packet protocol with backpressure, and a separate module-lookup mechanism.

We start with the **queueing** model elements — spelled **queuing** in this package (the INET
directory name `queueing` is deliberately renamed to the standard spelling).

Two deliverables:

1. A **general migration recipe** (§6) — how to migrate any INET module.
2. The **`package/queuing/` package** plus the module framework it needs (§7), built in waves.

## 2. Source material (what the design is derived from)

- **INET master, `src/inet/queueing/`** — the contract layer (`IPassivePacketSink`,
  `IActivePacketSource`, `IPassivePacketSource`, `IActivePacketSink` + combinations), the base
  classes, and ~100 elements across source/sink/queue/server/classifier/scheduler/filter/
  marker/meter/shaper/policing/gate/tokengenerator/flow.
- **INET `topic/infrastructure` branch** — the communication philosophy this port adopts:
  - Protocol **registration is dead; lookup is the mechanism**: `findModuleInterface(gate,
    type, arguments, direction)` walks the connection chain asking each module whether it
    provides interface `type` for `arguments`, either via a C++ `lookupModuleInterface`
    override (dynamic claims) or declarative per-gate `@interface(...)` properties (static
    claims, incl. `forward=` transparency).
  - **Packets move by direct synchronous `pushPacket()` calls**; `send()` remains only for
    real links (channels with delay). Zero 0-simtime cross-module events inside a node.
  - Commands/queries are **direct method calls** on module interfaces; only packets traverse
    connections.
  - Lookups are resolved **once** into cached refs (`PassivePacketSinkRef`); per-packet
    delivery is a direct call.
  - The queueing **contract itself is unchanged** on the branch (`git diff` over
    `src/inet/queueing/contract` is empty; `IModuleInterfaceLookup.h` is new, branch-only
    infrastructure) — we port the master contract with the branch's communication model.
- **omnetpp-julia** — the engine is model-agnostic: a model provides `model_module_count`,
  `model_delay_edges` (sparse `(src, dst, delay)` — zero-delay edges merge modules into one
  serialized cluster, delays are the parallelism fences), `schedule_initial_events!`,
  `reset_model!`, `finalize_model!`; events are closures scheduled via
  `schedule_event!(ctx, delay, module_id, action)`; `mm1k_v2` is the precedent for the
  parameters/state/structure/behaviour split; `Recorder` +
  `register_indexed_vector!`/`emit_indexed_vector!`/`record_scalar!` for results.
- **inet-julia t1s port** — established conventions we keep: plain mutable state structs with
  `recorder::Any` defaulting `nothing` (zero-cost when off), INET-matching module paths and
  `name:vector` result names, per-module `MersenneTwister` seeded from `seed` + stable index,
  `TimerHandle` generation-counter cancellation, golden network hashes as the reproducibility
  gate, unit tests driving one layer with stubs inside a real `SequentialSimulator`.
- **ProjecturEd references** (`ProjecturedKernel.ReferenceModule`, already a dependency) —
  `Reference` is plain data (no editor needed); `evaluate_reference`/`search_references` walk
  any struct/vector graph; `IdentityReferenceStep` gives name-stable addressing. References
  are not free to build (cell-backed), so they are the *addressing/wiring* representation,
  resolved once at build/init time and cached — never a per-packet mechanism.

## 3. Architecture

### 3.1 The four-struct convention

Every migrated INET simple module `Stem` becomes four structs in one file:

- **`StemParameters`** — the typed record of configuration (INET NED parameters). Immutable
  per run. `@document` (editable/viewable in the editor, binds to the configuration UI).
- **`StemStates`** — the dynamic run state (INET member variables that change during the
  run), plain `mutable struct` (hot path, not reactive), with `reset!(states, seed)`.
- **`StemStatistics`** — counters/accumulators plus recording plumbing: `recorder::Any`
  (default `nothing`), registered vector handles, and the statistic fields themselves.
  Plain mutable, with `reset!`.
- **`StemModule`** — the assembly: identity (`name::Symbol`, `module_id::Int`), the three
  structs above, the gates, and the resolved peer refs. This is the thing gates point at and
  lookup returns.

Classifying an INET class's members into these buckets is mechanical: NED parameters and the
strategy objects created from them → `Parameters`; queues/timers/FSM/in-flight packets →
`States`; the `num*Packets`-style counters and everything emitted as a statistic →
`Statistics`; gates and `*Ref` peers → the `Module`.

Each element file is its **own Julia module** named after the element stem
(`module PacketQueue` containing `PacketQueueParameters` … `PacketQueueModule`), `using`
the contract files whose interfaces it implements (§3.2 source-file architecture).

NED-only parameter presets (DropTailQueue = PacketQueue + fixed parameters) become preset
**constructor functions**, not new types.

### 3.2 The module framework — omnetpp-julia kernel + inet-julia contract

Decided: **extending omnetpp-julia is allowed**, so the code split mirrors the C++ one — the
module/gate/connection kernel (the cModule/cGate analog) goes into **omnetpp-julia**, while
the packet protocol contract and the lookup mechanism (INET code in C++:
`queueing/contract/`, `IModuleInterfaceLookup`) live in **inet-julia**.

**Source-file architecture** (all new code, both repos — the projectured-julia kernel layer
pattern):

- Every source file is its **own Julia module** with explicit exports; files state their
  dependencies with **`using` — never `import`**. Methods of another module's generic
  function are added via qualified definition (`function Omnetpp.model_delay_edges(m::…)`),
  which works under plain `using`. (Supersedes the `import Omnetpp:` convention in
  `package/inet/main/Inet.jl` for new code.)
- An interface that is implemented multiple times and is extensible gets a **separate
  interface specification file** (generic-function declarations, docstrings, error stubs).
- An interface with default implementations gets a **separate defaults file**.

**omnetpp-julia — new module layer `src/model/module/`** (next to `structure/`; designed so
the future declarative module description, `plan/pending/native-module-description.md`, can
generate these values):

```julia
abstract type AbstractModule end        # supertype of every StemModule

@enum GateDirection GateInput GateOutput

mutable struct Gate
    owner::Any                    # the AbstractModule (Any: no circular type refs)
    name::Symbol
    index::Int                    # 1-based position in a gate vector; 1 for scalar gates
    direction::GateDirection
    peer::Union{Gate, Nothing}    # next gate along the connection chain
    delay::SimTime                # delay of the connection leaving this gate (0 = same event)
    annotations::Vector{Any}      # uninterpreted metadata slot (NED-property analog);
end                               # inet-julia's lookup claims live here (§3.5)

connect!(out_gate, in_gate; delay = ZERO_DELAY)
```

File split: interface specification (`ModuleInterface.jl` — gate access, chain traversal,
init hooks), data types + core operations, `ModuleDefaults.jl`. Details:

- Gate chains work like OMNeT++: a connection may pass through **compound module boundary
  gates**; `next_gate`/`previous_gate` traverse the chain, `end_gate` finds the terminal
  module. Compound modules are composition sugar — a struct holding submodules + internal
  connections whose boundary gates sit in the chain; they have no behaviour of their own.
- **1-based indexing everywhere** (repo convention). Gate vectors (`out[]` of a classifier)
  are `Vector{Gate}` fields.
- `TimerHandle` moves from `T1sModule` to this layer (generic timing utility; t1s then gets
  it from `Omnetpp`, tests stay green).
- Network-builder helpers: modid assignment, `model_delay_edges` derived from connections,
  the two-stage init driver (§3.10).
- Note: `AbstractModule` (a network component) vs `AbstractModel` (a whole simulation) are
  one letter apart; this mirrors the OMNeT++ module/model vocabulary and is accepted.

**inet-julia** keeps the INET half:

- `package/queuing/main/contract/` — one interface specification file per protocol interface plus a
  contract defaults file (§3.3).
- `package/common/main/lookup/` — the lookup mechanism (§3.5): claim types (stored in gate `annotations`),
  `find_module_interface`, reference resolution.

### 3.3 The packet protocol — generic functions, not interface types

Julia has no multiple inheritance, and INET roles combine freely (a queue is passive on both
sides, a server active on both). So the four roles become **generic-function vocabularies**
that a `StemModule` type implements by defining methods; role membership is declared, not
inherited (§3.5). All protocol functions take the schedule context first (t1s convention):

```julia
# passive sink (consumer)          # passive source (provider)
can_push_some_packet(m, gate)      can_pull_some_packet(m, gate)
can_push_packet(m, gate, pk)       can_pull_packet(m, gate)       # → Packet | nothing
push_packet!(ctx, m, gate, pk)     pull_packet!(ctx, m, gate)     # → Packet

# active source (producer)         # active sink (collector)
handle_can_push_packet_changed!(ctx, m, gate)
handle_push_packet_processed!(ctx, m, gate, pk, successful)
handle_can_pull_packet_changed!(ctx, m, gate)
handle_pull_packet_processed!(ctx, m, gate, pk, successful)
```

- Each role is specified in its **own interface file** under `package/queuing/main/contract/`
  (`PassivePacketSink.jl`, `ActivePacketSource.jl`, `PassivePacketSource.jl`,
  `ActivePacketSink.jl`, later `PacketCollection.jl` …), mirroring INET's `contract/`
  folder; shared **default implementations** (trivial `can_*` answers, backpressure
  propagation for transparent flows, the `push_or_schedule!` egress helper) live in
  `ContractDefaults.jl`.
- Backpressure flows opposite to packets via the two `handle_can_*_changed!` callbacks,
  exactly as in INET; transparent elements propagate them through.
- The **streaming trio** (`push_packet_start!`/`_progress!`/`_end!`, preemption) is deferred;
  the design leaves room (extra methods on the same vocabulary) but wave 1–2 elements don't
  need it. `PreemptingServer`/`InProgressQueue` wait for it.
- Ownership discipline replaces C++ `take()`/`delete`: a pushed/pulled packet is handed over —
  the giver must not retain or mutate it afterwards; duplicators use `dup` (O(1),
  content-shared). Dropping = emit drop statistic and simply lose the reference.
- Reentrancy: callbacks are synchronous (a queue's `push_packet!` may call the collector's
  `handle_can_pull_packet_changed!`, which pulls back into the queue on the same stack).
  Rule from INET, kept as our discipline: **update all own state and statistics before
  notifying peers**. Where a module needs more (INET's `reconcile()` pattern), state it in
  that module's port notes — no framework mechanism until needed.

### 3.4 Communication rules

1. **Packets travel only via connections/gates.** Egress goes through one helper:

   ```julia
   push_or_schedule!(ctx, m, out_gate, packet)
   ```

   - consumer ref resolved and connection delay zero → **direct synchronous call**
     `push_packet!(ctx, consumer, peer_gate, packet)` — same event, infrastructure-branch
     semantics;
   - connection has delay (a link) → `schedule_event!(ctx, delay, peer_modid, c ->
     push_packet!(c, consumer, peer_gate, packet))` — the analog of `send()` over a channel.
2. **Everything else is a direct method call between modules** — queries
   (`get_num_packets(queue)`, `is_open(gate)`), commands (`open!`/`close!`), token
   operations (`add_tokens!`) — on a module found via lookup (§3.5). No command messages,
   no signals-as-communication.
3. **Timers are self-events**: `schedule_timer!(ctx, delay, m.module_id, handle, action)`
   with `TimerHandle` cancellation.

### 3.5 Lookup — a separate mechanism (the infrastructure-branch design)

Lives in inet-julia `package/common/main/lookup/` (own Julia module; interface + defaults files as the
mechanism grows), independent of the packet protocol. Two addressing modes:

**(a) Connection-relative lookup** — the `findModuleInterface` port:

```julia
abstract type ModuleInterface end            # lookup tokens, not supertypes (InetCommon)
# the packet-role tokens are declared by their contract files (§3.3):
abstract type PassivePacketSink  <: ModuleInterface end
abstract type ActivePacketSource <: ModuleInterface end
abstract type PassivePacketSource <: ModuleInterface end
abstract type ActivePacketSink   <: ModuleInterface end
# later: PacketCollection, TokenStorage, Clock, ...

find_module_interface(gate, ::Type{T}; arguments = nothing, direction = 0)
    # → (module, gate) | nothing
```

Walks the gate chain (forward for output gates, backward for input, explicit override via
`direction`); at each module it consults, in order:

1. a **dynamic claim**: a `lookup_module_interface(m, gate, T, arguments, direction)` method
   defined for that module type (the dispatcher/socket mechanism; default method falls
   through to 2) — its answer is final;
2. **declarative claims** on the arrival gate (claim values stored in the gate's
   `annotations` slot): `InterfaceClaim(T; arguments...)` matches the requested interface +
   arguments; `ForwardClaim(T, out_gate_name[, translated_T])`
   re-issues the lookup out of another gate (transparency — a delayer answers on behalf of
   what's behind it; a queue answers an `ActivePacketSink` lookup for its downstream). No
   claim → the walk continues to the next module in the chain.

Failed mandatory lookup is a hard error naming the originator, gate, and interface.
Arguments start as `nothing` (unconditional); the protocol/service/socket argument
vocabulary from the branch is added only when dispatching protocol stacks arrive.

**(b) Reference lookup** — the replacement for INET's module-path parameters
(`bufferModule`, `storageModule`, `clockModule`, `collectionModule`): a parameter field of
type `Union{Nothing, Reference}` holding a ProjecturEd reference, evaluated against the
**network root** at initialize time:

```julia
resolve_module(network, ref, ::Type{T})   # try_evaluate_reference + interface check
```

`search_references(network, m -> m isa PacketBufferModule)` covers find-by-type;
`IdentityReferenceStep` is available for name-stable addressing (note: it resolves against
an `IdentityDocument` wrapper carrying the identity string, not a bare name field — if we
want it, the network builder must wrap or the step stays unused in favor of field/index
steps). References are built/stored in parameters and resolved **once**; the resolved
module is cached in the `StemModule` ref fields.

**Role declaration** (used by lookup and by connection validation): a module states which
interfaces it implements per gate — this is what the `claims` on its gates encode; the
`check_gate_compatibility` pass at init (the `checkPacketOperationSupport` analog) validates
that every connection pairs a pusher with a pushee or a puller with a pullee, with errors
naming the offending modules.

### 3.6 Forwarding

All three kinds the design must support, and how:

- **Packet forwarding**: transparent flow elements implement `push_packet!` as process +
  `push_or_schedule!` downstream (and mirror for pull) — INET `PacketFlowBase`.
- **Call forwarding**: a module implements an interface method by delegating to another
  module (compound queue delegates `get_num_packets` to its inner queue; `PacketFlowBase`
  delegates the collection interface upstream). Plain method bodies — no machinery.
- **Lookup forwarding**: `ForwardClaim` (declarative) or a `lookup_module_interface` method
  (dynamic). Per the branch's D4 decision: a module that forwards a lookup *without
  processing packets itself* steps out of the data path entirely (the returned ref bypasses
  it); transparent *data-path* elements instead answer on behalf of downstream while staying
  in the path.

### 3.7 Engine integration

A migrated network is an `AbstractModel` (the omnetpp-julia interface), assembled by a
network builder:

- **Module ids**: `1` = barrier (convention), then one `module_id` per module struct,
  assigned deterministically in construction order. Ids are stable per model kind (hash
  reproducibility).
- **`model_delay_edges` is derived from the connections** — every connection contributes
  `(src_modid, dst_modid, delay)`. Zero-delay connections merge the chain into one cluster
  (serialized — required, since direct calls mutate peer state within one event); delayed
  links are the parallelism fences. This makes the parallel-engine contract fall out of the
  topology for free.
- `build_model` constructs modules + gates + connections + runs init stage 1;
  `schedule_initial_events!` runs init stage 2 (§3.10) and wires the recorder;
  `reset_model!` resets states/statistics and reseeds RNGs; `finalize_model!` derives
  end-of-run scalars from terminal state. New code extends these via qualified definition
  (`function Omnetpp.finalize_model!(…)`) under plain `using` (§3.2) — `finalize_model!`
  is in the interface but absent from the umbrella's legacy import list.
- **RNG**: per-module `MersenneTwister` seeded from the model seed + stable module index
  (t1s rule), stored in `StemStates`.

### 3.8 Statistics — native Julia expressions

The `@statistic` mini-language (source/filter/record chains, warmup, atomic brackets,
histogram declarations) is **not ported and not reinvented as a DSL** — statistic
definitions are native Julia expressions: emission sites and accumulator updates are
ordinary code in the module, derived statistics are plain Julia functions over recorded
data. Direct recorder emission, t1s-style — no signal/subscription registry:

- `StemStatistics` holds the counters INET keeps as member variables
  (`num_pushed_packets`, …) **and** the emission plumbing: `recorder::Any` (`nothing`
  default), `stat_handles::Dict{Symbol,Int}`.
- Emission helper per module: `recorder === nothing && return` short-circuit, then
  `emit_indexed_vector!` (SimTime overload for time-valued stats → seconds, INET
  convention).
- **Names and module paths match INET exactly** (`queueLength:vector`,
  `NetworkName.queue`…) so `.vec` files cross-compare with INET references via the existing
  `compare_vec_files` harness.
- Each module computes its named statistics as ordinary Julia code (queue length emitted
  after push/pull/drop; jitter/lifetime accumulators as explicit fields when we get to the
  rich sink statistics — first wave records the count/length/rate/queueLength/queueingTime
  family and the drop statistics); end-of-run scalars are Julia expressions over terminal
  state and recorded vectors in `finalize_model!`.
- Initial/final emissions only when file output is requested (extra root events change the
  network hash — t1s lesson); recording must stay determinism-neutral.

### 3.9 Parameters — native Julia expressions

- NED's parameter expression language (defaults, `exponential(1s)`, cross-parameter
  references, units) is **not ported**: parameter values and defaults are native Julia
  expressions in the `StemParameters` keyword constructor (defaults may reference earlier
  keyword arguments; quantities are plain Julia values in documented units — `Float64`
  seconds, `BitLength` for lengths, `SimTime` only at the engine boundary).
- **Volatile parameters** (re-evaluated per use: `productionInterval`, `processingTime`,
  `packetLength`) are marked with an explicit **`Volatile(...)` wrapper value**. The read
  helper `evaluate(p.field, rng)` distinguishes three cases:
  - a plain number — constant;
  - a bare distribution value, `uniform(0, 10)` — **drawn once** at build from the module
    RNG (NED's non-volatile random assignment; materialization implemented when first
    needed — the wave-1 random parameters are all volatile);
  - `Volatile(uniform(0, 10))` — **re-evaluated (sampled) at every use**, the NED
    `volatile` semantics. INET `volatile` NED defaults translate to `Volatile(...)`
    defaults in the constructor.

  Distribution constructors (`uniform(a, b)`, `exponential(mean)`, `normal(m, s)`, …) are
  ordinary Julia functions returning small isbits distribution values — native
  expressions, not a DSL; they live with the module layer's parameter support in
  omnetpp-julia. `Volatile` may also wrap a function for arbitrary per-use logic. `Volatile`
  and the distributions are plain structs (deliberately not `@document`), so a parameter
  field's stored value is never a bare `Function` — **the reactive thunk trap does not
  arise and no special cell kinds are needed**; the values stay inspectable/editable data
  in the editor.
- INET's `Class`-string strategy parameters (`dropperClass`, `comparatorClass`,
  `classifierClass`, packet-filter expressions) become **plain Julia functions/closures**
  stored in parameters (`dropper` holding `queue -> packet_to_drop`), with the named INET
  strategies provided as ordinary functions. These fields do hold bare `Function`s, so they
  keep the explicit `::ImmutableCell{Any}` cell kind (the documented thunk-trap escape).
  The NED match-expression language is not ported; predicates are Julia closures.

### 3.10 Initialization — two stages

The INET stage system collapses to two (more only when a future model demands it):

1. **`initialize_refs!(network, m)`** — resolve all lookups (connection-relative and
   reference) into cached refs; validate gate compatibility. Pure topology reading; no
   protocol calls; runs for all modules inside `build_model`.
2. **`initialize_protocol!(ctx, m)`** — the protocol kicks that INET does in
   `INITSTAGE_QUEUEING`: queue notifies its producer, source schedules its first
   production, server tries to start serving. Runs as the first root event(s) from
   `schedule_initial_events!`.

### 3.11 Reactive/`@document` policy

- `StemParameters`: `@document` (UI-bindable configuration).
- `StemModule` and the network struct: `@document` — non-invasive (native `Mut` variant runs
  full speed), makes the running network viewable/selectable in the editor and gives
  projectured references first-class documents to address. States/statistics stay **plain
  mutable structs** held in module fields (the mm1k/t1s hot-path rule).
- No bare `Function`-typed fields in any `@document` struct (thunk trap); volatile
  parameters are `Volatile(...)` wrapper values (plain structs, trap-free by construction),
  and the remaining bare-`Function` strategy fields use the explicit `ImmutableCell{Any}`
  cell kind (§3.9).

## 4. Difficulties found, and their resolutions

1. **No interfaces/multiple inheritance in Julia** — INET's role interfaces combine freely
   on one class. → Roles = generic-function vocabularies + declared claims (§3.3, §3.5);
   interface tokens are abstract types used as first-class lookup keys, never supertypes.
2. **No gates/connections in omnetpp-julia** (`Structure.jl` has id→id connections only,
   named ports explicitly "future"). → Build `Gate`/`connect!`/chain traversal as a new
   omnetpp-julia module layer (§3.2); the engine still sees only modids + delay edges,
   derived from the connections (§3.7).
3. **Synchronous backpressure reentrancy** — nested push/pull callbacks on one stack.
   → Keep INET's ordering discipline (state before notify, §3.3); adopt the branch's
   "explicit pending state + reconcile" pattern per-module only if a port actually hits it.
4. **Volatile NED parameters** re-drawn per use. → explicit `Volatile(...)` marker values
   (§3.9): `uniform(0, 10)` draws once at build, `Volatile(uniform(0, 10))` re-draws per
   use; the wrapper is a plain struct, so it also structurally avoids the reactive-field
   thunk trap (only bare-`Function` strategy fields still need `ImmutableCell{Any}`).
5. **Module-path string parameters** (`bufferModule` etc.). → ProjecturEd references
   resolved once at init (§3.5b). This is the projectured-native replacement, and the first
   real sim-side use of the reference layer.
6. **INET's `@statistic` declarative layer** is a whole expression language. → Not ported
   and not reinvented — statistic definitions are native Julia expressions, emitted under
   INET-compatible names/paths (§3.8); validate against INET `.vec` references.
7. **C++ ownership (`take`/`drop`/`delete`)**. → GC removes deletion, but the handover
   discipline stays (no retention after push/pull; `dup` for duplication) (§3.3).
8. **Streaming/preemption protocol** — a large seam touching servers, queues, gates.
   → Deferred wholesale; excluded elements listed in wave "later" (§7).
9. **Clocks** (`ClockUserModuleMixin`, drifting clocks). → Deferred; all timing goes through
   the timer helpers, which are the single seam where a clock hook can be added later.
   `clockModule` parameters are omitted from ported elements until then.
10. **Trajectory parity with C++** — direct calls produce different event trajectories than
    master INET's mix of sends. → We target the *infrastructure branch* semantics (it proved
    behavior parity is achievable); validation is statistics-level (`.vec` comparison with
    per-signal rules, analytical pins, golden hashes), not event-log-level.
11. **The framework spans two repos** — the module/gate kernel belongs in omnetpp-julia
    (cModule/cGate territory; extending it is allowed), the contract + lookup in inet-julia
    (INET territory), so wave-1 work is lockstep across both. → Accepted: the module layer
    is a self-contained omnetpp-julia slice with its own tests (Phase 0a lands before its
    first inet-julia consumer), and the one-way Inet→Omnetpp dependency keeps the seam
    clean.
12. **Compound modules** (PriorityQueue etc. are pure NED composition). → Structs of
    submodules + internal connections + boundary gates in the chain (§3.2); statistics
    aggregation (`CompoundPacketQueueBase`) via call forwarding (§3.6). First compound is
    ported in wave 2, which is the design's proof.

## 5. Relationship to INET naming

| INET / OMNeT++ | Julia port |
|---|---|
| `cModule` / `cGate` (omnetpp kernel) | omnetpp-julia `src/model/module/` (`AbstractModule`, `Gate`) |
| `queueing/` | inet-julia `package/queuing/main/` |
| `queueing/contract/*.h` | `package/queuing/main/contract/*.jl` interface specification files (tokens + method vocabularies) |
| `PacketProcessorBase` etc. base classes | `ContractDefaults.jl` + shared helpers + composition — no base-class towers |
| `pushPacket(packet, gate)` | `push_packet!(ctx, m, gate, packet)` |
| `PassivePacketSinkRef` + `pushOrSendPacket` | cached `(module, gate)` refs + `push_or_schedule!` |
| `findModuleInterface` / `@interface` props | `find_module_interface` / `InterfaceClaim`/`ForwardClaim` in gate `annotations` |
| `ModuleRefByPar` (path strings) | `Reference` parameters + `resolve_module` |
| NED parameter expressions, volatile | native Julia expressions; `volatile` → `Volatile(uniform(0, 10))` marker values |
| `@statistic` declarations | native Julia expressions: direct emission + Julia post-processing, INET-compatible names |
| module display strings, animation | not ported (editor projections are the future answer) |

## 6. General migration recipe (per module)

Method: **derive, don't transliterate** (the packet-chunk-api ledger discipline). Per
element:

1. **Read the sources**: the NED file (parameters, gates, statistics, `@defaultStatistic`)
   and the C++ class (member variables, protocol methods, init stages). Note base-class
   inheritance — in Julia it flattens into the four structs + shared helper functions.
2. **Write `StemParameters`**: one field per NED parameter, defaults as native Julia
   expressions; volatile → `Volatile(...)` default; strategy classes → function fields
   (`ImmutableCell{Any}`); module-path params → `Reference` fields. Drop parameters that
   are C++/display accidents (`displayStringTextFormat`) — record each drop.
3. **Write `StemStates`**: the mutable run state, `reset!`, RNG if the module draws random
   numbers.
4. **Write `StemStatistics`**: counters + emitted vectors with INET signal names; `reset!`.
5. **Write `StemModule`**: gates (with their lookup claims in `annotations`), ref fields,
   the four-struct assembly; constructor takes `name` + `parameters` and builds gates.
6. **Implement the protocol methods** the element's roles require, translating the C++
   bodies; keep the notification order.
7. **Init**: `initialize_refs!` (resolve refs) and `initialize_protocol!` (kicks), as
   needed.
8. **Tests**, in this order: unit test with stub peers in a real `SequentialSimulator`;
   chain test in a mini-network with a pinned golden hash; where an INET reference exists,
   statistics comparison.
9. Record deviations from INET (dropped params, changed semantics) in this plan's log.

## 7. The queuing package — waves

Each phase = one commit series in the worktree; check off + append implementation notes here.

### Phase 0a — module kernel (omnetpp-julia, `src/model/module/`)
- [x] `AbstractModule`, `Gate`, `GateDirection`, `connect!`, chain traversal, compound
      boundary gates, `annotations` slot — separate Julia-module source files,
      `using`-linked, with the `ModuleInterface.jl` / `ModuleDefaults.jl` split
- [x] `TimerHandle` moved here from `T1sModule` (t1s updated; tests still green)
- [x] Network-builder helpers: modid assignment, `model_delay_edges` from connections,
      two-stage init driver, plus a per-run statistics-declaration hook
- [x] Unit tests: chain traversal, compound boundaries, builder; existing golden hashes
      unchanged

### Phase 0b — contract & lookup (inet-julia)
- [x] `package/queuing/main/contract/`: one interface specification file per role
      (`PassivePacketSink.jl`, `ActivePacketSource.jl`, `PassivePacketSource.jl`,
      `ActivePacketSink.jl`) + `ContractDefaults.jl` (default `can_*` answers,
      backpressure propagation, `push_or_schedule!`)
- [x] `package/common/main/lookup/`: `find_module_interface`, `InterfaceClaim`/`ForwardClaim` (stored in
      gate `annotations`), `lookup_module_interface` hook, `resolve_module` (reference
      mode)
- [x] `check_packet_connections` init validation (named for what it checks)
- [x] Unit tests: lookup (incl. forward claims), compatibility errors

### Phase 1 — sources & sinks (push and pull endpoints)
- [x] `ActivePacketSource` (periodic push producer; `Volatile`-valued interval; retry on
      `handle_can_push_packet_changed!`)
- [x] `PassivePacketSink`, consumption interval included
- [x] `PassivePacketSource`, `ActivePacketSink` (the pull pair)
- [x] Shared packet-fabrication helper (`PacketTemplate`, `CreationTimeTag`)
- [x] Chain test: producer → consumer (push) and provider → collector (pull), golden hashes

### Phase 2 — queue & server (the canonical chain)
- [x] `PacketQueue` (capacity by packets/bits, overflow drop via dropper function,
      comparator ordering; `bufferModule` deferred) + `drop_tail_queue`/`drop_head_queue`
      presets
- [x] `PacketServer` (`Volatile`-valued processing time/bitrate), `InstantServer`
- [x] Canonical chain test **source → queue → server → sink**, checked against the
      closed-form M/M/1 results and Little's law
- [x] `queueLength`/`queueBitLength`/`queueingTime`/drop statistics (`.vec` cross-check
      against INET reference files still to do)

### Phase 3 — classification, scheduling, filtering
- [x] `priority_classifier`, `content_based_classifier` — one element, two functions
- [x] `priority_scheduler`
- [x] `PacketFilter` with a predicate (drop statistics; `backpressure` parameter)
- [x] Fan-out/fan-in chain tests

### Phase 4 — plumbing & first compound
- [x] `PacketMultiplexer`, `PacketDemultiplexer`, `PacketDelayer`
- [x] Compound module support proven: `PriorityQueue` (classifier → queue[n] → scheduler)
      with aggregated statistics
- [x] Catalog entry: `QueuingModel` in `inet_simulation_catalog()`

### Wave 2 (breadth, own plan when reached)
Wrr/Label classifier+scheduler+filter, markers/taggers, token subsystem (`TokenBucket` value
type, `TokenBucketMeter`, `TokenBasedServer`, token generators → `LeakyBucket`/`TokenBucket`
shapers, `PacketPolicing`), `PacketBuffer`/`PriorityBuffer`, cloner/duplicator/ordinal
elements, `MarkovClassifier`/`Scheduler`, `EmptyPacketSource`/`FullPacketSink`,
`BackPressureBarrier`.

### Later / blocked (reasons)
- RED family (`RedDropper`, `EcnMarker`) — RED math + IPv4 header access.
- TSN gates/shapers (`PeriodicGate`, `CreditBasedGate`, `GateControlList`, shapers) — guard
  bands, transmission awareness, clocks.
- `PreemptingServer`, `InProgressQueue` — streaming protocol.
- Flow measurement — region-tag timing machinery.
- PCAP elements — file format infrastructure.
- `DynamicClassifier` — runtime module creation.

## 8. Open decisions

- [ ] Keep the `Gate`/annotation data generatable by the future declarative module
      description (omnetpp-julia `plan/pending/native-module-description.md`) — check the
      fit when that plan starts.
- [ ] Lookup **argument vocabulary** (protocol/service/socket) — introduce with the first
      dispatching element (MessageDispatcher analog), not before.
- [ ] Whether `StemStates`/`StemStatistics` should ever be `@document` (editor inspection of
      live queue contents) — revisit once the editor story for running sims needs it;
      default is plain mutable.
- [ ] Rich sink statistics family (jitter, delay variation, out-of-order) — port with
      explicit accumulators when a model needs them (wave 2+).

## Implementation log

### Wave 1 (phases 0a–4)

Where it landed. omnetpp-julia gained `package/simulator/main/src/model/module/` —
`ModuleLayer.jl` including `TimerModule`, `VolatileModule` and `NetworkModule` (the last
split into `ModuleInterface.jl` / `Gate.jl` / `Network.jl` / `ModuleDefaults.jl`).
inet-julia gained the lookup mechanism, the queuing contract and elements, and
`QueuingModel`. Every file is its own Julia module, `using`-linked, extending other modules'
generics by qualified definition. (They were written under `src/`; the component split that
followed — plan/done/component-package-split.md — moved them to `package/common/main/lookup/`
and `package/queuing/main/`, which is where the paths in this plan now point.)

Results: omnetpp-julia 5027 pass / 0 fail (baseline 4966 + 61 new; the 22 pre-existing
`test_presentation()` errors unchanged), inet-julia 1680 + 414 unchanged plus **203 new
queuing tests**, 0 fail.

**Decisions taken during the build**

- **Element structs stay plain mutable, not `@document`** (deviates from §3.11). The model
  wrapper `QueuingModel` is `@document`, as the lifecycle needs; parameters, states,
  statistics and the module itself are plain, following the t1s precedent where the model is
  reactive and the layer structs are not. `search_references` walks plain structs, so
  reference lookup is unaffected. Revisit when the editor needs to show a live network.
- **Stage names**: the kernel calls the two stages `initialize_module!` (topology, at build)
  and `start_module!` (behaviour, as a root event), not the plan's `initialize_refs!` /
  `initialize_protocol!` — "refs" and "protocol" are INET words in a kernel API. A module
  opts into the second with `module_starts`, so one needing no kick costs no event.
- **A third kernel hook**, `register_module_statistics!(m, path, recorder)`, because the
  recorder belongs to the run and cannot be given to a module when it is built.
- **Four gate pairings, not three** (§3.2 said three): a compound may also connect its own
  input boundary to its own output boundary — the pass-through an omitted module is. Only
  joining one module's input to *another's* output is rejected.
- **The lookup walk continues only where connections do.** A module that neither claims nor
  answers ends the walk when nothing leads on from the gate it arrived at; passing through
  needs a real connection (a compound boundary, or a pass-through). This is faithful to
  `findModuleInterface`, and was a wrong assumption in the first draft of the tests.
- **Capacities are `nothing`, not `-1`** — INET's sentinel becomes `Union{Nothing,Int}` /
  `Union{Nothing,BitLength}`.
- **One element per INET *shape*, not per INET strategy.** `PacketClassifier`,
  `ContentBasedClassifier` and `PriorityClassifier` become one element and two prepared
  functions; likewise the schedulers and the filters. This is §3.9's "strategy classes become
  Julia functions" taken to its conclusion.
- **`Volatile` proved out.** Volatile parameters are `Volatile(exponential(0.1))` values read
  with `evaluate(value, rng)`; a bare distribution at a use site is an error naming the fix.
  No `@document` field ever holds a bare `Function`, so the thunk trap never arises.
- **Statistics per module under INET's names and paths** (`queueLength:vector`,
  `Queuing.queue`), scalars derived in `finalize_module!`. Queue length is *integrated* as the
  queue changes rather than sampled, so `queueLength:timeavg` is exact and costs nothing.

**Two deliberate departures from INET's behaviour**, both fixing something:

- **A queue that refused now tells its producer when it has room again.** INET's `PacketQueue`
  notifies its producer only at initialization, so a full queue with no dropper stalls its
  producer for the rest of the run. Covered by "a queue with a capacity and no dropper pushes
  back".
- **A server marks itself busy before taking a packet, not after.** Taking one frees room
  upstream, and with the fix above that news reaches the server again *before* its timer is
  armed — without the flag it would start serving a second packet on top of the one it holds.
  This is the reentrancy hazard §3.3 anticipated, and it appeared exactly where predicted.

**Also fixed**: `OmnetppSimulatorBlackBoxOptimExt` still declared `module
OmnetppBlackBoxOptimExt` after the rename, so the extension failed to load and took the
repository-wide suite down with it whenever BlackBoxOptim was present. One-word fix, its own
commit.

**Gaps left for wave 2**: `.vec` cross-checking against INET reference files (the harness
exists, the reference files do not); the rich sink statistics family (jitter, delay variation,
out-of-order); `bufferModule`; pushing *through* a scheduler (only the pull side is built);
streaming/preemption and clocks, as planned.

**Test premises that were wrong, not the code** — worth remembering: a filter's
`backpressure` does not affect a source that only asks "any room?" (it changes the answer to
"can you take *this* packet", which a server asks); a multiplexer offers room to producers in
index order, so the first starves the rest, exactly as INET does; and a packet arriving at an
empty queue with an idle server is pulled straight back out in the same event, so its queueing
time is legitimately zero.
