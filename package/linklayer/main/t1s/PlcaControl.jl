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
# The 14-state control machine is NOT written here. It is a state machine
# document, and `PlcaControlFsm.jl` beside this file is generated from it:
#
#     tool/generate_plca_control_fsm.jl   the machine (states, the conditions
#                                         that move it, the code around them)
#     t1s/PlcaControlFsm.jl               generated — do not edit
#
# The generated file defines `PlcaState` (shared with the data FSM, whose `ds`
# is an ordinary field it owns), the state constants, `control_dispatch!`, the
# entry actions and `handle_with_control_fsm!`. What stays here is the part
# ahead of that struct — the enums and interface types its fields are
# annotated with — plus the keyword constructor and the PHY-facing callbacks.

include("PlcaControlFsm.jl")

"""
    PlcaState(module_id, config; bitrate, upcalls, downlink)

Build a PLCA node's shared state. The generated struct's field order is the
machine, then the timers, then the variables, so every field is passed
explicitly rather than positionally by accident.
"""
function PlcaState(module_id::Int, config::PlcaConfig; bitrate::Float64 = 10.0e6,
                   upcalls::PlcaControlUpcalls = NO_PLCA_UPCALLS,
                   downlink::PlcaDownlink = NO_PLCA_DOWNLINK)
    plca = PlcaState(Fsm(:Control, CONTROL_S_DISABLE),
                     TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(),
                     TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(),
                     TimerHandle(),
                     module_id, config, bitrate,
                     0x00,                # ds — the data FSM's, not ours
                     false, false, false, false,   # packet_pending/tx_en/carrier/signal
                     false, false, false,          # crs/col/receiving
                     CMD_NONE, CMD_NONE,           # rx_cmd/tx_cmd
                     0, 0, false,                  # cur_id/bc/committed
                     false, false,                 # edge caches
                     false,                        # in_fsm re-entrancy guard
                     upcalls, downlink,
                     nothing, 0, Dict{Symbol,Int}(),
                     SimTime(0), SimTime(0), 0, 0, 0)
    plca.fsm_control.on_transition = (fsm, from, to, index) -> _plca_on_transition(plca, to)
    plca
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
    # Installed directly, not dispatched: a state set outside a dispatch runs
    # no entry action, which is what the machine's startup rule says and what
    # the hand-written `plca.cs = CS_RESYNC` did.
    plca.fsm_control.state = CONTROL_S_RESYNC
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
