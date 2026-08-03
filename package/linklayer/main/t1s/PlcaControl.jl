# ============================================================================
# PLCA control FSM — 14 states, faithful to EthernetPlca.cc:344-586.
#
# States (`EthernetPlca.h:48-63`):
#   CS_DISABLE   CS_RESYNC   CS_RECOVER   CS_SEND_BEACON   CS_SYNCING
#   CS_WAIT_TO   CS_EARLY_RECEIVE  CS_COMMIT  CS_YIELD  CS_RECEIVE
#   CS_TRANSMIT  CS_BURST     CS_ABORT     CS_NEXT_TX_OPPORTUNITY
#
# Role split:
#   coordinator (local_nodeID == 0) — emits BEACON, cycles curID 0..N-1
#   follower    (local_nodeID != 0) — waits for BEACON, participates in cycle
#
# Two FSMs run in parallel per node: control (this file) and data (Phase 5).
# They interact via shared variables: packetPending, TX_EN, CARRIER_STATUS,
# SIGNAL_STATUS. This file exposes those as fields on PlcaState so Phase 5
# can plug in without touching the control transitions.
#
# For Phase 4 we exercise ONLY the control FSM. `packetPending` and `TX_EN`
# are always false, so CS_COMMIT / CS_TRANSMIT / CS_BURST / CS_ABORT
# branches never fire. The coordinator cycles beacon → curID rotation →
# beacon indefinitely; a follower detects the beacon and mirrors the cycle.
# ============================================================================

# ---------- state enum ------------------------------------------------------

@enum PlcaControlState::UInt8 begin
    CS_DISABLE               = 0
    CS_RESYNC                = 1
    CS_RECOVER               = 2
    CS_SEND_BEACON           = 3
    CS_SYNCING               = 4
    CS_WAIT_TO               = 5
    CS_EARLY_RECEIVE         = 6
    CS_COMMIT                = 7
    CS_YIELD                 = 8
    CS_RECEIVE               = 9
    CS_TRANSMIT              = 10
    CS_BURST                 = 11
    CS_ABORT                 = 12
    CS_NEXT_TX_OPPORTUNITY   = 13
end

# The tx_cmd / rx_cmd MII field values (matching INET's rx_cmd/tx_cmd).
@enum PlcaCmd::UInt8 begin
    CMD_NONE   = 0
    CMD_BEACON = 1
    CMD_COMMIT = 2
end

# ---------- PLCA state -------------------------------------------------------

# Callback interface upward — the layer above PLCA. In this Phase, layer
# "above" is nothing (we drive PLCA from tests); Phase 5 fills these with
# the data FSM hooks; Phase 6 adds MAC.
struct PlcaControlUpcalls
    # Called when the control FSM enters CS_COMMIT — fires COMMIT_TO into
    # the data FSM (Phase 5).
    commit_to     :: Function       # (ctx, plca) -> ()
    # Called on transitions that need MAC-visible CRS/COL edges (via edge
    # detection at end of handler); Phase 6 wires these to MAC.
    on_carrier_sense_change  :: Function   # (ctx, plca) -> ()
    on_signal_error_change   :: Function   # (ctx, plca) -> ()
end

_plca_no_upcall(_...) = nothing
const NO_PLCA_UPCALLS = PlcaControlUpcalls(_plca_no_upcall,
                                            _plca_no_upcall, _plca_no_upcall)

# Callback interface downward — the PHY.
struct PlcaDownlink
    start_signal_tx :: Function     # (ctx, kind::EthernetSignalKind)
    end_signal_tx   :: Function     # (ctx)
    # Data-frame tx path (Phase 5 uses these):
    start_frame_tx  :: Function     # (ctx, packet, esd)
    end_frame_tx    :: Function     # (ctx)
end

_plca_no_downlink(_...) = nothing
const NO_PLCA_DOWNLINK = PlcaDownlink(_plca_no_downlink, _plca_no_downlink,
                                       _plca_no_downlink, _plca_no_downlink)

