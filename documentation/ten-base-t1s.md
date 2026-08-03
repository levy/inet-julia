# 10BASE-T1S with PLCA — Julia-native replication

Julia-native implementation of INET's 10BASE-T1S multidrop model with
PLCA arbitration. Design rationale, decisions and requirements:
`plan/done/ten-base-t1s-plca.md`. Analysis source: INET at
`src/inet/{linklayer,physicallayer}/ethernet/`.

## Where it lives

- **`src/t1s/`** — the FSM/wire building blocks (`T1sModule`).
- **`src/model/T1sModel.jl`** — the `AbstractModel` wrapper that plugs
  `T1sModule` into the simulator lifecycle.

## Four FSMs, faithful to INET

Same layered structure as `EthernetPlcaInterface.ned`:

    app → MAC → PLCA → PHY → wire

Each layer is a struct with its own FSM state. Method calls between layers
are direct Julia function calls; no cModule/cMessage/cGate ceremony.

- **MAC** (`src/t1s/Mac.jl`) — 6 states (`IDLE`, `WAIT_IFG`, `TRANSMITTING`,
  `JAMMING`, `BACKOFF`, `RECEIVING`). Full CSMA/CD backoff kept faithfully;
  JAMMING/BACKOFF fire whenever PLCA's DS_COLLIDE raises SIGNAL_ERROR
  (bestcase never triggers this; worstcase does).
- **PLCA control FSM** (`src/t1s/PlcaControl.jl`) — 14 states (`CS_DISABLE`,
  `CS_RESYNC`, …, `CS_NEXT_TX_OPPORTUNITY`). The coordinator emits BEACON,
  cycles `curID` 0..N-1, restarts. Followers detect BEACON, mirror the
  cycle, wait for their own TO to transmit.
- **PLCA data FSM** (`src/t1s/PlcaData.jl`) — 9 states (`DS_IDLE`,
  `DS_WAIT_IDLE`, `DS_RECEIVE`, `DS_HOLD`, `DS_COLLIDE`,
  `DS_DELAY_PENDING`, `DS_PENDING`, `DS_WAIT_MAC`, `DS_TRANSMIT`). Holds a
  packet in `DS_HOLD` until CS_COMMIT fires COMMIT_TO; recovers via
  DELAY_PENDING → PENDING → WAIT_MAC when the packet misses its TO.
- **PHY** (`src/t1s/Phy.jl`) — 5 states (`IDLE`, `TRANSMITTING`,
  `RECEIVING`, `COLLISION`, `CRS_ON`). Tracks multiple rx signals
  defensively (mixed-config validation), delivers CRS/COL/RX events upward.

Plus **`WireJunction`** (`src/t1s/Junction.jl`) — first-class multidrop
T-junction, one module_id per junction. Multidrop is a *chain* of segments
joined by junctions (matching `MultidropNetwork.ned:44-49`), so chain
propagation delays are per-junction rather than fanned out at the sender.

## Timers (all bits ÷ bitrate)

| Timer | Value @ 10 Mb | Where |
|---|---|---|
| BEACON on wire | 20 b = 2.0 µs | `beacon_timer_length` |
| Empty TO | 32 b = 3.2 µs | `to_timer_length` |
| Beacon-detection | 22 b = 2.2 µs | `beacon_det_timer_length` |
| Burst-mode wait | 128 b = 12.8 µs | `burst_timer_length` |
| Pending recovery | 512 b = 51.2 µs | `pending_timer_length` |
| WAIT_MAC fallback | 288 b = 28.8 µs | `commit_timer_length` |
| Syncing gap | 1 ns (hard) | `syncing_timer_hardcoded_ps` |
| MAC IFG | 96 b = 9.6 µs | `INTERFRAME_GAP_BITS` |
| MAC JAM | 32 b = 3.2 µs | `JAM_SIGNAL_BYTES * 8` |
| PHY hdr | 64 b (8 B) | `ETHERNET_PHY_HEADER_LEN_BYTES` |
| PHY ESD | 8 b (1 B) | `ETHERNET_PHY_ESD_LEN_BYTES` |

