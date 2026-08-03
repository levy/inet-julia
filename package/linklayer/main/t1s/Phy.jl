# ============================================================================
# EthernetCsmaPhy — the physical layer FSM (§5.3 of the plan).
#
# 5 states, faithful to INET's `EthernetCsmaPhy.cc:117-237`:
#
#   IDLE          nothing on wire
#   TRANSMITTING  we're driving the wire (BEACON / COMMIT / DATA / JAM)
#   RECEIVING     one or more peers are transmitting into us
#   COLLISION     we're transmitting while also receiving (or vice versa)
#   CRS_ON        just-finished tx/rx; carrier-off timer running
#
# All five kept. COLLISION is dead under PLCA-only operation (§3.2 of the
# plan) but the model must support the mixed CSMA/CD-vs-PLCA validation
# configs and the case where a WireJunction delivers two simultaneous rxs.
#
# Interface out to the layer above (PLCA or a test stub) is a struct of
# callback functions (`PhyUpcalls`). Interface out to the wire is a callback
# `PhyDownlink` that ferries `WireEvent`s to the junction. Both are
# late-bound so PHY can be unit-tested without the surrounding layers.
# ============================================================================

@enum PhyFsmState::UInt8 begin
    PHY_IDLE
    PHY_TRANSMITTING
    PHY_RECEIVING
    PHY_COLLISION
    PHY_CRS_ON
end

# One active rx signal being tracked (analog of INET's `RxSignal` in
# `EthernetCsmaPhy.h:60-73`). We keep a Vector to support multiple
# simultaneous receptions (mixed configs; §3.2 gotcha), even though
# PLCA-only never sees it grow past one.
mutable struct RxSignal
    signal::WireEvent
    rx_end_time::SimTime
end

# Upward interface — the layer above (PLCA in the full stack, a mock in
# unit tests) plugs in its `handle*` functions here.
struct PhyUpcalls
    carrier_sense_start :: Function        # (ctx, plca_ptr) -> ()
    carrier_sense_end   :: Function
    collision_start     :: Function
    collision_end       :: Function
    reception_start     :: Function        # (ctx, plca_ptr, sig::WireEvent)
    reception_end       :: Function        # (ctx, plca_ptr, sig::WireEvent)
end

# Downward interface — the junction the PHY is wired to.
struct PhyDownlink
    # Called when we start transmitting: hand `sig` to the junction with
    # the sending PHY's module_id already stamped inside.
    send_signal :: Function                # (ctx, sig::WireEvent) -> ()
    # Called on early tx-end (truncation): notify the junction to update
    # any in-flight replicas of our signal.
    truncate_signal :: Function            # (ctx, sig::WireEvent) -> ()
end

# Trivial no-op interfaces for testing PHY in isolation.
_noop6(args...) = nothing
const NO_UPCALLS  = PhyUpcalls(_noop6, _noop6, _noop6, _noop6, _noop6, _noop6)
const NO_DOWNLINK = PhyDownlink(_noop6, _noop6)

# Recording interface — a upcalls variant that records into a Vector
# for test inspection. Records (kind::Symbol, arg::Any).
function recording_upcalls(log::Vector)
    return PhyUpcalls(
        (ctx, _) -> push!(log, (:carrier_sense_start, ctx.timestamp)),
        (ctx, _) -> push!(log, (:carrier_sense_end,   ctx.timestamp)),
        (ctx, _) -> push!(log, (:collision_start,     ctx.timestamp)),
        (ctx, _) -> push!(log, (:collision_end,       ctx.timestamp)),
        (ctx, _, sig) -> push!(log, (:reception_start, ctx.timestamp, sig)),
        (ctx, _, sig) -> push!(log, (:reception_end,   ctx.timestamp, sig)),
    )
end

# ---------- PhyState ---------------------------------------------------------