# PLCA timing configuration — NED-equivalent parameters, in BITS
# (converted to SimTime via `/bitrate`). Defaults from EthernetPlca.ned.
mutable struct PlcaConfig
    plca_node_count::Int
    local_node_id::Int
    max_bc::Int                 # burst count max; 0 = no burst
    delay_line_length::Int      # nibbles in the DLL; drives hold_timer

    beacon_timer_length_bits::Int         # 20
    beacon_det_timer_length_bits::Int     # 22
    to_timer_length_bits::Int             # 32
    burst_timer_length_bits::Int          # 128
    pending_timer_length_bits::Int        # 512
    commit_timer_length_bits::Int         # 288
    syncing_timer_hardcoded_ps::Int       # 1 ns = 1000 ps
end

function PlcaConfig(; plca_node_count::Int, local_node_id::Int,
                     max_bc::Int = 0, delay_line_length::Int = 100)
    PlcaConfig(plca_node_count, local_node_id, max_bc, delay_line_length,
               20, 22, 32, 128, 512, 288, 1000)
end

# The state struct — everything PLCA needs to run.
mutable struct PlcaState
    module_id::Int
    config::PlcaConfig
    bitrate::Float64

    # Control FSM
    cs::PlcaControlState

    # Shared with the data FSM (Phase 5)
    ds::UInt8                        # PlcaDataState placeholder; filled in Ph.5
    packet_pending::Bool
    tx_en::Bool
    carrier_status::Bool             # CARRIER_STATUS: ON=true, OFF=false
    signal_status::Bool              # SIGNAL_STATUS: SIGNAL_ERROR=true

    # From PHY / observed on the wire
    crs::Bool                        # carrier sense (PHY CRS)
    col::Bool                        # collision (PHY COL)
    receiving::Bool                  # RX_DV || rx_cmd == CMD_COMMIT
    rx_cmd::PlcaCmd                  # current received cmd (BEACON / COMMIT / NONE)

    # PLCA's own transmitted cmd
    tx_cmd::PlcaCmd

    # Round-robin position
    cur_id::Int                      # current TO ID (coordinator advances)
    bc::Int                          # current burst count
    committed::Bool                  # true from CS_COMMIT until end of own TO

    # Edge-detection cache — only CHANGES propagate up
    prev_carrier_sense::Bool
    prev_signal_error::Bool

    # Re-entrancy guard: PHY callbacks (carrier_sense_start etc.) fire
    # synchronously during PLCA's own Enter actions (start_signal_tx path).
    # Without a guard, the FSM would take further transitions BEFORE the
    # current Enter has finished its side effects. Mirrors INET's
    # `fsm.insertDelayedAction` — pending PHY-state updates are captured
    # while `in_fsm` is true, then re-evaluated after the outer loop unwinds.
    in_fsm::Bool

    # Timers (control FSM)
    beacon_timer::TimerHandle
    beacon_det_timer::TimerHandle
    to_timer::TimerHandle
    syncing_timer::TimerHandle
    burst_timer::TimerHandle
    # Timers (data FSM) — Phase 5 populates these
    hold_timer::TimerHandle
    pending_timer::TimerHandle
    commit_timer::TimerHandle
    tx_timer::TimerHandle

    upcalls::PlcaControlUpcalls
    downlink::PlcaDownlink

    # ---- statistics recording (plan/pending/ten-base-t1s-statistics.md) ----
    # Recorder is set by T1sModel.make_recorder at build time. When nothing,
    # every _emit_stat! short-circuits and the hot path stays untouched.
    recorder::Any                       # Union{Nothing,Recorder}, but Recorder
                                        # lives in the OmnetppSimulator toplevel so Any
                                        # here avoids the type-order pain.
    node_idx::Int                       # 1-based node index; 0 = no recorder
    # Map from signal name → indexed_vector handle. Populated by make_recorder.
    stat_handles::Dict{Symbol,Int}
    # Accumulators for per-cycle / per-TO statistics.
    cycle_start_time::SimTime           # start of current cycle (for cycleLength)
    to_start_time::SimTime              # start of current TO   (for toLength)
    packets_in_to::Int
    packets_in_cycle::Int
    packets_in_own_to::Int
end

