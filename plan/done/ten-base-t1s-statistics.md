# 10BASE-T1S statistics — instrument for INET cross-comparison

**Status:** implemented (phases 1–8, 10). Phase-9 INET-run step remains
manual, as scoped. `test/t1s/phase{2..8}_stats*.jl` green, ~285 stats
checks, no regressions to the existing suite; `.vec` round-trip through
the writer/reader/comparison harness verified. `notraffic` cycleLength
analytical pin (18.001 µs) enforced. INET-reference comparison scaffold
in place; falls through as "skipped" until reference files land in
`test/t1s/inet-reference/`.
**Scope:** wire `T1sModel` to emit the statistics INET's PLCA / PHY / MAC
emit, using the existing `Recorder` + `VectorFileWriter` infrastructure,
and add a comparison harness that validates the Julia output against
INET reference values. Byte-exact where possible; approximate with
declared tolerance where not.
**Depends on:** `plan/done/ten-base-t1s-plca.md` (T1sModel + FSMs).
**Prior art:** INET emits these signals from `EthernetPlca.cc:24-39`,
`EthernetCsmaPhy.cc` (transmissionStarted/Ended etc.), and
`EthernetCsmaMac.cc` (numFramesSent/Received). See the analysis in
`plan/done/ten-base-t1s-plca.md` §8 for the full list.

---

## 1. The gap this plan closes

The T1S plan committed to "reproduce `notraffic.ini`'s `curID` trace and
per-cycle `cycleLength` exactly" (phase 4) and "reproduce `worstcase.ini`'s
231.6 µs pending delay for node[0]" (phase 7). Both are *pinned in the plan*
as acceptance signals but the implementation currently validates them only
through test-time state inspection — sample `plca.cur_id` at 3/6/9/12/15
µs, sample `plca_data(plca).ds` at 45 µs.

That's not comparable to INET. INET's PLCA module registers 16 signals,
some carrying whole time-series (`curID`, `cycleLength`), some scalar
summaries (`packetPendingDelay`). To cross-check with INET's actual
output — either by loading INET's `.vec` files into a Julia comparison
harness or (extended) by parsing OMNeT++'s `.sca` output — the Julia model
needs to emit the same set of signals through the same recorder API, so
the resulting `.vec` file has the same shape.

**Infrastructure that already exists:**

- `src/result/VectorFileWriter.jl` writes **OMNeT++-compatible `.vec` files**
  (version 3, ETV/TV columns, per-vector attributes, run-level attributes).
  Files it produces are readable by `opp_scavetool`, the OMNeT++ IDE, and
  any parser that follows the format documented in `VectorFileWriter.jl:5-19`.
