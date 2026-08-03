# ============================================================================
# PLCA data FSM — 9 states.
#
# For Phase 5 (transmit path only) we implement:
#   DS_IDLE, DS_WAIT_IDLE, DS_RECEIVE, DS_HOLD, DS_TRANSMIT
#
# The recovery path — DS_COLLIDE, DS_DELAY_PENDING, DS_PENDING, DS_WAIT_MAC
# — lands in Phase 7 once MAC (Phase 6) is present to close the collision
# loop.
#
# Interacts with the control FSM via shared variables on PlcaState
# (packet_pending, TX_EN, carrier_status) plus the COMMIT_TO signal that
# CS_COMMIT fires into DS_HOLD → DS_TRANSMIT.
# ============================================================================

# Enum ORDER matches INET's EthernetPlca.h::DataState — the integer values
# appear in cross-comparison `.vec` output, so alignment matters.
@enum PlcaDataState::UInt8 begin
    DS_WAIT_IDLE       = 0
    DS_IDLE            = 1
    DS_RECEIVE         = 2
    DS_HOLD            = 3
    DS_COLLIDE         = 4
    DS_DELAY_PENDING   = 5
    DS_PENDING         = 6
    DS_WAIT_MAC        = 7
    DS_TRANSMIT        = 8
end

# Extend PlcaState with a data-FSM slot. The struct already has `ds::UInt8`
# placeholder; here we give it a proper enum interpretation and a place to
# stash the current tx packet.
mutable struct PlcaDataFsm
    ds::PlcaDataState
    current_tx::Union{Nothing, Packet}
    # Timestamp the current currentTx first arrived from MAC — set on entry
    # to DS_HOLD, read on DS_TRANSMIT to compute packetPendingDelay.
    packet_arrival_time::SimTime
    # Timestamp of the last successful DS_TRANSMIT — for packetInterval.
    last_tx_time::SimTime
end
PlcaDataFsm() = PlcaDataFsm(DS_IDLE, nothing, SimTime(0), SimTime(0))

# Attach a PlcaDataFsm to the PLCA. Called at build time; the field is
# stored in the module-level Dict below since PlcaState doesn't have a
# native slot (would require re-shaping PlcaState — kept minimal here).
const _data_fsms = IdDict{PlcaState, PlcaDataFsm}()
plca_data(plca::PlcaState) = get!(_data_fsms, plca, PlcaDataFsm())

# ---------- entry points -----------------------------------------------------

"""
    plca_start_frame_transmission!(ctx, plca, packet)

Called by MAC (or in Phase 5, directly by test / app stub) to hand PLCA a
frame. Fires START_FRAME_TRANSMISSION into the data FSM.
"""
function plca_start_frame_transmission!(ctx, plca::PlcaState, packet::Packet)
    d = plca_data(plca)
    if d.ds === DS_IDLE
        d.current_tx = packet
        d.packet_arrival_time = ctx.timestamp
        _enter_data!(ctx, plca, DS_HOLD)
    elseif d.ds === DS_WAIT_IDLE
        d.current_tx = packet
        d.packet_arrival_time = ctx.timestamp
        _enter_data!(ctx, plca, DS_TRANSMIT)
    elseif d.ds === DS_RECEIVE
        # Contention — enter DS_COLLIDE. Phase 7 path.
        d.current_tx = nothing
        _enter_data!(ctx, plca, DS_COLLIDE)
    elseif d.ds === DS_WAIT_MAC
        # PLCA has been waiting for MAC's tx — accept immediately.
        # packet_arrival_time is preserved from the ORIGINAL arrival to
        # measure end-to-end pending delay including recovery cycles.
        d.current_tx = packet
        _enter_data!(ctx, plca, DS_TRANSMIT)
    else
        # In DS_HOLD / DS_TRANSMIT / DS_COLLIDE / DS_PENDING / DS_DELAY_PENDING:
        # MAC shouldn't send a new frame; treat as error to surface bugs.
        error("plca_start_frame_transmission!: unexpected ds=$(d.ds)")
    end
end

"""
    plca_end_frame_transmission!(ctx, plca)

Called by MAC to signal end of frame tx. Under Phase 5+ operation, the
tx_timer inside DS_TRANSMIT normally fires first and drives DS forward;
this hook is idempotent.
"""
function plca_end_frame_transmission!(ctx, plca::PlcaState)
    nothing