function PlcaState(module_id::Int, config::PlcaConfig; bitrate::Float64 = 10.0e6,
                   upcalls::PlcaControlUpcalls = NO_PLCA_UPCALLS,
                   downlink::PlcaDownlink = NO_PLCA_DOWNLINK)
    PlcaState(module_id, config, bitrate,
              CS_DISABLE,          # cs
              0x00,                # ds (Phase 5)
              false,               # packet_pending
              false,               # tx_en
              false,               # carrier_status
              false,               # signal_status
              false,               # crs
              false,               # col
              false,               # receiving
              CMD_NONE,            # rx_cmd
              CMD_NONE,            # tx_cmd
              0,                   # cur_id
              0,                   # bc
              false,               # committed
              false, false,        # edge caches
              false,               # in_fsm re-entrancy guard
              TimerHandle(), TimerHandle(), TimerHandle(),
              TimerHandle(), TimerHandle(),
              TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(),
              upcalls, downlink,
              nothing, 0, Dict{Symbol,Int}(),        # recorder/node_idx/handles
              SimTime(0), SimTime(0), 0, 0, 0)       # accumulators
end

# ---------- helpers ---------------------------------------------------------

_is_coord(plca::PlcaState) = plca.config.local_node_id == 0
_bits_to_time(plca::PlcaState, bits::Int) = to_simtime(bits / plca.bitrate)

# ---------- statistics-emit helpers ----------------------------------------
# All emit sites short-circuit when `plca.recorder === nothing`, so unit
# tests that don't attach a recorder pay zero cost.
#
# Two flavours because `SimTime === Int64`:
#   _emit_time!  — dispatches through the SimTime overload of
#                  emit_indexed_vector!, which divides by TIME_UNIT so the
#                  emitted value is in SECONDS (INET convention).
#   _emit_count! — dispatches through the Real overload, storing raw Float64.
#                  For counts / enum-values / booleans (curID, state kinds).

"Emit a duration sample (SimTime, will be reported in seconds)."
function _emit_time!(plca::PlcaState, ctx, name::Symbol, value::SimTime)
    plca.recorder === nothing && return
    idx = get(plca.stat_handles, name, 0)
    idx > 0 || return
    emit_indexed_vector!(plca.recorder, idx, ctx, value)
end

"Emit a count / enum sample (Real, stored as Float64)."
function _emit_count!(plca::PlcaState, ctx, name::Symbol, value::Real)
    plca.recorder === nothing && return
    idx = get(plca.stat_handles, name, 0)
    idx > 0 || return
    emit_indexed_vector!(plca.recorder, idx, ctx, Float64(value))
end

"Set `plca.tx_cmd` and emit txCmd if it changed."
function _set_tx_cmd!(plca::PlcaState, ctx, new::PlcaCmd)
    plca.tx_cmd == new && return
    plca.tx_cmd = new
    _emit_count!(plca, ctx, :txCmd, UInt8(new))
end

"Set `plca.cur_id` and emit curID if it changed (matches INET's
`emit(curIdSignal, curID)` on every value change)."
function _set_cur_id!(plca::PlcaState, ctx, new::Int)
    plca.cur_id == new && return
    plca.cur_id = new
    _emit_count!(plca, ctx, :curID, new)
end

function _update_receiving!(plca::PlcaState)
    # Analog of the RX_DV/rx_cmd expression at EthernetPlca.cc:277 etc.
    plca.receiving = plca.rx_cmd === CMD_COMMIT
    # RX_DV would additionally set this for DATA — but Phase 4 has no DATA.
end

# ---------- start ----------------------------------------------------------

"Kick the FSM off — call once from schedule_initial_events!.
Per analysis (`EthernetPlca.cc:176`), INET initializes to CS_RESYNC (not
CS_DISABLE — that state is only reached via explicit disable), with
curID pre-set to `plca_node_count`. INET's initialize() also calls
emit() for every signal at t=0 with its current value, so byte-exact
cross-comparison against INET's .vec files requires the same at-time-0
sample for each signal we emit."
function plca_start!(ctx, plca::PlcaState)
    plca.cs = CS_RESYNC
    plca.cur_id = plca.config.plca_node_count
    # curID is the ONE signal INET actually init-emits (the initial value
    # `plca_node_count` is set in the setter INET traces). Others follow
    # emit-on-change during the FSM run — matching INET's default emit()
    # semantics. dataState is emitted here too as it stays in DS_IDLE
    # under notraffic and INET emits its initial value.
    _emit_count!(plca, ctx, :curID, plca.cur_id)
    # dataState initial = DS_IDLE = 1 (INET enum order — see PlcaData.jl).
    _emit_count!(plca, ctx, :dataState, UInt8(DS_IDLE))
    _emit_count!(plca, ctx, :controlState, UInt8(CS_RESYNC))
    _emit_count!(plca, ctx, :carrierSense, 0)   # crs starts false
    _emit_count!(plca, ctx, :collision, 0)      # col starts false
    handle_with_control_fsm!(ctx, plca)