- `src/result/Recorder.jl` provides `record_scalar!` (writes to the
  `SimulationResult` scalars vector), `record_vector!` (per-name simple
  time-series), and `register_indexed_vector!` / `emit_indexed_vector!`
  (per-node parametric vectors, INET's typical shape).
- `RoutingModel` uses the recorder for per-node `endToEndDelay` — a working
  template we can mirror exactly.

**What's missing:** signal-emit calls at the FSM transition sites, and a
comparison harness that reads reference `.vec` files.

## 2. The signals to emit

Grouped by module, mapping INET's signal name to the Julia call site.

### 2.1 PLCA control FSM (`EthernetPlca.cc:24-39`)

| Signal | Kind | Emit at | Value |
|---|---|---|---|
| `curID` | vector | Every entry to CS_WAIT_TO | `plca.cur_id` |
| `controlStateChanged` | vector | Every state transition | `Int(new_state)` |
| `rxCmd` | vector | Every change of `plca.rx_cmd` | `Int(rx_cmd)` |
| `txCmd` | vector | Every change of `plca.tx_cmd` | `Int(tx_cmd)` |
| `transmitOpportunityUsed` | vector | On CS_YIELD entry (=0) and CS_TRANSMIT entry (=1) | `0` or `1` |
| `toLength` | vector | On CS_NEXT_TX_OPPORTUNITY entry | duration of the just-ended TO |
| `ownToLength` | vector | On CS_NEXT_TX_OPPORTUNITY entry when `cur_id == local_id` | idem |
| `cycleLength` | vector | On CS_SYNCING → CS_WAIT_TO transition (cycle start) | duration of the just-ended cycle |
| `numPacketsPerTo` | vector | On CS_NEXT_TX_OPPORTUNITY entry | packets sent in that TO |
| `numPacketsPerCycle` | vector | On cycle end | packets sent this cycle |
| `numPacketsPerOwnTo` | vector | On own-TO end | packets sent in own TO |

### 2.2 PLCA data FSM

| Signal | Kind | Emit at | Value |
|---|---|---|---|
| `dataStateChanged` | vector | Every DS transition | `Int(new_ds)` |
| `packetPendingDelay` | vector | On DS_TRANSMIT entry when tx follows a recovery cycle | `now - packet_arrival_time` |
| `packetInterval` | vector | On DS_TRANSMIT entry | `now - prev_tx_time` |

Note `packetPendingDelay` requires PLCA to remember when the packet first
arrived from MAC. Add a `packet_arrival_time::SimTime` field to
`PlcaDataFsm` — reset on entering DS_HOLD, read on DS_TRANSMIT.

### 2.3 MAC (`EthernetCsmaMac.cc`)

| Signal | Kind | Emit at | Value |
|---|---|---|---|
| `numFramesSent` | scalar (final) | End of run | `mac.num_frames_sent` |
| `numFramesReceived` | scalar (final) | End of run | `mac.num_frames_received` |
| `carrierSenseChanged` | vector | Every CRS edge | `0` or `1` |
| `collisionChanged` | vector | Every COL edge | `0` or `1` |
| `stateChanged` | vector | Every MAC transition | `Int(new_state)` |

Add `num_frames_sent` / `num_frames_received` counters to `MacState`
(currently only `AppState.packets_received` exists).

### 2.4 PHY (`EthernetCsmaPhy.cc`)

| Signal | Kind | Emit at | Value |
|---|---|---|---|
| `stateChanged` | vector | Every PHY transition | `Int(new_state)` |
| `receivedSignalType` | vector | On RX_END delivery | `Int(sig.kind)` |
| `transmittedSignalType` | vector | On TX_START | `Int(sig.kind)` |
| `receptionStarted` / `Ended` | vector | On RX_START / RX_END | `1` |
| `transmissionStarted` / `Ended` | vector | On TX_START / TX_END | `1` |
| `busUsed` | scalar (final) | End of run | fraction of sim time bus was TX or RX |

### 2.5 What we deliberately skip

- INET's `Chunk`-level statistics (packet-tag emissions, region-tag events).
  Not relevant to bit-level PLCA validation.
- INET's `EthernetInterface`-level Layer-2 statistics (queue length over
  time, drop rate). Not exercised by the three target scenarios.
- PMCD, MII pin-level signals. Dropped in the T1S plan §3.1.

## 3. Emit-site pattern

Following `RoutingModel`'s convention (`RoutingModel.jl:596-605`):

```julia
function _app_receive!(ctx, nodes, node_idx::Int, pk::Packet, recorder)
    node = nodes[node_idx]
    node.packets_received += 1
    ...
    recorder === nothing || emit_indexed_vector!(recorder, node_idx, ctx, e2e_delay)
end
```

For T1S each FSM handler receives `recorder` as an argument. Rather than
thread it through every function signature (many FSM entries), stash it on
`PlcaState` / `MacState` / `PhyState` at build time — same pattern as
`downlink` / `upcalls`. Emit-site becomes:

```julia
function _enter_control_action!(ctx, plca::PlcaState, s::PlcaControlState)
    ...
    elseif s === CS_NEXT_TX_OPPORTUNITY
        # existing logic
        _emit_to_length!(plca, ctx)
        _emit_num_packets_per_to!(plca, ctx)
    ...
end

_emit_to_length!(plca::PlcaState, ctx) = plca.recorder === nothing ? nothing :
    emit_indexed_vector!(plca.recorder, plca.node_idx, ctx, plca.to_length_accumulator)
```