end

"""
    plca_start_signal_from_mac!(ctx, plca, kind::EthernetSignalKind)

MAC calls this via its downlink when it starts a signal (only JAM in
practice). PLCA absorbs JAM per plan §3.1 — it never actually reaches
the wire (INET `EthernetPlca.cc:311-316`). Other kinds are unexpected.
"""
function plca_start_signal_from_mac!(ctx, plca::PlcaState, kind::EthernetSignalKind)
    # Absorb: JAM is never emitted by PLCA (would confuse the multidrop
    # bus). The end_signal call below will advance DS_COLLIDE.
    return nothing
end

"""
    plca_end_signal_from_mac!(ctx, plca)

MAC calls this after JAM completes. Fires END_SIGNAL_TRANSMISSION into
the data FSM, which advances DS_COLLIDE → DS_DELAY_PENDING (§5.5).
"""
function plca_end_signal_from_mac!(ctx, plca::PlcaState)
    d = plca_data(plca)
    if d.ds === DS_COLLIDE
        _enter_data!(ctx, plca, DS_DELAY_PENDING)
    end
end

# ---------- COMMIT_TO from control FSM --------------------------------------

"CS_COMMIT (control FSM) → COMMIT_TO fires here to advance the data FSM."
function plca_commit_to!(ctx, plca::PlcaState)
    d = plca_data(plca)
    if d.ds === DS_HOLD
        cancel!(plca.hold_timer)
        _enter_data!(ctx, plca, DS_TRANSMIT)
    elseif d.ds === DS_PENDING
        _enter_data!(ctx, plca, DS_WAIT_MAC)
    else
        # Silent no-op for phases where COMMIT_TO fires against an
        # inactive DS — this can happen when the control FSM reaches
        # CS_COMMIT via a race we haven't modelled yet.
    end
end

# ---------- DS Enter actions -------------------------------------------------

function _enter_data!(ctx, plca::PlcaState, s::PlcaDataState)
    d = plca_data(plca)
    d.ds = s
    _emit_count!(plca, ctx, :dataState, UInt8(s))

    if s === DS_IDLE
        plca.packet_pending = false
        plca.carrier_status = false
        plca.signal_status = false
        plca.tx_en = false
        handle_with_control_fsm!(ctx, plca)

    elseif s === DS_WAIT_IDLE
        plca.packet_pending = false
        plca.carrier_status = false
        plca.signal_status = false
        plca.tx_en = false
        handle_with_control_fsm!(ctx, plca)

    elseif s === DS_HOLD
        plca.packet_pending = true
        plca.carrier_status = true
        # Schedule hold_timer to catch "control FSM never reaches COMMIT" (Phase 7).
        hold_bits = 4 * plca.config.delay_line_length
        schedule_timer!(ctx, _bits_to_time(plca, hold_bits),
            plca.module_id, plca.hold_timer,
            function (ctx2) _hold_timer_fired!(ctx2, plca) end)
        handle_with_control_fsm!(ctx, plca)

    elseif s === DS_TRANSMIT
        plca.packet_pending = false
        plca.carrier_status = true
        plca.signal_status = false
        plca.tx_en = true
        # End the COMMIT signal if we were still sending one from CS_COMMIT.
        if plca.tx_cmd === CMD_COMMIT
            plca.downlink.end_signal_tx(ctx)
            _set_tx_cmd!(plca, ctx, CMD_NONE)
        end
        # Emit packetPendingDelay: time from packet arrival to tx-start.
        # For worstcase, this is where the 231.6 µs figure surfaces.
        _emit_time!(plca, ctx, :packetPendingDelay,
                    SimTime(ctx.timestamp - d.packet_arrival_time))
        # Emit packetInterval: gap since last tx (0 for first tx).
        if d.last_tx_time > zero(d.last_tx_time)
            _emit_time!(plca, ctx, :packetInterval,
                        SimTime(ctx.timestamp - d.last_tx_time))
        end
        d.last_tx_time = ctx.timestamp
        # Count this packet toward per-TO / per-cycle stats.
        plca.packets_in_to += 1
        plca.packets_in_cycle += 1
        # Compute duration and hand the packet to PHY.
        pk = d.current_tx::Packet
        data_bits = data_length(pk).bits
        tx_bits = data_bits + ETHERNET_PHY_HEADER_LEN_BYTES * 8 +
                  ETHERNET_PHY_ESD_LEN_BYTES * 8
        schedule_timer!(ctx, to_simtime(tx_bits / plca.bitrate),
            plca.module_id, plca.tx_timer,
            function (ctx2) _tx_timer_fired!(ctx2, plca) end)
        esd = (plca.bc < plca.config.max_bc - 1) ? ESD_BRS : ESD_ESD
        plca.downlink.start_frame_tx(ctx, pk, esd)
        handle_with_control_fsm!(ctx, plca)

    elseif s === DS_RECEIVE
        plca.carrier_status = plca.crs && plca.rx_cmd !== CMD_COMMIT
        handle_with_control_fsm!(ctx, plca)

    # ---- Phase 7 recovery path ----
    elseif s === DS_COLLIDE
        plca.packet_pending = false
        plca.carrier_status = true
        plca.signal_status = true         # SIGNAL_ERROR — MAC's collision_start
        handle_with_control_fsm!(ctx, plca)

    elseif s === DS_DELAY_PENDING
        plca.signal_status = false        # clear SIGNAL_ERROR (MAC's collision_end)
        schedule_timer!(ctx,
            _bits_to_time(plca, plca.config.pending_timer_length_bits),
            plca.module_id, plca.pending_timer,
            function (ctx2) _pending_timer_fired!(ctx2, plca) end)
        handle_with_control_fsm!(ctx, plca)

    elseif s === DS_PENDING
        plca.packet_pending = true
        handle_with_control_fsm!(ctx, plca)

    elseif s === DS_WAIT_MAC
        plca.carrier_status = false
        schedule_timer!(ctx,
            _bits_to_time(plca, plca.config.commit_timer_length_bits),
            plca.module_id, plca.commit_timer,
            function (ctx2) _commit_timer_fired!(ctx2, plca) end)
        handle_with_control_fsm!(ctx, plca)
    end