end

# ---------- PHY-side event hooks --------------------------------------------
#
# These are the callbacks PLCA gives to PHY (via PhyUpcalls). They mutate
# PLCA's CRS/rx_cmd/receiving state, then run the control FSM.

"PHY tells us carrier came on. INET's `handleCarrierSenseStart`."
function plca_on_carrier_sense_start!(ctx, plca::PlcaState)
    plca.crs = true
    _emit_count!(plca, ctx, :carrierSense, 1)
    handle_with_control_fsm!(ctx, plca)
end

"PHY tells us carrier dropped."
function plca_on_carrier_sense_end!(ctx, plca::PlcaState)
    plca.crs = false
    _emit_count!(plca, ctx, :carrierSense, 0)
    prev = plca.rx_cmd
    plca.rx_cmd = CMD_NONE          # `EthernetPlca.cc:275` clears on CRS end
    prev == plca.rx_cmd || _emit_count!(plca, ctx, :rxCmd, UInt8(plca.rx_cmd))
    _update_receiving!(plca)
    handle_with_control_fsm!(ctx, plca)
end

"PHY tells us a signal reception started. Sets rx_cmd based on kind."
function plca_on_reception_start!(ctx, plca::PlcaState, sig::WireEvent)
    prev = plca.rx_cmd
    if sig.kind === SIG_BEACON
        plca.rx_cmd = CMD_BEACON
    elseif sig.kind === SIG_COMMIT
        plca.rx_cmd = CMD_COMMIT
    else
        plca.rx_cmd = CMD_NONE      # DATA sets RX_DV (Phase 5)
    end
    prev == plca.rx_cmd || _emit_count!(plca, ctx, :rxCmd, UInt8(plca.rx_cmd))
    _update_receiving!(plca)
    handle_with_control_fsm!(ctx, plca)
end

function plca_on_reception_end!(ctx, plca::PlcaState, sig::WireEvent)
    # rx_cmd stays until carrier drops; INET clears in handleCarrierSenseEnd.
    handle_with_control_fsm!(ctx, plca)
end

# Collision hooks are dummies in Phase 4 (COLLISION path isn't exercised).
plca_on_collision_start!(ctx, plca::PlcaState) = handle_with_control_fsm!(ctx, plca)
plca_on_collision_end!(ctx, plca::PlcaState)   = handle_with_control_fsm!(ctx, plca)

# ---------- the FSM: handle_with_control_fsm! -------------------------------
#
# Runs the control FSM to fixed point: while a transition is possible, take
# it. Every state's Enter action bumps a "keep going" flag by transitioning
# to the new state and setting `cs`, then the loop re-evaluates. Same shape
# as INET's `EthernetPlca::handleWithControlFSM`.
#
# At the bottom, edge-detect on carrier_status / signal_status and fire the
# `on_*_change` upcalls if changed — this is how PLCA drives MAC's synthetic
# CRS/COL edges (Phase 6).

function handle_with_control_fsm!(ctx, plca::PlcaState)
    # Re-entrancy guard: if a PHY callback fires while we're inside the FSM
    # (which happens for start_signal_tx → carrier_sense_start), just return.
    # The outer loop will re-evaluate transitions on the updated state.
    plca.in_fsm && return nothing
    plca.in_fsm = true
    try
        # Loop until no more transitions.
        changed = true
        while changed
            changed = _step_control_fsm!(ctx, plca)
        end
        # Edge detection — only fire upcalls when values CHANGE.
        if plca.carrier_status != plca.prev_carrier_sense
            plca.prev_carrier_sense = plca.carrier_status
            plca.upcalls.on_carrier_sense_change(ctx, plca)
        end
        if plca.signal_status != plca.prev_signal_error
            plca.prev_signal_error = plca.signal_status
            plca.upcalls.on_signal_error_change(ctx, plca)
        end
    finally
        plca.in_fsm = false
    end
    return nothing
end

