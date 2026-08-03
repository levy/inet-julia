# 10BASE-T1S with PLCA — a Julia-native replication

**Status:** implemented (phases 1–10). `test/t1s/phase{1..9}_*.jl` green,
130 checks, no regressions to the existing suite. `notraffic.ini`
reproduces (5 nodes, 100 µs, 305 events, hash
`0xb58a20d95ff669c958edb2eebde3f4a9` pinned). Bestcase/worstcase per-node
timing offsets and INET hash cross-check are recorded follow-ups.
**Scope:** a working 10BASE-T1S multidrop model on `omnetpp-julia` that reproduces
INET's `examples/ethernet/TenBaseT1S/` scenarios byte-for-byte on cycle
timing and event ordering. Six INET classes replicated
(`EthernetCsmaMac`, `EthernetCsmaPhy`, `EthernetPlca`, `EthernetPlcaInterface`,
`EthernetSourceApp`, `EthernetSinkApp`) **faithfully** — every stateful module
keeps its FSM, `WireJunction` is a first-class module, and the MAC ↔ PLCA
collision dance is preserved. Layout convenience is Julia-native; behaviour
is verbatim.
**Depends on:** `plan/done/packet-chunk-api.md` (`Omnetpp.PacketModule` —
`@header`, chunks, tags, envelope).
**Prior art:** INET at `src/inet/{linklayer/ethernet,physicallayer/wired/ethernet}/`.
Detailed analysis is the source of every timing constant and state-machine
transition below; cited as `file:line` where relevant.

---

## 1. What 10BASE-T1S / PLCA is, in one page

10 Mb/s Ethernet over a **single twisted pair**, half-duplex, multidrop bus of
up to eight nodes (IEEE 802.3cg-2019 clauses 147–148). One shared wire; when
one node transmits, all others receive after per-segment propagation delay.
Bit time = 100 ns; IFG = 96 bits = 9.6 µs; frames are ordinary Ethernet MAC
frames plus an 8-byte PHY header (preamble + SFD) and a 1-byte end-of-stream
delimiter (ESD).

**PLCA (Physical Layer Collision Avoidance)** replaces CSMA/CD's random-backoff
collision recovery with **round-robin token passing**. One node is the
**coordinator** (`local_nodeID == 0`); it periodically emits a **BEACON**
(20-bit-long marker on the wire) that starts a **cycle**. After the beacon,
`plca_node_count` **transmit opportunities (TOs)** follow, one per node
in ID order. During TO N, only node N may transmit; others yield. A node
with nothing to send yields immediately, so the coordinator's `curID` counter
advances one TO per idle slot (~3.2 µs) or one TO per frame (frame duration
plus PHY hdr + ESD + IFG). At `curID >= plca_node_count`, the coordinator
emits the next beacon.

The **COMMIT** signal is a distinct wire signal a node emits BEFORE its frame
— it "claims" the medium during the brief window between deciding to
transmit and the frame actually appearing. In burst mode, COMMIT is re-emitted
between frames to hold the channel.

Under PLCA, real collisions never occur. INET nonetheless keeps
`EthernetCsmaMac` unchanged and layers PLCA between MAC and PHY as a shim
that fakes carrier-sense/collision signals for the MAC. This is a
compatibility artefact of retrofitting PLCA onto pre-existing code and is not
inherent to the protocol — see §3.

---

## 2. Concrete goal: reproduce these three examples

INET ships ten `.ini` files under `examples/ethernet/TenBaseT1S/`. Three are
the right targets and cover the model's whole surface:

| Example | Scope of what it exercises | Why it's a good target |
|---|---|---|
| **`notraffic.ini`** | 4 nodes + 1 controller, no application traffic. | Only the PLCA **control** FSM runs. Coordinator emits BEACON, `curID` cycles 0→1→2→3→0. If the per-cycle `cycleLength` and per-node TO-start timestamps match INET's, the entire beacon + WAIT_TO + YIELD + NEXT_TX_OPPORTUNITY skeleton is correct. |
| **`bestcase.ini`** | 4 nodes, `max_bc=1`, packets arrive exactly at own-TO start. | Exercises the "packet is ready at TO start" happy path: CS_COMMIT → CS_TRANSMIT → CS_BURST → CS_TRANSMIT → CS_NEXT_TX_OPPORTUNITY. Zero pending delay. Cycle length is a closed-form arithmetic; matching it to nanoseconds validates the transmit path. |
| **`worstcase.ini`** | Same topology as bestcase, but node[0] misses its TO by 1 ps. | Exercises the **data** FSM's DS_HOLD → DS_COLLIDE → DS_DELAY_PENDING → DS_PENDING → DS_WAIT_MAC → DS_TRANSMIT recovery path. Predicts 231.6 µs pending delay exactly. Matching this validates the retry-in-next-cycle mechanism. |

Everything the model can express at the target level appears in these three:
control-FSM cycling, transmit path, burst mode, missed-TO recovery, multiple
receivers, arbitrary source timings. Reproducing them is the acceptance test
of the whole plan.

The other seven inis are variations (traffic sweeps, throughput/latency
measurements, mixed CSMA/CD-vs-PLCA comparisons, a paper-figure
reproduction). They come essentially for free once the three above pass;
list them under §9 as follow-ups, not phases.

---

## 3. What is essential, and what is an INET-C++ accident

Same ledger style as [[packet-chunk-api]] §2. The user's brief is *don't copy
blindly*; here that matters more than usual because much of INET's Ethernet
layer is CSMA/CD scaffolding with PLCA glued on top.

### 3.1 Drop entirely

| INET mechanism | Why it exists | Julia replacement |
|---|---|---|
| **`IEthernetCsmaMac` / `IEthernetCsmaPhy` abstract interface classes** | C++ abstract base classes so PLCA can implement both (§7 gotchas: PLCA implements both interfaces at once) | Direct function calls between structs. Dispatch on state type is enough. |
| **PMCD (physical medium collision detected) as a separate variable** | IEEE MII bookkeeping never actually mutated (`EthernetPlca.cc:373` guard reduces to `!CRS && local_nodeID == 0`) | Drop; fold into the direct guard. |
| **cMessage self-messages and priority-based tie-breaking (`SHRT_MIN` / `SHRT_MAX` on `rxEndTimer` / `crsOffTimer`)** | OMNeT++ FES tie-breaking across message kinds | Julia scheduler resolves same-time events by insertion order deterministically. `to_timer` priority = 100 (§3.2) needs an explicit workaround; the two PHY priorities become schedule-order choices at their ~2 sites. |
| **`fcsMode` != `"declared"`** | Computes real Ethernet CRC | Declared mode is INET's default; no code path computes an actual CRC in the target scenarios. Drop CRC computation, keep the 4-byte FCS field. |
| **`EthernetPlcaInterface` compound module + `egressTC`/`ingressTC`/`measurementStarter` submodules** | Optional traffic conditioners, all empty by default in every target `.ini` | Not modelled. App → queue → MAC directly. |
| **cModule / cGate / NED parameter propagation** | OMNeT++ topology apparatus | `T1sModel <: AbstractModel`; nodes are struct instances; module_ids assigned at build; NED-like parameters live on the model struct. Same pattern as `RoutingModel`. |

### 3.2 Keep, because they are real