mutable struct PhyState
    module_id::Int
    fsm::PhyFsmState
    # Currently-outgoing signal (nothing when not TRANSMITTING).
    current_tx::Union{Nothing, WireEvent}
    tx_end_time::SimTime
    # Incoming signals (usually 0 or 1; may be >1 under COLLISION).
    rx_signals::Vector{RxSignal}
    # Timers — via TimerHandle so we can cancel/re-schedule.
    rx_end_timer::TimerHandle
    crs_off_timer::TimerHandle
    # Interfaces
    upcalls::PhyUpcalls
    downlink::PhyDownlink
    # Opaque pointer passed as the second arg to upcalls; PLCA passes its
    # own state here so the mock and real code share a single signature.
    upper_ptr::Any
    # Bitrate for computing tx durations — set at build.
    bitrate::Float64
    # ---- statistics recording ----
    recorder::Any                       # Union{Nothing,Recorder}
    node_idx::Int                       # 1-based
    stat_handles::Dict{Symbol,Int}
    # busUsed accumulator: total simtime the wire was TX or RX on our end.
    bus_used::SimTime
    # Timestamp of the last TX/RX span start; used to close spans on end.
    tx_span_start::SimTime
    rx_span_start::SimTime
end

function PhyState(module_id::Int; bitrate::Float64 = 10.0e6,
                  upcalls::PhyUpcalls = NO_UPCALLS,
                  downlink::PhyDownlink = NO_DOWNLINK,
                  upper_ptr::Any = nothing)
    PhyState(module_id, PHY_IDLE, nothing, SimTime(0),
             RxSignal[], TimerHandle(), TimerHandle(),
             upcalls, downlink, upper_ptr, bitrate,
             nothing, 0, Dict{Symbol,Int}(),
             SimTime(0), SimTime(0), SimTime(0))
end

# ---------- statistics-emit helpers -----------------------------------------

function _phy_emit!(phy::PhyState, ctx, name::Symbol, value::Real)
    phy.recorder === nothing && return
    idx = get(phy.stat_handles, name, 0)
    idx > 0 || return
    emit_indexed_vector!(phy.recorder, idx, ctx, Float64(value))
end

function _phy_transition!(phy::PhyState, ctx, new::PhyFsmState)
    phy.fsm == new && return
    phy.fsm = new
    _phy_emit!(phy, ctx, :state, UInt8(new))
end

# ---------- Event handlers ---------------------------------------------------
#
# These are the entry points into the PHY FSM. Each corresponds to one of
# the events named in the transition table (analysis §3.2):
#   TX_START    phy_start_frame_transmission!  /  phy_start_signal_transmission!
#   TX_END      phy_end_frame_transmission!    /  phy_end_signal_transmission!
#   RX_START    phy_rx_start!
#   RX_UPDATE   phy_rx_update!                 (truncation from a peer)
#   RX_END      (rx_end_timer callback)
#   CRS_OFF     (crs_off_timer callback)

# The plan's transition table (§5.3, from EthernetCsmaPhy.cc:117-237):
#
# IDLE:
#   TX_START      → TRANSMITTING;  upcalls.carrier_sense_start
#   RX_START      → RECEIVING;     upcalls.carrier_sense_start
# TRANSMITTING:
#   TX_END        → CRS_ON;        _handle_end_tx!
#   RX_START      → COLLISION;     _handle_start_rx!; upcalls.collision_start
# RECEIVING:
#   RX_START      → RECEIVING;     _update_rx_signals!
#   RX_UPDATE     → RECEIVING;     _update_rx_signals!
#   RX_END_TIMER  → CRS_ON;        _handle_end_reception!
#   TX_START      → COLLISION;     _handle_start_tx!; upcalls.collision_start
# COLLISION:
#   TX_START(JAM) → COLLISION;     _handle_start_tx!
#   TX_END && no rx pending      → CRS_ON;    _handle_end_tx!; upcalls.collision_end
#   TX_END && rx pending          → COLLISION; _handle_end_tx!
#   RX_START / RX_UPDATE          → COLLISION; _update_rx_signals!
#   RX_END_TIMER && currentTx     → COLLISION; _handle_end_reception!
#   RX_END_TIMER && !currentTx    → CRS_ON;    _handle_end_reception!; upcalls.collision_end
# CRS_ON:
#   TX_START      → TRANSMITTING;  _handle_start_tx!
#   RX_START      → RECEIVING;     _handle_start_rx!
#   CRS_OFF_TIMER → IDLE;          upcalls.carrier_sense_end