# One step of the FSM — take at most one transition. Returns true if state
# changed (so the caller loops). Each `case` block corresponds to one of the
# 14 states.
function _step_control_fsm!(ctx, plca::PlcaState)::Bool
    cs = plca.cs

    if cs === CS_DISABLE
        # T1: !coord → CS_RESYNC; T2: coord → CS_RECOVER
        return _enter_control!(ctx, plca,
            _is_coord(plca) ? CS_RECOVER : CS_RESYNC)

    elseif cs === CS_RESYNC
        # T1: !coord && CRS → CS_EARLY_RECEIVE
        # T2: !CRS && coord → CS_SEND_BEACON
        if !_is_coord(plca) && plca.crs
            return _enter_control!(ctx, plca, CS_EARLY_RECEIVE)
        elseif !plca.crs && _is_coord(plca)
            return _enter_control!(ctx, plca, CS_SEND_BEACON)
        end

    elseif cs === CS_RECOVER
        return _enter_control!(ctx, plca, CS_WAIT_TO)

    elseif cs === CS_SEND_BEACON
        # T1: beacon_timer not scheduled → CS_SYNCING
        if !is_scheduled(plca.beacon_timer)
            return _enter_control!(ctx, plca, CS_SYNCING)
        end

    elseif cs === CS_SYNCING
        # Followers: CRS drops → WAIT_TO. Coordinator: syncing_timer fires → WAIT_TO.
        # First-TO-start rule: reset cur_id = 0 as we cross into WAIT_TO.
        if !plca.crs && !is_scheduled(plca.syncing_timer)
            # Emit cycleLength for the cycle we just finished (skip the very
            # first cycle where cycle_start_time is still 0).
            if plca.cycle_start_time > zero(plca.cycle_start_time)
                _emit_time!(plca, ctx, :cycleLength,
                            SimTime(ctx.timestamp - plca.cycle_start_time))
                _emit_count!(plca, ctx, :numPacketsPerCycle, plca.packets_in_cycle)
            end
            plca.cycle_start_time = ctx.timestamp
            plca.packets_in_cycle = 0
            _set_cur_id!(plca, ctx, 0)
            return _enter_control!(ctx, plca, CS_WAIT_TO)
        end

    elseif cs === CS_WAIT_TO
        # T1: CRS
        if plca.crs
            return _enter_control!(ctx, plca, CS_EARLY_RECEIVE)
        end
        # T2: my TO && packet pending
        if plca.cur_id == plca.config.local_node_id && plca.packet_pending && !plca.crs
            return _enter_control!(ctx, plca, CS_COMMIT)
        end
        # T3: to_timer expired && not my TO
        if !is_scheduled(plca.to_timer) &&
           plca.cur_id != plca.config.local_node_id && !plca.crs
            return _enter_control!(ctx, plca, CS_NEXT_TX_OPPORTUNITY)
        end
        # T4: my TO && no packet
        if plca.cur_id == plca.config.local_node_id && !plca.packet_pending && !plca.crs
            return _enter_control!(ctx, plca, CS_YIELD)
        end

    elseif cs === CS_EARLY_RECEIVE
        # T3: !CRS && coord → CS_RECOVER
        if !plca.crs && _is_coord(plca)
            return _enter_control!(ctx, plca, CS_RECOVER)
        end
        # T4: receiving && CRS → CS_RECEIVE
        if plca.receiving && plca.crs
            return _enter_control!(ctx, plca, CS_RECEIVE)
        end
        # T1: !coord && !receiving && (rx==BEACON || (!CRS && bdt scheduled)) → SYNCING
        if !_is_coord(plca) && !plca.receiving &&
           (plca.rx_cmd === CMD_BEACON ||
            (!plca.crs && is_scheduled(plca.beacon_det_timer)))
            return _enter_control!(ctx, plca, CS_SYNCING)
        end
        # T2: !coord && !CRS && rx!=BEACON && !bdt → RESYNC
        if !_is_coord(plca) && !plca.crs &&
           plca.rx_cmd !== CMD_BEACON && !is_scheduled(plca.beacon_det_timer)
            return _enter_control!(ctx, plca, CS_RESYNC)
        end

    elseif cs === CS_YIELD
        # T1: CRS && to_timer still scheduled → CS_EARLY_RECEIVE
        if plca.crs && is_scheduled(plca.to_timer)
            return _enter_control!(ctx, plca, CS_EARLY_RECEIVE)
        end
        # T2: !to_timer → CS_NEXT_TX_OPPORTUNITY
        if !is_scheduled(plca.to_timer)
            return _enter_control!(ctx, plca, CS_NEXT_TX_OPPORTUNITY)
        end

    elseif cs === CS_RECEIVE
        # T1: !CRS → CS_NEXT_TX_OPPORTUNITY
        if !plca.crs
            return _enter_control!(ctx, plca, CS_NEXT_TX_OPPORTUNITY)
        end

    elseif cs === CS_COMMIT
        # T1: TX_EN → CS_TRANSMIT
        if plca.tx_en
            return _enter_control!(ctx, plca, CS_TRANSMIT)
        end
        # T2: !TX_EN && !packet_pending → CS_ABORT
        if !plca.tx_en && !plca.packet_pending
            return _enter_control!(ctx, plca, CS_ABORT)
        end

    elseif cs === CS_TRANSMIT
        # T1: !TX_EN && !CRS && bc>=max_bc → CS_NEXT_TX_OPPORTUNITY
        if !plca.tx_en && !plca.crs && plca.bc >= plca.config.max_bc
            return _enter_control!(ctx, plca, CS_NEXT_TX_OPPORTUNITY)
        end
        # T2: !TX_EN && bc<max_bc → CS_BURST
        if !plca.tx_en && plca.bc < plca.config.max_bc
            return _enter_control!(ctx, plca, CS_BURST)
        end

    elseif cs === CS_BURST
        # T1: TX_EN → CS_TRANSMIT
        if plca.tx_en
            cancel!(plca.burst_timer)
            return _enter_control!(ctx, plca, CS_TRANSMIT)
        end
        # T2: !TX_EN && burst_timer expired → CS_ABORT
        if !plca.tx_en && !is_scheduled(plca.burst_timer)
            return _enter_control!(ctx, plca, CS_ABORT)
        end

    elseif cs === CS_ABORT
        # T1: !CRS → CS_NEXT_TX_OPPORTUNITY
        if !plca.crs
            return _enter_control!(ctx, plca, CS_NEXT_TX_OPPORTUNITY)
        end

    elseif cs === CS_NEXT_TX_OPPORTUNITY
        # T1 coord && curID>=N → CS_RESYNC; T2 → CS_WAIT_TO
        if _is_coord(plca) && plca.cur_id >= plca.config.plca_node_count
            return _enter_control!(ctx, plca, CS_RESYNC)
        end
        return _enter_control!(ctx, plca, CS_WAIT_TO)
    end

    return false