Add a `recorder::Union{Nothing, Recorder}` field to each state struct.
Constructor default is `nothing` — unit tests keep working (all Phase 1-9
tests pass without touching recorder). `T1sModel`'s wiring
(`_build_state!`) sets `recorder` on every FSM state struct when a
recorder is available.

**A per-node index** — INET emits per-module signals, so opp_scavetool
groups by module path. We use `register_indexed_vector!(rec, "Net.node[$i]",
"curID")` at build time, then `emit_indexed_vector!(rec, i, ctx, value)`
at emit sites. This produces one `.vec` per (node, signal) pair, matching
INET's grouping.

## 4. Comparison harness

Two directions of comparison, each with distinct value.

### 4.1 Analytical values (no INET run required)

The plan already predicts specific numbers from spec:
- Cycle length for `notraffic` (N=5): `2µs beacon + 1 ns syncing + 5·3.2 µs TOs = 18.001 µs`.
- `worstcase.ini` pending delay: `231.6 µs = (32b + 3·73B·8 + 3·128b + 20b + 32b + 96b) / 10Mb`.
- `bestcase.ini` cycle length with `max_bc=1`: closed-form arithmetic.

These predictions are worth pinning as tests. The test asserts the emitted
`.vec` file contains samples matching the analytical values. Fast, no
external dependency, catches every timing-model regression.

### 4.2 Byte-exact against INET reference `.vec` files

For a fuller check, load INET's `.vec` output and compare per-sample.