end

# ---------- timer callbacks --------------------------------------------------

function _tx_timer_fired!(ctx, plca::PlcaState)
    d = plca_data(plca)
    if d.ds === DS_TRANSMIT
        plca.downlink.end_frame_tx(ctx)
        d.current_tx = nothing
        _enter_data!(ctx, plca, DS_WAIT_IDLE)
    end
end

function _hold_timer_fired!(ctx, plca::PlcaState)
    d = plca_data(plca)
    if d.ds === DS_HOLD
        # Phase 7: control FSM never reached CS_COMMIT in time — collision.
        d.current_tx = nothing
        _enter_data!(ctx, plca, DS_COLLIDE)
    end
end

function _pending_timer_fired!(ctx, plca::PlcaState)
    d = plca_data(plca)
    if d.ds === DS_DELAY_PENDING
        _enter_data!(ctx, plca, DS_PENDING)
    end
end

function _commit_timer_fired!(ctx, plca::PlcaState)
    d = plca_data(plca)
    if d.ds === DS_WAIT_MAC
        # MAC never re-tx'd; give up this attempt.
        _enter_data!(ctx, plca, DS_WAIT_IDLE)
    end
end

# ---------- PHY reception hooks (data-side) ---------------------------------
#
# Called on reception_start/end from PHY. Handles DS_IDLE → DS_RECEIVE
# transitions when a peer's data arrives.

function plca_data_on_reception_start!(ctx, plca::PlcaState, sig::WireEvent)
    d = plca_data(plca)
    if d.ds === DS_IDLE && sig.kind === SIG_DATA
        _enter_data!(ctx, plca, DS_RECEIVE)
    elseif d.ds === DS_HOLD && sig.kind === SIG_DATA
        # A peer started transmitting while we were holding — collision.
        cancel!(plca.hold_timer)
        d.current_tx = nothing
        _enter_data!(ctx, plca, DS_COLLIDE)
    end
end

function plca_data_on_reception_end!(ctx, plca::PlcaState, sig::WireEvent)
    d = plca_data(plca)
    if d.ds === DS_RECEIVE
        _enter_data!(ctx, plca, DS_IDLE)
    end
end