end

# Transition into a new state — run the Enter action, then return true so
# the caller re-evaluates.
function _enter_control!(ctx, plca::PlcaState, new_state::PlcaControlState)::Bool
    plca.cs = new_state
    _emit_count!(plca, ctx, :controlState, UInt8(new_state))
    _enter_control_action!(ctx, plca, new_state)
    return true
end

function _enter_control_action!(ctx, plca::PlcaState, s::PlcaControlState)
    if s === CS_DISABLE
        _set_tx_cmd!(plca, ctx, CMD_NONE)
        plca.committed = false
        _set_cur_id!(plca, ctx, 0)

    elseif s === CS_SEND_BEACON
        _set_tx_cmd!(plca, ctx, CMD_BEACON)
        # Schedule beacon_timer for beacon duration.
        schedule_timer!(ctx, _bits_to_time(plca, plca.config.beacon_timer_length_bits),
            plca.module_id, plca.beacon_timer,
            function (ctx2) handle_with_control_fsm!(ctx2, plca) end)
        # Fire off the BEACON signal on the wire.
        plca.downlink.start_signal_tx(ctx, SIG_BEACON)

    elseif s === CS_SYNCING
        # End the BEACON tx_cmd (only coord had it).
        if plca.tx_cmd === CMD_BEACON
            _set_tx_cmd!(plca, ctx, CMD_NONE)
            plca.downlink.end_signal_tx(ctx)
        end
        # Coordinator only: schedule syncing_timer for 1ns to create a CRS
        # OFF/ON edge (§3.2). Follower goes to WAIT_TO on natural !CRS.
        if _is_coord(plca)
            schedule_timer!(ctx, SimTime(plca.config.syncing_timer_hardcoded_ps),
                plca.module_id, plca.syncing_timer,
                function (ctx2) handle_with_control_fsm!(ctx2, plca) end)
        end

    elseif s === CS_WAIT_TO
        # `curID` was set to 0 at CS_NEXT_TX_OPPORTUNITY T1 → RESYNC → …
        # or on the first WAIT_TO after SYNCING (from prev state == SYNCING).
        # Actually per plan §3.2: "curID is set to 0 at first TO start"
        # — we do it here if the previous state was SYNCING.
        # The simplest correct rule (matching INET's CS_SYNCING → CS_WAIT_TO
        # via curID=0 at cycle-start): set cur_id = 0 whenever we enter
        # WAIT_TO from SYNCING (implicit; controlled by NEXT_TX_OPPORTUNITY
        # incrementing from 0 up).
        # Schedule to_timer for empty-TO length.
        schedule_timer!(ctx, _bits_to_time(plca, plca.config.to_timer_length_bits),
            plca.module_id, plca.to_timer,
            function (ctx2) handle_with_control_fsm!(ctx2, plca) end)
        # Statistics: mark this TO's start. curID emission is now done via
        # _set_cur_id! at every change point (matches INET's on-change).
        plca.to_start_time = ctx.timestamp
        plca.packets_in_to = 0

    elseif s === CS_EARLY_RECEIVE
        cancel!(plca.to_timer)
        # Reschedule the beacon-detection timer.
        schedule_timer!(ctx, _bits_to_time(plca, plca.config.beacon_det_timer_length_bits),
            plca.module_id, plca.beacon_det_timer,
            function (ctx2) handle_with_control_fsm!(ctx2, plca) end)

    elseif s === CS_COMMIT
        _set_tx_cmd!(plca, ctx, CMD_COMMIT)
        plca.downlink.start_signal_tx(ctx, SIG_COMMIT)
        plca.committed = true
        cancel!(plca.to_timer)
        plca.bc = 0
        plca.upcalls.commit_to(ctx, plca)

    elseif s === CS_YIELD
        # Emit transmitOpportunityUsed = 0 (we didn't transmit in this TO).
        _emit_count!(plca, ctx, :transmitOpportunityUsed, 0)

    elseif s === CS_TRANSMIT
        # Emit transmitOpportunityUsed = 1 (this TO IS being used to transmit).
        # Emit only on the FIRST TRANSMIT of a TO (bc==0), not on BURST-driven
        # re-entries where we're still inside the same own TO.
        plca.bc == 0 && _emit_count!(plca, ctx, :transmitOpportunityUsed, 1)
        # End any tx_cmd signal (was COMMIT).
        if plca.tx_cmd !== CMD_NONE
            plca.downlink.end_signal_tx(ctx)
            _set_tx_cmd!(plca, ctx, CMD_NONE)
        end
        if plca.bc >= plca.config.max_bc
            plca.committed = false
        end

    elseif s === CS_BURST
        plca.bc += 1
        _set_tx_cmd!(plca, ctx, CMD_COMMIT)
        plca.downlink.start_signal_tx(ctx, SIG_COMMIT)
        schedule_timer!(ctx, _bits_to_time(plca, plca.config.burst_timer_length_bits),
            plca.module_id, plca.burst_timer,
            function (ctx2) handle_with_control_fsm!(ctx2, plca) end)

    elseif s === CS_ABORT
        if plca.tx_cmd !== CMD_NONE
            plca.downlink.end_signal_tx(ctx)
            _set_tx_cmd!(plca, ctx, CMD_NONE)
        end

    elseif s === CS_NEXT_TX_OPPORTUNITY
        # Emit toLength for the TO just ended. Note ownToLength when the
        # finishing TO was our own — remember the old cur_id BEFORE we
        # advance, because it identifies whose TO we just left.
        to_dur = SimTime(ctx.timestamp - plca.to_start_time)
        _emit_time!(plca, ctx, :toLength, to_dur)
        _emit_count!(plca, ctx, :numPacketsPerTo, plca.packets_in_to)
        if plca.cur_id == plca.config.local_node_id
            _emit_time!(plca, ctx, :ownToLength, to_dur)
            _emit_count!(plca, ctx, :numPacketsPerOwnTo, plca.packets_in_to)
        end
        _set_cur_id!(plca, ctx, plca.cur_id + 1)
        plca.committed = false
        # NOTE: do NOT reset cur_id to 0 here — the CS_RESYNC transition
        # depends on cur_id >= plca_node_count. The reset happens at
        # SYNCING → WAIT_TO (first-TO-start rule, plan §3.2 / INET
        # `EthernetPlca.cc:399-400`).
    end
end