Notraffic cycle time (N=5): 2µs BEACON + 1 ns syncing + 5·3.2 µs TOs
= 18.001 µs. Empirically the model produces 305 events over 100 µs.

## Building a T1S model

```julia
using Omnetpp, Inet          # lifecycle from the kernel, the model from here
t = SimulationType(T1sModel)
a = ParameterAssignment(Dict{Symbol,Any}(
    :n_nodes    => 5,
    :time_limit => 100e-6,       # seconds
    :scenario   => :notraffic))   # :notraffic | :bestcase | :worstcase
run = expand_simulation(configure_simulation(t, a))[1]
inst = prepare_simulation_execution(run; engine = SequentialEngineSpec())
run_simulation!(inst)
res = finish_simulation!(inst)

@show res.network_hash             # 0x429fe1b7ab8d705cbaaa4926d57e103b
```

## Non-obvious design decisions

- **`chunk_length` vs `Base.length`.** From `PacketModule` — see
  `documentation/packet.md`.
- **`TimerHandle` for cancellation.** The `Omnetpp` scheduler has no
  first-class event cancellation, so each timer owns a mutable handle
  with a generation counter. Scheduling bumps the counter; the scheduled
  closure checks its captured generation before firing. Cancel/reschedule
  = bump. Simple and race-free.
- **Re-entrancy guard on PLCA's FSM.** PHY's `carrier_sense_start`
  callback fires synchronously from PLCA's own `SEND_BEACON` Enter
  (via `downlink.start_signal_tx` → phy_start → upcalls.carrier_sense_start
  → `plca_on_carrier_sense_start!` → `handle_with_control_fsm!`). Without
  a guard the nested FSM invocation would take further transitions before
  the outer Enter's side effects (like scheduling `syncing_timer`) are
  in place. `PlcaState.in_fsm` is set for the duration of
  `handle_with_control_fsm!`; nested calls return immediately, and the
  outer loop re-evaluates on unwind. Same shape as INET's
  `fsm.insertDelayedAction`.
- **`cur_id` reset at first-TO-start**, not at CS_RESYNC. During BEACON
  emission `cur_id` transiently equals `plca_node_count` (the reset
  happens at SYNCING → WAIT_TO). This matches INET
  (`EthernetPlca.cc:399-400`).
- **The `do`-block trap.** `schedule!` / `schedule_root!` /
  `schedule_timer!` all take `action::Function` LAST; Julia's `do`-block
  sugar puts the closure FIRST, so `f(args...) do x ... end` breaks
  dispatch. Explicit lambdas throughout.
- **Consolidated module_ids.** Each node has ONE module_id (Q5 answered:
  four state structs per node but one dispatch key), while each
  `WireJunction` has its own. Fewer scheduler entries per node without
  losing the per-junction event trace.
- **MAC's `intuniform` BACKOFF uses the per-node RNG** seeded from the
  node address (same pattern as `RoutingModel`). Deterministic and
  golden-hash-preserving.

## Statistics and INET validation

The T1S model emits ~22 named signals matching INET's PLCA / PHY / MAC
signal names, wired through the existing `Recorder` + `VectorFileWriter`
infrastructure. The output `.vec` files are OMNeT++ version 3 —
readable by `opp_scavetool`, the IDE, and any other analysis tool.

**PLCA signals** (per node, path `Net.node[i].plca`):
`curID`, `cycleLength`, `toLength`, `ownToLength`, `packetPendingDelay`,
`packetInterval`, `transmitOpportunityUsed`, `numPacketsPerTo`,
`numPacketsPerOwnTo`, `numPacketsPerCycle`, `controlStateChanged`,
`dataStateChanged`, `rxCmd`, `txCmd`.

**MAC signals** (per node, path `Net.node[i].mac`):
`carrierSenseChanged`, `collisionChanged`, `stateChanged`,
`numFramesSent`, `numFramesReceived`.