# --- TX_START: starting a data frame -----------------------------------------

"""
    phy_start_frame_transmission!(ctx, phy, packet::Packet, esd::EthernetEsdKind)

Called by PLCA/MAC when it hands us a frame to put on the wire. Encapsulates
the packet in a WireEvent(kind=DATA), schedules the crs_off timer, sends
to junction. Fires `carrier_sense_start` upward on IDLE→TRANSMITTING.
"""
function phy_start_frame_transmission!(ctx, phy::PhyState,
                                       packet::Packet, esd::EthernetEsdKind)
    # Duration: payload bits + PHY header (64) + ESD (8) if present.
    payload_bits = data_length(packet).bits
    esd_bits = esd === ESD_NONE ? 0 : ETHERNET_PHY_ESD_LEN_BYTES * 8
    duration_seconds = (payload_bits + ETHERNET_PHY_HEADER_LEN_BYTES * 8 + esd_bits) /
                       phy.bitrate
    duration = to_simtime(duration_seconds)
    sig = WireEvent(SIG_DATA, packet, esd, duration, phy.module_id, false)
    _do_start_tx!(ctx, phy, sig)
end

"""
    phy_start_signal_transmission!(ctx, phy, kind::EthernetSignalKind)

For BEACON / COMMIT / JAM — signals with no encapsulated packet. Duration
depends on `kind`:
  BEACON = 20 bits (`EthernetCsmaPhy.cc:245`)
  COMMIT = 640 bits (a safety ceiling; always truncated — plan §3.3)
  JAM    = 32 bits (`JAM_SIGNAL_BYTES * 8`)
"""
function phy_start_signal_transmission!(ctx, phy::PhyState, kind::EthernetSignalKind)
    duration_bits =
        kind === SIG_BEACON ? 20 :
        kind === SIG_COMMIT ? 640 :
        kind === SIG_JAM    ? JAM_SIGNAL_BYTES * 8 :
        error("phy_start_signal_transmission!: unexpected kind $kind")
    duration = to_simtime(duration_bits / phy.bitrate)
    sig = WireEvent(kind, nothing, ESD_NONE, duration, phy.module_id, false)
    _do_start_tx!(ctx, phy, sig)
end

function _do_start_tx!(ctx, phy::PhyState, sig::WireEvent)
    prev = phy.fsm
    # Statistics: transmissionStarted + transmittedSignalType fire on every
    # tx start; bus_used accumulator starts.
    _phy_emit!(phy, ctx, :transmitting, 1)
    _phy_emit!(phy, ctx, :transmittedSignalType, UInt8(sig.kind))
    phy.tx_span_start = ctx.timestamp
    if prev === PHY_IDLE
        _phy_transition!(phy, ctx, PHY_TRANSMITTING)
        _install_tx!(ctx, phy, sig)
        phy.upcalls.carrier_sense_start(ctx, phy.upper_ptr)
    elseif prev === PHY_CRS_ON
        _phy_transition!(phy, ctx, PHY_TRANSMITTING)
        cancel!(phy.crs_off_timer)
        _install_tx!(ctx, phy, sig)
        # No carrier_sense_start — already up from previous tx/rx.
    elseif prev === PHY_RECEIVING
        _phy_transition!(phy, ctx, PHY_COLLISION)
        _install_tx!(ctx, phy, sig)
        phy.upcalls.collision_start(ctx, phy.upper_ptr)
    elseif prev === PHY_COLLISION
        # JAM entering during COLLISION: keep state, but INET
        # asserts current_tx === nothing here (JAM only overlays).
        _install_tx!(ctx, phy, sig)
    elseif prev === PHY_TRANSMITTING
        # Attempted to start a tx while already transmitting — programmer error.
        error("phy_start_tx: already TRANSMITTING (module_id=$(phy.module_id))")
    end
    return nothing
end

function _install_tx!(ctx, phy::PhyState, sig::WireEvent)
    phy.current_tx = sig
    phy.tx_end_time = ctx.timestamp + sig.duration
    phy.downlink.send_signal(ctx, sig)
end

# --- TX_END: end of transmission --------------------------------------------