INET's `.vec` files are text with the same version-3 format we produce
(that's why `opp_scavetool` reads ours interchangeably). A Julia
`.vec` reader is ~50 lines:

```julia
struct VecSample; event::Int; time::SimTime; value::Float64; end
struct VecVector
    id::Int
    module_path::String
    name::String
    attributes::Dict{String,String}
    samples::Vector{VecSample}
end
struct VecFile
    version::Int
    run::String
    attributes::Dict{String,String}
    vectors::Vector{VecVector}
end
read_vec_file(path::String)::VecFile = # parse the format
```

Comparison operates on `Dict{Tuple{String,String}, Vector{VecSample}}` (path,
name) → samples. For each (path, name) present in the INET reference,
compare our vector sample-by-sample, allowing:
- **Byte-exact match** for cycle timings and TO durations (deterministic).
- **Sample-count match with ε=1 tolerance** for RNG-driven traffic
  (Poisson intervals in `paper.ini`), since equivalent RNG streams may
  produce off-by-one draws depending on internal event ordering.

Where INET's output includes signals we don't emit (say, `.cc`-internal
diagnostics), the comparison passes over them with a `log(:skipped, name)`.

### 4.3 Where do the INET reference files come from?

INET must be run to produce them. This is the compat-adjacent concern
[[project_omnetpp_cpp_compatibility]] tracks — the user has a local
`jsim`/omnetpp fork in `/home/projectured/workspace/inet/` (see
`inet/examples/ethernet/TenBaseT1S/`). Options:

- **Manual, once**: user runs INET on each of the target scenarios, checks
  the resulting `.vec` / `.sca` files into `test/t1s/inet-reference/`.
  Simple; refresh only when INET version changes.
- **CI-integrated**: a script that runs INET at test time. Requires INET
  build available on the test machine; not viable in a stock omnetpp-julia
  test run.
- **Analytical-only**: skip INET files entirely, pin only the closed-form
  predictions from §4.1. Loses full-run comparison but doesn't gate on
  INET infra.

**Recommendation:** ship both — analytical pins in the standard test run;
INET-reference comparison as a separately-invokable script (`bin/` or
`scripts/`) that runs only when the reference files are present. Same
pattern OMNeT++ examples use for validation runs.

## 5. Where the Julia model is genuinely better

Not translations — outcomes that differ.

1. **Instrumentation is optional and zero-cost when off.** `recorder ===
   nothing` short-circuits every emit call; the hot path is unchanged.
   INET's `emit(signal, value)` always dispatches through the signal
   registry even when nobody's subscribed.
2. **The same file format across implementations.** We already write
   version-3 `.vec` files (`VectorFileWriter.jl`). No conversion layer,
   no format translation — `opp_scavetool` reads Julia output and Julia
   reads INET output.
3. **Analytical validation is first-class.** Because the FSMs' timing is
   spec-derived, we can assert closed-form predictions in the same test
   suite that runs the model. `worstcase.ini`'s 231.6 µs isn't a
   remembered number — it's `(32b + 3·73B·8 + 3·128b + 20b + 32b + 96b) /
   10Mb` in the test source.

## 6. Staged build

### Phase 1 — signal-emit infrastructure
- Add `recorder::Union{Nothing, Recorder}` field to `PlcaState`,
  `MacState`, `PhyState`. Constructor default `nothing`.
- Add `num_frames_sent` / `num_frames_received` counters to `MacState`.
- Add `packet_arrival_time::SimTime` to `PlcaDataFsm`; set on DS_HOLD
  entry, read on DS_TRANSMIT.
- Wire recorder-plumbing through `T1sModel._build_state!` — if the model
  is built with a recorder, propagate to every node's state structs.
- Test: emit_calls compile out (fields default to nothing; existing 130
  tests stay green).

### Phase 2 — the core five signals (analytical acceptance)
Emit and pin:
- `curID` (vector, per node)
- `cycleLength` (vector, per node) — includes closed-form pin for
  notraffic
- `toLength` / `ownToLength` (vector, per node)
- `packetPendingDelay` (vector, per node) — includes closed-form pin for
  worstcase (231.6 µs)

Test: run notraffic; assert `.vec` file contains `curID` sawtooth 0..N-1
and `cycleLength` = 18001 ps for each cycle. Run worstcase (once
implemented in T1sModel with proper offsets); assert `packetPendingDelay`
contains a sample at 231.6 µs.

**This is the acceptance gate.** If phase 2 fails, either the timing is
wrong or the emit site is wrong; either way it's actionable.

### Phase 3 — the FSM-trace signals
Emit `controlStateChanged`, `dataStateChanged`, `rxCmd`, `txCmd` —
per-transition vectors. Useful for post-hoc diagnostics; not required
for acceptance but cheap to add.

### Phase 4 — auxiliary counts
Emit `transmitOpportunityUsed`, `numPacketsPerTo`, `numPacketsPerCycle`,
`numPacketsPerOwnTo`. All are per-cycle / per-TO accumulator counters
maintained across the CS_WAIT_TO ↔ CS_NEXT_TX_OPPORTUNITY loop.

### Phase 5 — MAC statistics
Emit `numFramesSent` / `numFramesReceived` as scalars (final values).
Emit `carrierSenseChanged` / `collisionChanged` / `stateChanged` as
vectors. MAC counters are trivial; MAC-state trace is useful for
post-hoc analysis.

### Phase 6 — PHY statistics
Emit `stateChanged`, `receivedSignalType`, `transmittedSignalType`,
`receptionStarted/Ended`, `transmissionStarted/Ended`. `busUsed` is a
running accumulator: for each TX/RX span, `bus_used += span_duration`;
final scalar is `bus_used / time_limit`.

### Phase 7 — a `.vec` reader in Julia
`src/result/VectorFileReader.jl` — the symmetric counterpart to
`VectorFileWriter`. ~100 lines including grammar; the format is small
and text-based.

Test: write a synthetic `.vec` file via `VectorFileWriter`, read it back
via `VectorFileReader`, assert round-trip equality.

### Phase 8 — comparison harness
`scripts/compare_t1s_vectors.jl` — takes two `.vec` file paths, reports
per-(module, signal) pass/fail with:
- Deterministic vectors (curID, cycleLength, toLength): byte-exact.
- Timing-scalar predictions (packetPendingDelay for worstcase): exact
  match to closed-form.
- RNG-driven vectors (paper.ini Poisson intervals): sample-count match ±1.

Consumes optional `test/t1s/inet-reference/*.vec` files if present. If
absent, prints "no INET reference; skipping" and passes.

### Phase 9 — reference INET runs
Manual step, documented in `documentation/t1s-inet-validation.md`:
1. Build INET locally (user has `/home/projectured/workspace/inet/`).
2. Run each target `.ini` via `opp_run -u Cmdenv -c General
   examples/ethernet/TenBaseT1S/notraffic.ini` (see the ini file's
   `# Run:` comment for the exact invocation).
3. Copy the resulting `results/*.vec` into
   `test/t1s/inet-reference/`.
4. Re-run the comparison harness; commit the reference `.vec` files if
   they diff cleanly.

Not gated as a test — this is a one-shot validation step. Once done,
commit the reference outputs so future runs can compare without
re-invoking INET.

### Phase 10 — docs + close-out
Add a "Statistics and INET validation" section to
`documentation/ten-base-t1s.md`. Update this plan with any design
changes discovered during phases 2-9. Move to `plan/done/`.

## 7. Open questions

1. **Where should `packet_arrival_time` live for `packetPendingDelay`?**
   Currently `PlcaDataFsm` is a side-struct in an `IdDict` — adding a
   field there works but the extra indirection during an emit call is
   awkward. Alternative: move it to `PlcaState` proper. Lean: `PlcaState`,
   at the small cost of a slot that stays 0 for pure-receive nodes.
2. **Scalar-emit granularity.** `record_scalar!` is a `Dict[name] =
   value` (last-write-wins), matching INET's final-scalar convention.
   `numFramesSent` fits naturally. For per-node scalars we'd want
   `record_scalar!(rec, Symbol("node[$i].numFramesSent"), n)` — verify
   this convention against RoutingModel and MM1KModel; RoutingModel uses
   `emit_indexed_vector!` throughout, not scalars. If per-node scalars
   need a new API, expose `register_indexed_scalar!` /
   `emit_indexed_scalar!` symmetric to the vector versions.
3. **Should the comparison harness live in `test/` or `scripts/`?**
   `test/t1s/` implies it runs in every `Pkg.test` — but it needs
   reference files that might not be present. `scripts/` implies
   opt-in — cleaner separation but hides the check from routine
   validation. Lean: skeleton in `test/t1s/` that no-ops if reference
   files are absent (see phase 8); the actual comparison script runs
   only when they are.
4. **INET-side signal names might drift across INET versions.** Pin the
   INET version in `documentation/t1s-inet-validation.md` and note
   which signals were used.
5. **`busUsed` semantics.** INET emits it as a scalar over the whole
   run. In OMNeT++ statistics config it's often computed via
   `statistic["busUsed"](sum(...) / T)`. Our version: accumulate TX/RX
   spans in PHY, divide by `time_limit` on run end. Test the arithmetic
   against a synthetic (single-node, no traffic) case where `busUsed`
   should be `beacon_duration / cycle_length` from PHY's perspective.

## 7.1 Rejected alternatives

- **Emit signals via callbacks instead of direct recorder calls.**
  Tempting because it decouples FSMs from the recorder. Rejected: adds
  a callback dispatch per emit site, which is the hot path (there are
  thousands of emissions per second in a running simulation). The
  `recorder === nothing ? nothing : emit(...)` short-circuit is
  already the same three lines and doesn't add indirection.
- **A signal-registry / listener architecture like OMNeT++'s
  `cSimpleModule::emit`.** Rejected: the whole point of a Julia-native
  design is that we don't need the runtime signal-registration
  ceremony. Direct calls are strictly less code and strictly faster.
- **Compare via a network-hash-style single value** (e.g. hash the
  emitted vectors and pin the hash). Rejected: opaque failures. When
  the hash doesn't match, we learn nothing about *which* signal
  disagreed. Per-signal comparison is expensive only in code, not in
  compute.
- **Roll our own `.vec` file format** with richer typing. Rejected:
  interoperability with `opp_scavetool` and every existing OMNeT++
  analysis notebook is worth more than any format improvement.