**PHY signals** (per node, path `Net.node[i].phy`):
`stateChanged`, `receivedSignalType`, `transmittedSignalType`,
`receptionStarted`, `receptionEnded`, `transmissionStarted`,
`transmissionEnded`. Plus a `bus_used_ns` accumulator on `PhyState`
(final `busUsed = bus_used_ns / time_limit`).

### Enabling statistics

Statistics recording is opt-in via the `:vec_path` parameter — empty
default (in-memory `Recorder` only, populates `SimulationResult.vectors`;
useful for tests). Set it to write a `.vec` file:

```julia
a = ParameterAssignment(Dict{Symbol,Any}(
    :n_nodes    => 5,
    :time_limit => 100e-6,
    :scenario   => :notraffic,
    :vec_path   => "results/notraffic.vec"))
```

The recorder wires to every node's PHY/PLCA/MAC via
`T1sModel.make_recorder` and `_wire_recorder!`, called from
`schedule_initial_events!`. When `:vec_path` is empty, per-node
`stat_handles` are still populated but no file is written; results are
readable at test time from `SimulationResult.vectors`.

Recording is **determinism-neutral**: the pinned `notraffic` network
hash (`0x429fe1b7ab8d705cbaaa4926d57e103b`) is unchanged whether
statistics are on or off.

### Cross-comparison against INET

Two directions of comparison ship in the stats work
(plan `plan/done/ten-base-t1s-statistics.md`):

1. **Analytical pins** — closed-form predictions from spec, right in
   the test suite. `notraffic`'s 18.001 µs cycle length is pinned;
   every emitted `cycleLength` sample must equal `2e-6 + 1e-9 +
   5·3.2e-6`. `worstcase`'s 231.6 µs pending delay will pin once
   `worstcase.ini`'s specific per-node offsets are implemented (that's
   the follow-up in "what's not shipped yet"). No INET dependency.
2. **Byte-exact against INET reference `.vec` files** via
   `src/result/VectorFileReader.jl` (round-trippable parser for the
   same format we write) and `src/result/VecCompare.jl` (per-signal
   tolerance rules: `:exact`, `:approx(rtol)`, `:count_within(n)`).
   The `scripts/compare_t1s_vectors.jl` CLI is the entry point.

To validate against INET, run each scenario in your local INET build,
drop the resulting `.vec` files into `test/t1s/inet-reference/`, and
re-run the test suite — the phase-8 test set detects the reference
files and switches from "skip" to "compare".

## What's not shipped yet

- **Bestcase / worstcase per-node timing offsets** for INET-exact
  reproduction. Placeholder fixed 10 µs cadence configured; real
  `worstcase.ini`'s 231.6 µs pending-delay measurement is a follow-up.
- **INET reference `.vec` files.** Comparison harness is in place; the
  actual INET-run step (documented in the stats plan §9) is manual.
- **`busUsed` scalar-emit.** The accumulator (`PhyState.bus_used_ns`)
  is populated; scalar emission at end-of-run needs a `Recorder` scalar
  channel (currently `record_scalar!` writes to
  `SimulationResult.scalars`, not to `.vec`).
- **Burst mode `max_bc > 1`.** CS_BURST + repeat DS_TRANSMIT loop present
  in the FSM but only exercised by `max_bc = 0` in the target scenarios.
- **Poisson / uniform inter-arrival** for smoke / paper / throughput
  scenarios. IntervalKind supports IA_UNIFORM / IA_POISSON but only
  IA_FIXED is used by the currently-configured scenarios.
- **Mixed CSMA/CD-vs-PLCA validation config.** The MAC is already
  faithful, so the CSMA/CD side is present; needs a mode-select to
  disable PLCA on some nodes.
- **`SerializedFields{H}` byte-round-trip cache** — inherited from
  `PacketModule` (see `documentation/packet.md`).
- **Full `E2EDelay` tag** for e2e-delay measurement at the app layer.