"Called when PLCA/MAC tells us its tx is complete (frame or signal)."
function phy_end_frame_transmission!(ctx, phy::PhyState)
    _do_end_tx!(ctx, phy)
end
phy_end_signal_transmission!(ctx, phy::PhyState) = _do_end_tx!(ctx, phy)

function _do_end_tx!(ctx, phy::PhyState)
    prev_sig = phy.current_tx
    prev_sig === nothing && error("phy_end_tx: no current_tx (module_id=$(phy.module_id))")
    # If end came early (before tx_end_time), we must truncate any in-flight
    # replicas at the junction. The junction propagates the update.
    actual_end = ctx.timestamp
    was_truncated = actual_end < phy.tx_end_time
    if was_truncated
        truncated = WireEvent(prev_sig.kind, prev_sig.packet, prev_sig.esd,
                              actual_end - (phy.tx_end_time - prev_sig.duration),
                              prev_sig.src_module_id, true)
        phy.downlink.truncate_signal(ctx, truncated)
    end
    phy.current_tx = nothing
    # Statistics: transmitting=0 (tx ended) + transmittedSignalType=0
    # (INET emits both edges of the tx interval) + busUsed accumulator.
    _phy_emit!(phy, ctx, :transmitting, 0)
    _phy_emit!(phy, ctx, :transmittedSignalType, 0)
    phy.bus_used += ctx.timestamp - phy.tx_span_start
    phy.tx_span_start = SimTime(0)

    if phy.fsm === PHY_TRANSMITTING
        # → CRS_ON, schedule crs_off_timer at max(rx_end, tx_end) — here just tx_end.
        _to_crs_on!(ctx, phy)
    elseif phy.fsm === PHY_COLLISION
        # Ends only depend on rx being drained: if any rx still active,
        # stay in COLLISION; else → CRS_ON and fire collision_end.
        if !isempty(phy.rx_signals)
            # stay COLLISION
        else
            _phy_transition!(phy, ctx, PHY_CRS_ON)
            _schedule_crs_off!(ctx, phy)
            phy.upcalls.collision_end(ctx, phy.upper_ptr)
        end
    end
    return nothing
end

# --- RX_START: a peer's signal arrived at us --------------------------------

"Called by the junction when a peer signal arrives at our port."
function phy_rx_start!(ctx, phy::PhyState, sig::WireEvent)
    # Ignore signals we sent (shouldn't happen with the junction filter,
    # defensive).
    sig.src_module_id == phy.module_id && return

    prev = phy.fsm
    push!(phy.rx_signals, RxSignal(sig, ctx.timestamp + sig.duration))
    _reschedule_rx_end!(ctx, phy)
    # Statistics: receptionStarted + receivedSignalType. rx_span_start marks
    # the beginning of a rx-active span (idempotent — already set if a
    # concurrent rx is going).
    # INET only emits receivedSignalType (not separate started/ended flags).
    _phy_emit!(phy, ctx, :receivedSignalType, UInt8(sig.kind))
    if iszero(phy.rx_span_start)
        phy.rx_span_start = ctx.timestamp
    end

    if prev === PHY_IDLE
        _phy_transition!(phy, ctx, PHY_RECEIVING)
        phy.upcalls.carrier_sense_start(ctx, phy.upper_ptr)
        phy.upcalls.reception_start(ctx, phy.upper_ptr, sig)
    elseif prev === PHY_CRS_ON
        _phy_transition!(phy, ctx, PHY_RECEIVING)
        cancel!(phy.crs_off_timer)
        # No carrier_sense_start — carrier is already up.
        phy.upcalls.reception_start(ctx, phy.upper_ptr, sig)
    elseif prev === PHY_TRANSMITTING
        _phy_transition!(phy, ctx, PHY_COLLISION)
        phy.upcalls.collision_start(ctx, phy.upper_ptr)
    elseif prev === PHY_RECEIVING || prev === PHY_COLLISION
        # Add to the list; state doesn't change. INET calls updateRxSignals.
    end
    return nothing
end