- **`EthernetCsmaMac`'s 6-state FSM.** `IDLE`, `WAIT_IFG`, `TRANSMITTING`,
  `JAMMING`, `BACKOFF`, `RECEIVING` (`EthernetCsmaMac.h:39-46`). Under PLCA
  the JAMMING / BACKOFF branches DO fire (§3.2 gotcha in the analysis):
  DS_COLLIDE in PLCA raises `handleCollisionStart` up to MAC, which enters
  JAMMING → END_JAM_TIMER → BACKOFF → END_BACKOFF_TIMER → WAIT_IFG →
  re-tx via `phy->startFrameTransmission`. Meanwhile PLCA advances
  DS_COLLIDE → DS_DELAY_PENDING → DS_PENDING → DS_WAIT_MAC and accepts the
  re-tx there. Removing this loop breaks `worstcase.ini`'s 231.6 µs number.
  Keep verbatim.
- **The `WireJunction` module as a first-class node.** Multidrop topology
  is a chain of point-to-point links joined by T-junctions
  (`WireJunction.cc:83-139`); a T-junction rebroadcasts any signal from
  port K to every other port after per-segment delay. Reproducing the wire
  faithfully means these are real nodes on the event graph, with their own
  module_ids and their own event-handling rule. Fan-out at the sending PHY
  (the earlier "just enumerate peers" simplification) collapses this into
  the PHY and loses the ability to model chain topologies where different
  nodes see the same transmission at different times through different
  numbers of junctions. Multidrop scenarios rely on this — the coordinator
  is 100 cm from junction[0] but node[i] is 50 cm from junction[i], with
  N-1 junctions between them.
- **The 14-state control FSM and the 9-state data FSM in PLCA**, with their
  exact states and transition guards (§5.4, §5.5). Every timing INET
  produces derives from these. Any simplification here breaks the acceptance
  test.
- **The MAC-facing method-call surface `IEthernetCsmaPhy` names.** MAC calls
  `phy->startFrameTransmission(packet)`, `phy->endFrameTransmission()`,
  `phy->startSignalTransmission(JAM)`, `phy->endSignalTransmission()`.
  PHY / PLCA call back with `mac->handleCarrierSenseStart()`,
  `handleCarrierSenseEnd()`, `handleCollisionStart()`, `handleCollisionEnd()`,
  `handleReceptionStart()`, `handleReceptionEnd(kind, packet)`. In Julia
  these are functions on the state structs (`plca_start_frame_transmission!(plca,
  packet)`, `mac_handle_collision_start!(mac)` etc.), but the CALLS themselves
  and their ordering are load-bearing — PLCA fakes carrier-sense/collision
  events to MAC synthetically (§7 gotchas), and MAC's FSM responds to them.
- **The timing constants**, in bits (§6). Especially:
  - `beacon_timer_length = 20b`, `to_timer_length = 32b`
  - `pending_timer_length = 512b`, `commit_timer_length = 288b`,
    `burst_timer_length = 128b`, `beacon_det_timer_length = 22b`
  - `syncing_timer` = 1 ns (hardcoded, `EthernetPlca.cc:409`) — the
    intentionally-short CRS OFF/ON gap that lets followers detect end of
    BEACON.
- **The `to_timer` scheduling-priority hint** (`EthernetPlca.cc:115`, priority
  100). When a packet arrives at exactly TO-end, the TO boundary must be
  processed FIRST so the packet is registered as `packetPending` in the
  new state, not the old one. `worstcase.ini` depends on this.
- **`curID` incremented in CS_NEXT_TX_OPPORTUNITY, not on CS_SYNCING entry**
  (`EthernetPlca.cc:399-400`). The reset-to-0 happens at first TO start,
  not at beacon start, so coordinator and followers agree on TO boundaries.
- **The coordinator's cycle-close via CS_NEXT_TX_OPPORTUNITY T1 → CS_RESYNC
  when `curID >= plca_node_count`.** Followers do NOT auto-recycle; they
  wait for the next BEACON. This asymmetry is essential.
- **`bc < max_bc - 1 ? ESDBRS : ESD`** on burst-mode transmit (`EthernetPlca.cc:774`).
  ESDBRS is what tells the wire "another frame from me is coming; don't
  compete." Bestcase.ini's `max_bc=1` uses this exactly once per own TO.
- **`receiving = RX_DV || rx_cmd == CMD_COMMIT`** (but NOT `|| rx_cmd == CMD_BEACON`).
  A passing beacon is "carrier on but not receiving"; that distinction drives
  CS_EARLY_RECEIVE T1 vs T4 (`EthernetPlca.cc:451-467`).
- **Edge-detection on `CARRIER_STATUS` / `SIGNAL_STATUS`** — only *transitions*
  propagate from PLCA up to MAC. Emit the same value twice and MAC's
  `ASSERT(!CRS)` fires. This drives MAC's synthetic carrier-sense and
  is how PLCA "fakes" MAC's IEEE 802.3 view of the medium.
- **`rxSignals` vector for multiple simultaneous receptions** on PHY. Under
  PLCA-only operation the target scenarios never see two concurrent
  transmissions, so the vector holds ≤1 in practice — but the PHY code
  keeps the vector shape because (a) mixed-mode CSMA/CD-vs-PLCA validation
  configs (`validation.ini`) DO collide, and (b) a `WireJunction` may
  deliver two rx-starts to the same PHY at the same simtime if two peers
  transmit simultaneously into distinct wire segments feeding one junction.
  Keep the vector.
- **Signal truncation on abort** (`truncateSignal`, `SendOptions().finishTx(id)`).
  COMMIT signals are always cut short (their nominal bitLength is a safety
  ceiling); a truncated signal is delivered `bitError = true`. Preserving
  this makes CS_ABORT, CS_TRANSMIT-mid-COMMIT, and CS_BURST transitions
  reach the wire correctly.

### 3.3 Fix — INET's own defects and simplifications

- **`EthernetCsmaPhy::startSignalTransmission(COMMIT)` bitLength = 640** with
  the comment *"make it indefinite long?"* (`.cc:258`). This is a safety
  ceiling never intended to be reached; the signal is always cut short.
  Keep the ceiling and the truncation mechanism (§3.2), but the value is
  a define, not a magic number — put it in the timing table (§6).
- **`PMCD` set to `true` and never mutated** — dead variable (see §3.1).
- **The MAC txTimer includes `phy->getEsdLength()`** (`EthernetCsmaMac.cc:455`).
  This coupling exists because MAC and PLCA are separate modules and the
  PLCA "phy" reports a different ESD length than the raw PHY (`.h:202` vs
  `.h:121`). Keep faithfully; the polymorphic-length lookup becomes a
  method call `phy_esd_length(phy_or_plca)`, but the arithmetic is the same.

---

## 4. The Julia-native shape

### 4.1 Layering: MAC and PLCA and PHY, all stateful

Layering follows INET's `EthernetPlcaInterface` verbatim:

    app  →  queue  →  MAC  →  PLCA  →  PHY  →  wire (WireJunction …)

Each layer is a struct with its own FSM state and its own event handlers.
"Method calls" between layers (`phy->startFrameTransmission`,
`mac->handleCollisionStart`, etc.) become direct function calls between
structs; the `IEthernetCsmaMac` / `IEthernetCsmaPhy` abstractions collapse
to Julia dispatch. PLCA sits between MAC and PHY in both directions — the
same "shim implements both interfaces" pattern INET uses (`EthernetPlca.h:27`).

Each **node** carries:

```julia
mutable struct T1sNode
    address::UInt64                     # 6-byte MAC (padded)
    module_id::Int                      # for schedule!
    mac::MacState                       # 6-state FSM + tx/backoff/jam/ifg timers
    plca::PlcaState                     # control (14 states) + data (9 states) + timers
    phy::PhyState                       # 5-state FSM + tx/rx signal state
    app::AppState                       # source RNG, sink counter, packet queue
end
```

Each of the four state structs owns its own module_id in the scheduler
event graph. This preserves INET's semantic that "a MAC event" and "a PHY
event" arrive at distinct handlers with distinct handling; consolidating
into one module_id per node would fuse edges that INET's tie-breaking
rules keep distinct. It also lets the parallel scheduler assign the four
layers to the same cluster without loss, since inter-layer edges are
zero-delay.

Since the whole bus is one cluster (§4.2), the multi-module-id-per-node
layout costs one small `Vector{ModuleState}` per node and buys the exact
same event-ordering guarantees INET provides. See [Q5](#9-open-questions)
if measurement in phase 10 shows the extra dispatch is a hot spot.

### 4.2 The shared bus: `WireJunction` as a first-class node

INET's `WireJunction` (`physicallayer/wired/common/WireJunction.cc:83-139`)
is a dumb protocol-agnostic broadcaster: any signal arriving on port K is
duplicated to every other port. Multidrop networks are a CHAIN of
point-to-point wire segments joined by these T-junctions
(`MultidropNetwork.ned:44-49`):

    controller ---[100cm]--- j[0] ---[100cm]--- j[1] --- … --- j[N-1]
                              |                 |                |
                            [50cm]            [50cm]           [50cm]
                              |                 |                |
                           node[0]           node[1]         node[N-1]

Each `j[i]` is a separate node in the event graph, with its own module_id
and its own event handler. A tx from `node[0]` reaches `node[N-1]` through
`N` junctions in series, each contributing its own segment delay. Reducing
this to per-peer-delays computed at build time would (a) lose the
per-junction event trace that INET produces, (b) miss the case where two
peers transmit simultaneously into a single junction (§3.2 `rxSignals`
note), and (c) foreclose the mixed-mode topologies `mixed.ini` uses where
a switch's second port hangs off a junction.

**Structure**:

```julia
mutable struct WireJunctionState
    module_id::Int
    port_peers::Vector{Tuple{Int, SimTime}}   # (peer_module_id, segment_delay)
    # transient: signals currently in flight through this junction
    active_signals::Vector{ActiveSignal}
end

struct ActiveSignal
    from_port::Int                     # port index that received it
    kind::EthernetSignalKind
    packet::Union{Nothing,Packet}
    esd::EthernetEsdKind
    remaining::SimTime                 # tx duration still in flight
end
```

Junctions handle three event kinds:
- `junction_rx_start!(j, from_port, signal)` — schedule a `phy_rx_start!`
  event at every OTHER port after that port's segment delay.
- `junction_rx_end!(j, from_port, signal)` — schedule matching rx_end.
- `junction_signal_update!(j, from_port, signal, event)` — for truncation
  updates (COMMIT cut short mid-flight).

The wire graph — which PHYs connect to which junctions with what delays —
is built once from a `T1sTopology` value (§4.6) at `build_model` time.
See [Q6](#9-open-questions) about whether the junction's active-signals
tracking is a hot spot or a nothing-burger; for target scenarios it holds
1-2 entries at any time.

**Cluster and parallelism.** All nodes + all junctions are in one cluster
(everything transitively reachable from the wire). `model_barrier_module =
coordinator's MAC`; parallel execution gives no speedup. State this
explicitly in the model description so nobody wastes time trying
`--engine parallel`.

### 4.3 Signals as events, not as message objects

INET's `EthernetSignal` is a `cMessage` that carries a packet plus `kind`
(BEACON / COMMIT / DATA / JAM), `esd1`, `esd2`, `bitrate`. In Julia the
"signal" is just the argument to the scheduled callback:

```julia
struct WireEvent
    kind::EthernetSignalKind          # @enum: NONE BEACON COMMIT DATA JAM
    packet::Union{Nothing,Packet}     # nothing for BEACON/COMMIT
    esd::EthernetEsdKind              # ESDNONE ESD ESDBRS ESDOK ESDERR
    duration::SimTime                 # for computing rx_end
    src_module_id::Int                # for suppressing self-rx if needed
end
```

The event callback receives this and dispatches on `kind`. No allocations
per signal beyond the struct itself (isbits — three enums + a Packet
reference + two integers). Note: with `PacketModule` (from
[[packet-chunk-api]]), `Packet` is a mutable envelope holding an immutable
shared chunk, so passing a packet to N receivers = N envelopes + one shared
chunk. No copying.

### 4.4 Timers

Every PLCA timer is a `SimTime` deadline scheduled with `schedule!`. The
implementation choice: one callback per timer type, dispatch on `Symbol` or
`@enum` for which timer fired. Something like:

```julia
@enum PlcaTimer BEACON_TIMER BEACON_DET_TIMER TO_TIMER SYNCING_TIMER \
                BURST_TIMER HOLD_TIMER PENDING_TIMER COMMIT_TIMER TX_TIMER
```

Each PLCA state carries the currently-scheduled deadlines as a
`Dict{PlcaTimer, EventKey}` (or a `NTuple{9, Union{Nothing, EventKey}}` if
we want isbits — 9 timers, small, worth benchmarking). Cancellation via
the standard event-cancel API. When a timer callback fires, it looks up
which node it's for (via the module_id), which timer (via a passed
symbol/tag), and dispatches into `handle_with_control_fsm!` or
`handle_with_data_fsm!` as appropriate.

**The `to_timer` priority hint.** When schedule-time equality matters
(worstcase.ini: packet at TO-end + 1ps), we want to_timer's callback to run
before the packet-arrival callback. omnetpp-julia's scheduler resolves
same-time events by insertion order (per `RoutingModel` observation);
inspect its `EventKey` layout to see if we can bias insertion for
timers. If not, add 1 ns to any timer scheduled at the same simtime as
another already-pending event — mechanical, and the 1 ns doesn't propagate
beyond that single boundary. Recorded as [Q1](#9-open-questions).

### 4.5 FSMs — style choice

14 + 9 states. Two options:

- **Big `if/elseif` on `state`**: readable, one function per FSM (control,
  data). Easy to grep. All transitions visible in one place. This is what
  INET does (see `EthernetPlca.cc:344-586` for control, `.cc:592-793` for
  data). Wart: nested guards get long.
- **Dispatch on `Val{state}`**: one method per state, transitions become
  case-per-event. Prettier but scatters the state machine across the file
  and hides the transition table.

**Recommendation: big `if/elseif`.** The FSM IS the plan's authoritative
statement of the protocol; keeping it linear preserves the transition table
as visible-in-source. `Val{state}` scattering is exactly what makes INET
harder to review than it should be, despite C++ having no other choice.
This is a §9 question if a first-draft implementation shows the linear
form has grown unmanageable.

---

## 5. Per-component design

### 5.1 Ethernet frame chunks via `@header`

The three headers we need. These slot straight into `Omnetpp.PacketModule`
(the [[packet-chunk-api]] delivery).

```julia
@header EthernetMacHeader begin
    dst_mac_hi   :: UInt16    # 16 bits + 32 bits = 48-bit MAC as two fields
    dst_mac_lo   :: UInt32
    src_mac_hi   :: UInt16
    src_mac_lo   :: UInt32
    ethertype    :: UInt16
end   # 14 bytes, matches INET

@header EthernetFcs begin
    fcs :: UInt32
end   # 4 bytes

# EthernetPhyHeader is opaque — treat as Filler(Bytes(8)); no fields ever read.
```

The 46-byte minimum payload padding is added by a `frame_bytes` helper:

```julia
function build_ethernet_frame(src::UInt64, dst::UInt64,
                              ethertype::UInt16, payload::Chunk)
    hdr = EthernetMacHeader(...)                  # split MAC into hi/lo
    pk = Packet(payload)
    pushfirst!(pk, hdr)
    # Pad to MIN_FRAME_BYTES = 64 (excluding preamble/SFD but including FCS)
    frame_bytes = data_length(pk) + Bytes(4)      # +FCS
    if frame_bytes < Bytes(64)
        push!(pk, Filler(Bytes(64) - frame_bytes - Bytes(4); fill = 0x00))
    end
    push!(pk, EthernetFcs(0x00000000))            # declared mode; zero-filled
    return pk
end
```

The tags system carries source/dest control info too if we want (§4.3 of the
packet plan). For the T1S model we don't need any — the destination is on
the wire header directly.

### 5.2 WireJunction — the T-junction

Structure and event handling are in §4.2. Full API:

```julia
mutable struct WireJunctionState
    module_id::Int
    port_peers::Vector{Tuple{Int, SimTime}}   # (peer_module_id, segment_delay)
    active_signals::Vector{ActiveSignal}
end

# Events:
junction_rx_start!(j::WireJunctionState, from_port::Int, sig::WireEvent)
junction_rx_end!(j::WireJunctionState, from_port::Int, sig::WireEvent)
junction_signal_update!(j, from_port, sig, kind::Symbol)  # for truncation
```

Handling of `junction_rx_start!`: for every port `p ≠ from_port`, schedule
`phy_rx_start!(peer_module_id[p], sig)` at `now + segment_delay[p]`.

No FSM, no timers on the junction itself. Truncation propagates: when a
sending PHY truncates its own signal (§3.2), a `junction_signal_update!`
walks the chain notifying each downstream junction and each receiving PHY.

### 5.3 PHY

5-state FSM: `IDLE`, `TRANSMITTING`, `RECEIVING`, `COLLISION`, `CRS_ON`
(`EthernetCsmaPhy.h:34-40`). All five kept — COLLISION fires when the PHY
sees an rx starting while it's transmitting, which happens on the mixed
CSMA/CD-vs-PLCA validation config and defensively when a junction delivers
two simultaneous rxs (§3.2 `rxSignals` note).

State:

```julia
mutable struct PhyState
    fsm::PhyFsmState
    current_tx::Union{Nothing, WireEvent}
    rx_signals::Vector{RxSignal}              # multiple concurrent rxs
    tx_end_time::SimTime
    rx_end_timer::Union{Nothing, EventKey}    # fires at max(rx_end)
    crs_off_timer::Union{Nothing, EventKey}   # fires at max(rx_end, tx_end)
end

struct RxSignal
    from_peer_port::Int
    signal::WireEvent
    rx_end_time::SimTime
end
```

Events fanning in:
- From PLCA (via method call): `phy_start_frame_transmission!(phy, packet, esd)`,
  `phy_end_frame_transmission!(phy)`, `phy_start_signal_transmission!(phy, kind)`
  (BEACON/COMMIT), `phy_end_signal_transmission!(phy)`
- From peer junctions (scheduled): `phy_rx_start!(phy, sig)`,
  `phy_rx_update!(phy, sig, kind)`, `phy_rx_end!(phy)`
- Timer callbacks: `phy_rx_end_timer!`, `phy_crs_off_timer!`

Fanning out:
- To PLCA (via method call): `plca_carrier_sense_start!/end!`,
  `plca_collision_start!/end!`, `plca_reception_start!/end!`
- To bus (scheduled to the immediate junction the PHY is wired to):
  `junction_rx_start!` etc.

The transition table follows INET's `EthernetCsmaPhy.cc:117-237` verbatim
(reproduced in the analysis, section 3.2). Same-time-tie-breaking:
`rx_end_timer` should fire AFTER concurrent starts (INET uses SHRT_MIN
priority); `crs_off_timer` should fire FIRST at end-of-tx (INET uses
SHRT_MAX). See [Q1](#9-open-questions) for how to translate.

### 5.4 PLCA control FSM

14 states. The complete transition table:

```
CS_DISABLE:
  T1: local_nodeID != 0                       → CS_RESYNC
  T2: local_nodeID == 0                       → CS_RECOVER

CS_RESYNC:
  T1: local_nodeID != 0 && CRS                → CS_EARLY_RECEIVE
  T2: !CRS && local_nodeID == 0               → CS_SEND_BEACON

CS_RECOVER:
  T1: (unconditional)                         → CS_WAIT_TO

CS_SEND_BEACON:
  Enter: sched beacon_timer(20b); tx_cmd=BEACON; phy_start_signal_tx(BEACON)
  T1: beacon_timer not scheduled              → CS_SYNCING

CS_SYNCING:
  Enter: end BEACON cmd
         if coordinator: sched syncing_timer(1ns)     (§3.2)
  T1: !CRS && syncing_timer not scheduled     → CS_WAIT_TO (curID=0, emit cycle stats)

CS_WAIT_TO:
  Enter: sched to_timer(32b, priority=100)     (§3.2 — priority matters)
  T1: CRS                                     → CS_EARLY_RECEIVE
  T2: curID == local_nodeID && packetPending && !CRS
                                              → CS_COMMIT
  T3: !to_timer && curID != local_nodeID && !CRS
                                              → CS_NEXT_TX_OPPORTUNITY
  T4: curID == local_nodeID && !packetPending && !CRS
                                              → CS_YIELD

CS_EARLY_RECEIVE:
  Enter: cancel to_timer; reschedule beacon_det_timer(22b)
  T1: !coord && !receiving && (rx_cmd==BEACON ||
                               (!CRS && beacon_det_timer scheduled))
                                              → CS_SYNCING
  T2: !coord && !CRS && rx_cmd != BEACON && !beacon_det_timer
                                              → CS_RESYNC
  T3: !CRS && coord                           → CS_RECOVER
  T4: receiving && CRS                        → CS_RECEIVE

CS_COMMIT:
  Enter: tx_cmd=COMMIT; phy_start_signal_tx(COMMIT); committed=true;
         cancel to_timer; bc=0
         fire COMMIT_TO into data FSM
  T1: TX_EN                                   → CS_TRANSMIT
  T2: !TX_EN && !packetPending                → CS_ABORT

CS_YIELD:
  Enter: emit transmitOpportunityUsed=0
  T1: CRS && to_timer scheduled               → CS_EARLY_RECEIVE
  T2: !to_timer                               → CS_NEXT_TX_OPPORTUNITY

CS_RECEIVE:
  T1: !CRS                                    → CS_NEXT_TX_OPPORTUNITY

CS_TRANSMIT:
  Enter: end tx_cmd if scheduled
         if bc >= max_bc: committed=false
  T1: !TX_EN && !CRS && bc >= max_bc          → CS_NEXT_TX_OPPORTUNITY
  T2: !TX_EN && bc < max_bc                   → CS_BURST

CS_BURST:
  Enter: bc++; tx_cmd=COMMIT; phy_start_signal_tx(COMMIT);
         sched burst_timer(128b)
  T1: TX_EN                                   → CS_TRANSMIT (cancel burst_timer)
  T2: !TX_EN && !burst_timer                  → CS_ABORT

CS_ABORT:
  Enter: end tx_cmd with ESD
  T1: !CRS                                    → CS_NEXT_TX_OPPORTUNITY

CS_NEXT_TX_OPPORTUNITY:
  Enter: emit TO stats; curID++; committed=false
  T1: local_nodeID == 0 && curID >= plca_node_count
                                              → CS_RESYNC       (coordinator only)
  T2: (unconditional)                         → CS_WAIT_TO
```

Every state's Enter action runs `handle_with_control_fsm!` again to
re-evaluate transitions on the new state. Every self-message handler
(any timer callback) also calls `handle_with_control_fsm!` first.

### 5.5 PLCA data FSM

9 states. Interacts with MAC via `packetPending`, `TX_EN`, and the
synthetic `handleCollisionStart` / `handleCollisionEnd` edges — verbatim
INET, faithful.

```
DS_IDLE:
  T1: RECEPTION_START && receiving           → DS_RECEIVE
  T2: START_FRAME_TRANSMISSION (app→plca)    → DS_HOLD (currentTx = pkt)

DS_WAIT_IDLE:
  Same as DS_IDLE but doesn't accept incoming rx-init;
  T1: CARRIER_SENSE_END                      → DS_IDLE
  T2: START_FRAME_TRANSMISSION               → DS_TRANSMIT

DS_RECEIVE:
  Enter: CARRIER_STATUS = (CRS && rx_cmd != COMMIT) ? ON : OFF
  T1: RECEPTION_END                          → DS_IDLE
  T2: START_FRAME_TRANSMISSION               → DS_COLLIDE (drop pkt)

DS_HOLD:
  Enter: packetPending=true; CARRIER_STATUS=ON;
         sched hold_timer(4 * delay_line_length / bitrate)   [400 bits = 40 µs default]
  T1: END_HOLD_TIMER                         → DS_COLLIDE (drop currentTx)
  T2: RECEPTION_START && receiving           → DS_COLLIDE
  T3: COMMIT_TO (from CS_COMMIT)             → DS_TRANSMIT

DS_COLLIDE:
  Enter: packetPending=false; CARRIER_STATUS=ON; SIGNAL_STATUS=SIGNAL_ERROR
         (raises SIGNAL_STATUS edge → MAC's handleCollisionStart → MAC
          enters JAMMING → sched jamTimer(32b) → MAC calls
          phy->startSignalTransmission(JAM) → PLCA absorbs (no-op) →
          jamTimer expires → MAC calls phy->endSignalTransmission →
          PLCA fires END_SIGNAL_TRANSMISSION → the T1 transition below)
  T1: END_SIGNAL_TRANSMISSION                → DS_DELAY_PENDING

DS_DELAY_PENDING:
  Enter: SIGNAL_STATUS=NO_ERR; sched pending_timer(512b) [51.2 µs]
  T1: END_PENDING_TIMER                      → DS_PENDING

DS_PENDING:
  Enter: packetPending=true
  T1: COMMIT_TO                              → DS_WAIT_MAC

DS_WAIT_MAC:
  Enter: CARRIER_STATUS=OFF; sched commit_timer(288b) [28.8 µs]
  T1: START_FRAME_TRANSMISSION               → DS_TRANSMIT (cancel commit_timer)
  T2: END_COMMIT_TIMER                       → DS_WAIT_IDLE

DS_TRANSMIT:
  Enter: packetPending=false; CARRIER_STATUS=ON;
         SIGNAL_STATUS = COL ? ERR : OK;
         TX_EN=true; end commit signal;
         sched tx_timer((dataBits + 64 + 8)/bitrate);
         phy_start_tx(DATA, currentTx, esd = bc<max_bc-1 ? ESDBRS : ESD)
  T1: END_TX_TIMER                           → DS_WAIT_IDLE
                                               (delete currentTx; phy_end_tx)
```

The two FSMs interact via `packetPending`, `TX_EN`, `CARRIER_STATUS`,
`SIGNAL_STATUS`, and the fires (COMMIT_TO, END_SIGNAL_TRANSMISSION,
START_FRAME_TRANSMISSION). Every data-FSM state entry that changes any of
these reruns the control FSM as a delayed action, mirroring INET.

### 5.6 MAC — the 6-state FSM

Faithful to `EthernetCsmaMac.cc:184-314`. State:

```julia
mutable struct MacState
    module_id::Int
    fsm::MacFsmState                # IDLE WAIT_IFG TRANSMITTING JAMMING BACKOFF RECEIVING
    current_tx_frame::Union{Nothing, Packet}
    num_retries::Int
    carrier_sense::Bool
    collision::Bool
    tx_timer::Union{Nothing, EventKey}
    ifg_timer::Union{Nothing, EventKey}
    jam_timer::Union{Nothing, EventKey}
    backoff_timer::Union{Nothing, EventKey}
    rng::MersenneTwister             # seeded from node address (per §5.7)
    # config:
    bitrate::Float64
    fcs_mode::Symbol                 # :declared for target scenarios (§3.1)
    promiscuous::Bool
    slot_bit_length::Int             # 512 for 10Mb
end
```

Transition table (`state × event → next / action`), lifted from analysis §3.1:

| State | Event | Guard | Next | Action |
|---|---|---|---|---|
| IDLE | UPPER_PACKET | — | TRANSMITTING | `set_current_transmission!` |
| IDLE | CARRIER_SENSE_START | — | RECEIVING | — |
| WAIT_IFG | END_IFG_TIMER | `current_tx_frame != nothing` | TRANSMITTING | — |
| WAIT_IFG | END_IFG_TIMER | queue non-empty | TRANSMITTING | dequeue |
| WAIT_IFG | END_IFG_TIMER | idle | IDLE | — |
| WAIT_IFG | END_IFG_TIMER | carrier_sense | RECEIVING | — |
| WAIT_IFG | LOWER_PACKET | — | stay | `process_received_frame!` |
| TRANSMITTING | END_TX_TIMER | !carrier_sense | WAIT_IFG | `plca_end_frame_transmission!` |
| TRANSMITTING | END_TX_TIMER | carrier_sense | RECEIVING | `plca_end_frame_transmission!` |
| TRANSMITTING | COLLISION_START | — | JAMMING | abort_tx; `plca_end_frame_transmission!`; `plca_start_signal_transmission!(JAM)` |
| JAMMING | END_JAM_TIMER | `retries==MAX_ATTEMPTS && !CRS` | WAIT_IFG | `plca_end_signal_transmission!`; give_up_tx |
| JAMMING | END_JAM_TIMER | `retries==MAX_ATTEMPTS && CRS` | RECEIVING | idem |
| JAMMING | END_JAM_TIMER | `retries<MAX_ATTEMPTS` | BACKOFF | `plca_end_signal_transmission!`; retry_tx (retries++) |
| BACKOFF | END_BACKOFF_TIMER | !CRS | WAIT_IFG | — |
| BACKOFF | END_BACKOFF_TIMER | CRS | RECEIVING | — |
| RECEIVING | CARRIER_SENSE_END | — | WAIT_IFG | — |

Timer durations:
- `tx_timer` = `(data_bits + ETHERNET_PHY_HEADER_LEN.bits +
  phy_esd_length(plca).bits) / bitrate` (`EthernetCsmaMac.cc:452-457`).
  Under PLCA, `phy_esd_length` = 8 bits (`.h:202`). Skip either term and
  MAC calls `plca_end_frame_transmission!` off by 6.4 µs or 0.8 µs.
- `ifg_timer` = `INTERFRAME_GAP_BITS(96) / bitrate` = 9.6 µs @ 10 Mb.
- `jam_timer` = `JAM_SIGNAL_BYTES(4) * 8 / bitrate` = 3.2 µs @ 10 Mb.
- `backoff_timer` = `slot_number * slot_bit_length / bitrate` where
  `slot_number = rand(rng, 0:min(2^num_retries, 2^BACKOFF_RANGE_LIMIT) - 1)`.
  Classical truncated BEB. Deterministic given the RNG.

**Interface to PLCA (upward from MAC's viewpoint)**:
- `plca_start_frame_transmission!(plca, packet)` — called from TRANSMITTING
  entry
- `plca_end_frame_transmission!(plca)` — called from END_TX_TIMER
- `plca_start_signal_transmission!(plca, kind::EthernetSignalKind)` — from
  JAMMING entry (kind = JAM; PLCA no-ops JAM per §3.2 gotcha)
- `plca_end_signal_transmission!(plca)` — from END_JAM_TIMER; triggers
  PLCA's DS_COLLIDE → DS_DELAY_PENDING transition

**Interface from PLCA (downward, PLCA reports state to MAC)**:
- `mac_handle_carrier_sense_start!(mac)`, `mac_handle_carrier_sense_end!(mac)`
- `mac_handle_collision_start!(mac)`, `mac_handle_collision_end!(mac)`
- `mac_handle_reception_start!(mac)` — currently a no-op in INET
  (`EthernetCsmaMac.cc`); kept as a hook
- `mac_handle_reception_end!(mac, kind, packet)` — DATA delivered; kind
  filters out JAM (asserted nullptr)

**Non-obvious details preserved** (analysis §3.1):
- `ifg_timer` re-evaluates the queue on expiry and can dequeue a new
  packet.
- RNG for BACKOFF must be per-node and deterministically seeded, or
  golden-hash reproduction breaks. Use the same seed pattern as
  `RoutingModel` (from node address).

### 5.7 App layer — queue + source + sink

INET's `EthernetSourceApp` / `EthernetSinkApp` are thin NED wrappers over
an `ActivePacketSource` and a socket layer. Simplified for the target
scenarios:

```julia
mutable struct AppState
    module_id::Int
    address::UInt64                  # this node's MAC (for src field)
    queue::Vector{Packet}            # egress queue (EthernetQueue in INET)
    rng::MersenneTwister             # for random inter-arrival / packet sizes
    # source config (nothing → sink-only node):
    source::Union{Nothing, SourceConfig}
    # sink counters:
    packets_received::Int
    total_e2e_delay::SimTime
end

struct SourceConfig
    dst_address::UInt64
    packet_length_min::Int           # in bytes
    packet_length_max::Int
    interval_kind::Symbol            # :fixed :uniform :poisson
    interval_min::Float64            # seconds
    interval_max::Float64
    initial_offset::SimTime
end
```

**Generation**: on `app_generate!` for a source node, build a frame with
`build_ethernet_frame(src, dst, ETHERTYPE_IPV4, Filler(Bytes(pk_len)))`,
push onto `queue`, then call `mac_upper_packet!(mac)` — MAC's FSM handles
the rest. Schedule the next `app_generate!` after `interval_kind`-drawn
delay.

**Reception**: MAC calls `app_receive!(app, packet)` on
`mac_handle_reception_end!` with a DATA frame whose dst_addr matches this
node's address (MAC-level filter). Increment `packets_received`; compute
e2e delay from a `CreationTimeTag` on the packet (using
[[packet-chunk-api]]'s Tag system).

**Per-node RNG**: `MersenneTwister(address)`, same seeding pattern as
`RoutingModel`, so golden hashes reproduce.

For the three target scenarios:
- **`notraffic`**: `source = nothing` on every node. No RNG use.
- **`bestcase`**: `interval_kind = :fixed`, `initial_offset` tuned so
  packets arrive at own-TO start. Deterministic.
- **`worstcase`**: same but `initial_offset` shifted +1 ps past own-TO end.
  Deterministic.

Poisson / uniform intervals are follow-ups (F2), not required for the
three-example acceptance.

---

## 6. Timing constants — one table, cite once

All in bits (÷ bitrate for seconds). Bitrate = 10 Mb/s → 1 bit = 100 ns.
Source: `EthernetPlca.ned`, `Ethernet.h`, `EthernetPhyConstants.h`.

| Constant | Value | Seconds @ 10Mb | What it gates |
|---|---|---|---|
| Bit time | 100 ns | — | Everything |
| IFG | 96 b | 9.6 µs | Post-tx recovery (folded into tx_timer) |
| PHY hdr | 64 b (8 B) | 6.4 µs | Prepended to every DATA signal |
| PHY ESD | 8 b (1 B) | 0.8 µs | Appended to every DATA signal |
| BEACON on wire | 20 b | 2.0 µs | `beacon_timer_length` |
| `to_timer_length` | 32 b | 3.2 µs | Empty-TO duration |
| `beacon_det_timer_length` | 22 b | 2.2 µs | Beacon-detection window in CS_EARLY_RECEIVE |
| `burst_timer_length` | 128 b | 12.8 µs | Max wait in CS_BURST for next frame |
| `pending_timer_length` | 512 b | 51.2 µs | DS_DELAY_PENDING duration |
| `commit_timer_length` | 288 b | 28.8 µs | DS_WAIT_MAC fallback |
| `syncing_timer` | 1 ns (hard) | 1 ns | Coordinator-only CRS-off gap |
| MAC `jam_timer` | 32 b | 3.2 µs | JAMMING duration; fires MAC's endSignal → PLCA DS_COLLIDE advance |
| MAC `MAX_ATTEMPTS` | 16 | — | CSMA/CD retry cap (`Ethernet.h:43`) |
| MAC `BACKOFF_RANGE_LIMIT` | 10 | — | Truncated BEB cap (`Ethernet.h:44`) |
| MAC `slot_bit_length` (10Mb) | 512 b | 51.2 µs | Slot time for MAC BACKOFF |
| COMMIT signal ceiling | 640 b | 64 µs | `EthernetCsmaPhy.cc:258`; always truncated |
| `hold_timer` | 4 × dll_length b | 40 µs (default) | DS_HOLD max wait |
| Frame duration | (bits + 64 + 8) / bitrate | — | tx_timer |
| Segment delay | length_m / 2×10⁸ | — | Cable propagation |

`worstcase.ini`'s expected 231.6 µs pending delay = `(32b + 3×73B×8 + 3×128b
+ 20b + 32b + 96b) / 10Mb`, i.e. 1 empty TO (32b) + 3 data frames (73B each
including hdr/pad/fcs/PHY-hdr/ESD) + 3 COMMITs (128b each) + 1 BEACON (20b)
+ own TO (32b) + IFG (96b). If our model doesn't reproduce this exactly, we
have the wrong duration on something in the table.

---

## 7. Where Julia is genuinely better

Not translations — outcomes that differ.

1. **No `Ptr<T>` / `take` / `dup` ceremony.** Julia GC + `PacketModule`'s
   `dup` = O(1) envelope-copy-with-shared-content. Broadcasting one packet
   through N junctions to M receivers costs N+M mutable envelopes plus one
   shared payload chunk.
2. **`@header`-generated codec.** Ethernet MAC header and FCS are two
   `@header` declarations, not two `.msg` files + two hand-written `.cc`
   serializers.
3. **The state machine reads as its transition table.** With `@enum` states
   and `if/elseif`-per-state, the source IS the spec. INET's C++ FSM
   helper macros work but require reading two files (`.h` and `.cc`) to
   see one transition. This applies to all four FSMs (MAC, PLCA control,
   PLCA data, PHY).
4. **No cModule / cMessage / cGate scaffolding.** The whole model is
   `AbstractModel` + `Vector{T1sNode}` + `Vector{WireJunctionState}` +
   `schedule!` — the same pattern as `RoutingModel` and `MM1KModel`.
5. **Direct method calls between layers.** MAC → PLCA → PHY calls are
   plain Julia function calls with strongly typed state arguments; no
   `IEthernetCsmaPhy` / `IEthernetCsmaMac` abstract-class ceremony.
   Reads: `plca_start_frame_transmission!(node.plca, packet)`.
6. **Priority-based FES tie-breaking becomes explicit.** OMNeT++ needs
   `SHRT_MIN` / `SHRT_MAX` priorities on multiple timers because its FES
   ordering is not stable across event kinds. Julia's scheduler has
   insertion-order tie-breaking (RoutingModel relies on this). We resolve
   the three cases (§3.1, `to_timer`, `crs_off_timer`, `rx_end_timer`)
   with schedule-order tweaks. See [Q1].
7. **Reproducibility gate is the same.** Pin the network hash for each
   ported example (`test/GOLDEN.md`-style), and we get seq-vs-par identity
   for free (though the "parallel" execution here is single-cluster, so
   this is a formality).

---

## 8. Staged build

Same shape as [[packet-chunk-api]]'s §8: each phase ports its slice of INET
behaviour and passes its slice of the acceptance tests before the next
begins. Order chosen so `notraffic.ini` is reproducible as early as
possible — that lands the control FSM, which is the hardest FSM.

### Phase 1 — headers and frame construction
`@header EthernetMacHeader`, `@header EthernetFcs`, `build_ethernet_frame`
helper. Cover fields, padding, FCS placeholder. Test: build a frame,
round-trip through `to_bytes`/`from_bytes`, check length + padding. No
protocol behaviour yet.

### Phase 2 — WireEvent + PHY state machine
The 5-state PHY (IDLE, TRANSMITTING, RECEIVING, COLLISION, CRS_ON) plus
its timers (`rx_end_timer`, `crs_off_timer`). Test with a single-node
model: `phy_start_frame_transmission!` → tx_timer fires → CRS_ON →
`crs_off_timer` → IDLE. Also inject a synthetic `phy_rx_start!`. No PLCA
yet. Same-time tie-breaking (§Q1) resolved here — both `rx_end_timer`
and `crs_off_timer` cases are exercised.

### Phase 3 — WireJunction + multidrop topology
`WireJunctionState`, `junction_rx_start!` / `_end!` / `_signal_update!`.
Build a two-node model with one junction between them; assert rx arrives
at the peer with the correct segment-delay latency. Extend to a chain of
three junctions and confirm rx-at-far-end = sum of segment delays.
**Acceptance: signal traces match INET's per-junction event timestamps
byte-for-byte on a 4-node chain.**

### Phase 4 — PLCA control FSM
14 states as tabulated in §5.4. Timers: `beacon_timer`, `beacon_det_timer`,
`to_timer` (priority 100), `syncing_timer`, `burst_timer`. Test skeleton:
run the coordinator alone and observe BEACON emission cadence; run a
follower alone and observe it detects synthetic BEACONs. No MAC yet —
`packetPending` is always false, so CS_COMMIT branches don't fire.
**Acceptance: reproduce `notraffic.ini`'s `curID` trace and per-cycle
`cycleLength` exactly**, over 100 µs of simulation. Pin the network hash.

### Phase 5 — PLCA data FSM (transmit path only)
9 states as §5.5, but only exercise DS_IDLE → DS_WAIT_IDLE → DS_TRANSMIT →
DS_WAIT_IDLE. Timers: `tx_timer`. Skip DS_HOLD / DS_COLLIDE /
DS_DELAY_PENDING / DS_PENDING / DS_WAIT_MAC for now — they're the
missed-TO recovery path. Uses a stub `mac_upper_packet!` that immediately
delegates to `plca_start_frame_transmission!` without going through the
MAC FSM.

### Phase 6 — MAC — the 6-state FSM
`MacState` as §5.6, all six states, timers, and the `mac_handle_*` /
`plca_*` method interfaces. Wire MAC BETWEEN app and PLCA: app pushes into
`mac.queue`, MAC dequeues and calls `plca_start_frame_transmission!`,
PLCA reports back. In this phase the JAMMING/BACKOFF branches are dead
(no DS_COLLIDE fires yet), so their code path is exercised by unit tests
only.
**Acceptance: reproduce `bestcase.ini`'s cycle length and per-node
transmit timestamps.** Pin the network hash. This is the first test where
the whole stack (app → MAC → PLCA → PHY → junction → peer PHY → PLCA →
MAC → app) is live.

### Phase 7 — PLCA data FSM (recovery path)
DS_HOLD, DS_COLLIDE, DS_DELAY_PENDING, DS_PENDING, DS_WAIT_MAC. Timers:
`hold_timer`, `pending_timer`, `commit_timer`. Because MAC is present
(Phase 6), DS_COLLIDE's END_SIGNAL_TRANSMISSION comes from MAC's
END_JAM_TIMER as INET intends — no internal-timer hack.
**Acceptance: reproduce `worstcase.ini`'s 231.6 µs pending delay for
node[0].** Pin the network hash. This is the acceptance test for the
faithful MAC ↔ PLCA collision dance: if MAC's random BACKOFF diverges
from a fresh MersenneTwister-seeded stream, hashes drift here.

### Phase 8 — App layer: source, sink, queue
`AppState` as §5.7. Deterministic source (`interval_kind = :fixed`),
sink counters (`packets_received`, `total_e2e_delay`). Egress queue with
`packetCapacity` (matches INET's `EthernetQueue` default 1000). Enough
for latency/throughput counting on the three target scenarios; Poisson
and uniform inter-arrival are follow-up F2.

### Phase 9 — model wrapping + lifecycle
`T1sModel <: AbstractModel`, `T1sTopology` value (§4.2), with `n_nodes`,
`max_bc`, `plca_node_count`, `local_id` per node, all PLCA timer constants
as NED-equivalent parameters. `build_model` / `model_module_count` /
`schedule_initial_events!` / `model_barrier_module`. Golden hashes in
`test/GOLDEN.md`. Note in the model description that parallel execution
provides no speedup (single cluster). See [[project_omnetpp_cpp_compatibility]]
if the same hashes want cross-checking against a jsim/INET run.

### Phase 10 — docs and close-out
`documentation/ten-base-t1s.md`, and update this plan with what the build
changed about the design.

### Follow-up phases (not required for close-out)

- **F1** — burst mode `max_bc > 1` for the throughput and paper configs
  (needs CS_BURST + DS_TRANSMIT loop; already covered by the design but
  the target scenarios all use `max_bc=1`).
- **F2** — Poisson / uniform inter-arrival for smoke / paper / throughput.
- **F3** — Mixed CSMA/CD-vs-PLCA validation config (`validation.ini`).
  The MAC is already faithful (§5.6), so the CSMA/CD side is already
  present; F3 is about running a topology WITHOUT PLCA so real
  collisions occur (needs a mode-select on the interface: PLCA-on vs
  PLCA-off, matching INET's `plca.typename = ""` NED trick).
- **F4** — Real FCS computation (`fcsMode = "computed"`). Not needed for
  target scenarios; add when a scenario surfaces the requirement.

---

## 9. Open questions

1. **Same-time event ordering across timer kinds.** INET uses cMessage
   scheduling priorities (`to_timer` priority=100 in `EthernetPlca.cc:115`,
   `crs_off_timer` SHRT_MAX in `EthernetCsmaPhy.h:82`, `rx_end_timer`
   SHRT_MIN in `EthernetCsmaPhy.h:81`) to disambiguate when multiple
   events fire at the exact same simtime. omnetpp-julia's scheduler
   resolves same-time events by insertion order (per RoutingModel
   observation), which is a WEAKER guarantee — it depends on the order
   the code schedules, not on an explicit priority. Decide in phase 2
   (PHY tie-breaks) and phase 4 (`to_timer`): either add priority to the
   `EventKey` layout (invasive; touches the scheduler), or arrange
   schedule-order at each of the three sites where it actually matters.
   Lean: schedule-order tweak, small fixed set.
2. **Per-layer timer bookkeeping shape.** Each layer (MAC has 4 timers,
   PLCA has 9, PHY has 2) needs to store scheduled `EventKey`s so they
   can be cancelled. `Dict{Symbol, EventKey}` (2 words per entry,
   mutable, easy to reason about) vs a fixed-shape struct with a named
   field per timer (`isbits`-friendlier, no allocation, needs setproperty!).
   Measure in phase 4; the fixed struct is only worth it if profiling
   shows the Dict is a hot spot.
3. **Ethernet MAC address as one `UInt64` or two `UInt16`+`UInt32`?**
   The `@header` form splits into `dst_mac_hi::UInt16 + dst_mac_lo::UInt32`
   because `@header` doesn't (yet) support 48-bit types. Alternative: add
   a `UInt48` alias to `PacketModule` that generates the split under the
   hood. Deferring; the split-field form is honest and readable.
4. **`hold_timer` default (`4 * delay_line_length / bitrate`)** is 40 µs
   with the default `delay_line_length=100`. The default is generous —
   the CS_COMMIT trigger usually fires well within a `to_timer` (3.2 µs).
   In INET this is a placeholder for real DLL depth. Keep the arithmetic
   as an NED-equivalent parameter; note that the target scenarios don't
   exercise the timeout path.
5. **Four state structs per node with separate module_ids: overhead?**
   Every node has MAC + PLCA + PHY + App, each with its own `module_id`.
   That's 4× the per-node module count vs consolidating. Impact on the
   scheduler's per-event dispatch is unclear until phase 9 measures it.
   Contingency: if it's a hot spot, consolidate the 4 module_ids into
   one T1sNode-level id and route by struct-type dispatch on the callback.
   The transition tables stay intact — only the schedule keys change.
6. **`WireJunction` active-signals list: hot path or nothing?** In target
   scenarios each junction holds 1-2 active signals at any time; in mixed
   configs (validation.ini) or during transients it could hold more.
   Vector is fine. Only worth a shape change if a profiler surfaces it.
7. **MAC BACKOFF RNG stream isolation.** MAC's `BACKOFF` state calls
   `intuniform(rng, 0, backoff_range - 1)`. This RNG is `MersenneTwister(address)`
   in our design (§5.7), SHARED with the app-layer traffic source. Under
   PLCA the BACKOFF fires on legitimate DS_COLLIDE (missed-TO recovery,
   worstcase.ini), which changes what the app-layer RNG draws next —
   entangling protocol-timing with traffic-generation for identical
   downstream determinism. That's fine as long as we own the reference
   implementation, but if we ever cross-check against jsim/INET
   (see [[project_omnetpp_cpp_compatibility]]), we need to know whether
   INET separates the streams. Bookkeeping: verify against INET source
   before phase 7.

## 9.1 Rejected alternatives

- **Consolidate MAC into PLCA — treat MAC as a stateless frame formatter.**
  Rejected on this iteration (originally the plan's approach). Rationale:
  the target `worstcase.ini` example depends on MAC's JAMMING/BACKOFF
  interlock with PLCA's DS_COLLIDE → END_SIGNAL_TRANSMISSION timing.
  Faking it with an internal `jam_delay` PLCA timer works for the
  no-MAC-RNG case but changes MAC's random BACKOFF exposure to the
  RNG stream, which cascades into any golden hash comparison with INET.
  Faithful MAC preserves the reference semantics; the "consolidation"
  saving was six MAC states, not a lot.
- **Fan out at the sending PHY (skip `WireJunction` as a first-class
  module).** Rejected on this iteration (originally the plan's approach).
  Rationale: multidrop topologies aren't stars — they're chains
  (`MultidropNetwork.ned:44-49`), where different nodes see the same
  transmission after passing through different counts of junctions.
  A per-peer-delay vector at the sender loses (a) the per-junction event
  trace, (b) the case where two peers transmit simultaneously into one
  junction, and (c) the ability to model the mixed switch+multidrop
  topology `mixed.ini` uses. The extra event hop per junction is real
  but small, and it's exactly what INET's timing accounts for.
- **Use a projectural (`@document`) representation for the FSMs so a
  live-inspect UI falls out.** Tempting because it composes with the
  projectured pattern the rest of `omnetpp-julia` uses (`Omnetpp.jl:6-9`).
  Rejected for the hot path: a per-state cell would allocate on every
  transition. The inspector should be a projection *over* PLCA state, not
  the state itself — same split we drew in [[packet-chunk-api]] §6.7.
- **Skip `curID`'s specific `plca_node_count` recycle rule and treat all
  nodes as symmetric with respect to cycle boundaries.** Rejected:
  followers must NOT auto-recycle; they wait for the next BEACON. The
  asymmetry is what makes the coordinator failure model deterministic
  (a lost coordinator stalls the bus; INET has no coordinator election).
- **Use OMNeT++-compatible `.msg`-generated header codecs.** Rejected;
  we have `@header` (from [[packet-chunk-api]]). The two headers we need
  are one screen of `@header` declarations.
- **Drop the CSMA/CD JAMMING and BACKOFF states from MAC because "under
  PLCA the wire never collides."** Rejected as premature: JAMMING and
  BACKOFF DO fire in normal PLCA operation whenever PLCA's DS_COLLIDE
  raises SIGNAL_ERROR to MAC (analysis §7 gotchas). What NEVER fires under
  PLCA is the CSMA/CD path where a real physical collision on the wire
  causes another node's transmission to arrive during our tx — but MAC's
  code doesn't distinguish; it just responds to `handleCollisionStart`.
  Keeping the states costs nothing and preserves the correct dynamics.