# Update a specific rx signal — for truncation propagated from the sender.
function phy_rx_update!(ctx, phy::PhyState, sig::WireEvent)
    # Find the matching in-flight rx (by src) and update its end time.
    idx = findfirst(r -> r.signal.src_module_id == sig.src_module_id, phy.rx_signals)
    idx === nothing && return
    phy.rx_signals[idx] = RxSignal(sig, ctx.timestamp + sig.duration)
    _reschedule_rx_end!(ctx, phy)
end

# --- Timer callbacks --------------------------------------------------------

function _reschedule_rx_end!(ctx, phy::PhyState)
    isempty(phy.rx_signals) && (cancel!(phy.rx_end_timer); return)
    max_end = maximum(r.rx_end_time for r in phy.rx_signals)
    delay = max_end - ctx.timestamp
    schedule_timer!(ctx, delay, phy.module_id, phy.rx_end_timer,
        function (ctx2) _handle_rx_end_timer!(ctx2, phy) end)
end

function _handle_rx_end_timer!(ctx, phy::PhyState)
    # Determine which rx just ended (any at ctx.timestamp).
    ending_now = filter(r -> r.rx_end_time == ctx.timestamp, phy.rx_signals)
    still_active = filter(r -> r.rx_end_time > ctx.timestamp, phy.rx_signals)
    phy.rx_signals = still_active

    # Deliver each ended rx to upper layer (if exactly one; else the frame was
    # corrupted by overlap and is dropped).
    if Base.length(ending_now) == 1 && phy.fsm !== PHY_COLLISION
        phy.upcalls.reception_end(ctx, phy.upper_ptr, ending_now[1].signal)
    end
    # INET emits receivedSignalType=0 at rx end (mirror of tx behaviour).
    for _ in ending_now
        _phy_emit!(phy, ctx, :receivedSignalType, 0)
    end
    # If more still active or we're COLLISION, reschedule.
    if !isempty(still_active)
        _reschedule_rx_end!(ctx, phy)
    end

    # State transitions
    if isempty(still_active)
        # bus_used accumulator: close the rx span.
        if phy.rx_span_start > zero(phy.rx_span_start)
            phy.bus_used += ctx.timestamp - phy.rx_span_start
            phy.rx_span_start = SimTime(0)
        end
        if phy.fsm === PHY_RECEIVING
            _to_crs_on!(ctx, phy)
        elseif phy.fsm === PHY_COLLISION
            if phy.current_tx === nothing
                _phy_transition!(phy, ctx, PHY_CRS_ON)
                _schedule_crs_off!(ctx, phy)
                phy.upcalls.collision_end(ctx, phy.upper_ptr)
            end  # else keep in COLLISION until tx also ends
        end
    end
    return nothing
end

function _to_crs_on!(ctx, phy::PhyState)
    _phy_transition!(phy, ctx, PHY_CRS_ON)
    _schedule_crs_off!(ctx, phy)
end

function _schedule_crs_off!(ctx, phy::PhyState)
    # Fires at max(rx_end, tx_end). Here tx is already ended so it's just now.
    # crs_off is essentially "one delta"; INET uses SHRT_MAX priority so it
    # fires before same-time reception starts. We schedule with zero delay;
    # if a RX_START arrives at the same simtime it must be processed FIRST
    # (see Q1). Our schedule-order tweak: don't schedule crs_off at zero;
    # schedule it at delta = 1 ps so RX_START at exact now still races.
    #
    # Actually INET's crs_off_timer priority is highest (SHRT_MAX) and fires
    # AT ctx.timestamp. Any concurrent RX_START scheduled by the caller then
    # fires *after*; the semantics INET produces is CRS goes off, then
    # immediately back on. We replicate that with delay 0 and rely on
    # insertion order: crs_off is scheduled first, then whatever the caller
    # schedules is later in the queue.
    schedule_timer!(ctx, SimTime(0), phy.module_id, phy.crs_off_timer,
        function (ctx2) _handle_crs_off_timer!(ctx2, phy) end)
end

function _handle_crs_off_timer!(ctx, phy::PhyState)
    # Only actually fires the carrier-off if there's no rx that started
    # at the same simtime.
    if isempty(phy.rx_signals) && phy.current_tx === nothing
        _phy_transition!(phy, ctx, PHY_IDLE)
        phy.upcalls.carrier_sense_end(ctx, phy.upper_ptr)
    end
    return nothing
end
