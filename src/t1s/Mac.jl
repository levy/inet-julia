# ============================================================================
# EthernetCsmaMac — 6-state FSM faithful to EthernetCsmaMac.cc:184-314.
#
# States:
#   MAC_IDLE           nothing pending
#   MAC_WAIT_IFG       just finished tx/rx; waiting IFG (9.6 µs)
#   MAC_TRANSMITTING   handing frame to PLCA, tx_timer running
#   MAC_JAMMING        collision detected; jam signal running (3.2 µs)
#   MAC_BACKOFF        after JAM; waiting slot before retry
#   MAC_RECEIVING      carrier is up (peer is transmitting)
#
# Under PLCA-only operation, JAMMING/BACKOFF fire ONLY when PLCA's
# DS_COLLIDE raises SIGNAL_ERROR (Phase 7). They're dormant in Phase 6.
# ============================================================================

const MAX_ATTEMPTS           = 16       # Ethernet.h:43
const BACKOFF_RANGE_LIMIT    = 10       # Ethernet.h:44
const SLOT_BIT_LENGTH_10MB   = 512      # EthernetModes.cc:31

@enum MacFsmState::UInt8 begin
    MAC_IDLE
    MAC_WAIT_IFG
    MAC_TRANSMITTING
    MAC_JAMMING
    MAC_BACKOFF
    MAC_RECEIVING
end

# Downward interface — the PLCA layer.
struct MacDownlink
    start_frame_tx   :: Function     # (ctx, packet, esd_ignored) — PLCA sees ESD from data FSM
    end_frame_tx     :: Function     # (ctx)
    start_signal_tx  :: Function     # (ctx, kind::EthernetSignalKind)  # JAM
    end_signal_tx    :: Function     # (ctx)
end

_mac_no_downlink(_...) = nothing
const NO_MAC_DOWNLINK = MacDownlink(_mac_no_downlink, _mac_no_downlink,
                                     _mac_no_downlink, _mac_no_downlink)

# Upward interface — the app / queue above.
struct MacUpcalls
    frame_received :: Function       # (ctx, mac, packet) — deliver rx frame
    frame_sent     :: Function       # (ctx, mac)         — tx completed
end

_mac_no_upcall(_...) = nothing
const NO_MAC_UPCALLS = MacUpcalls(_mac_no_upcall, _mac_no_upcall)

mutable struct MacState
    module_id::Int
    fsm::MacFsmState
    current_tx_frame::Union{Nothing, Packet}
    queue::Vector{Packet}                # egress queue
    num_retries::Int
    carrier_sense::Bool
    collision::Bool
    tx_timer::TimerHandle
    ifg_timer::TimerHandle
    jam_timer::TimerHandle
    backoff_timer::TimerHandle
    rng::MersenneTwister
    bitrate::Float64
    address::UInt64                      # this node's MAC (for src filter)
    promiscuous::Bool
    downlink::MacDownlink
    upcalls::MacUpcalls
    # PLCA's esd length seen from MAC (analysis: 8 bits for the PLCA shim).
    phy_esd_length_bits::Int
    # ---- statistics recording ----
    recorder::Any                       # Union{Nothing,Recorder}
    node_idx::Int                       # 1-based
    stat_handles::Dict{Symbol,Int}
    num_frames_sent::Int
    num_frames_received::Int
end

function MacState(module_id::Int, address::UInt64;
                  bitrate::Float64 = 10.0e6,
                  seed::Integer = Int(address),
                  promiscuous::Bool = false,
                  downlink::MacDownlink = NO_MAC_DOWNLINK,
                  upcalls::MacUpcalls = NO_MAC_UPCALLS)
    MacState(module_id, MAC_IDLE,
             nothing, Packet[], 0,
             false, false,
             TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(),
             MersenneTwister(seed), bitrate, address, promiscuous,
             downlink, upcalls,
             ETHERNET_PHY_ESD_LEN_BYTES * 8,
             nothing, 0, Dict{Symbol,Int}(), 0, 0)
end

# ---------- statistics-emit helpers -----------------------------------------

"Emit a count / enum / MAC signal (Real → Float64)."
function _mac_emit!(mac::MacState, ctx, name::Symbol, value::Real)
    mac.recorder === nothing && return
    idx = get(mac.stat_handles, name, 0)
    idx > 0 || return
    emit_indexed_vector!(mac.recorder, idx, ctx, Float64(value))
end

# Transition helper — sets fsm state and emits stateChanged.
function _mac_transition!(mac::MacState, ctx, new_state::MacFsmState)
    mac.fsm == new_state && return
    mac.fsm = new_state
    _mac_emit!(mac, ctx, :state, UInt8(new_state))
end

# ---------- events from PLCA (upward-facing hooks) --------------------------

"Called when PLCA sees carrier come up (via its edge-detection)."
function mac_handle_carrier_sense_start!(ctx, mac::MacState)
    mac.carrier_sense = true
    _mac_emit!(mac, ctx, :carrierSense, 1)
    if mac.fsm === MAC_IDLE
        _mac_transition!(mac, ctx, MAC_RECEIVING)
    end
end

function mac_handle_carrier_sense_end!(ctx, mac::MacState)
    mac.carrier_sense = false
    _mac_emit!(mac, ctx, :carrierSense, 0)
    if mac.fsm === MAC_RECEIVING
        _start_ifg!(ctx, mac)
    end
end

"Called when PLCA's DS_COLLIDE fires SIGNAL_ERROR (Phase 7)."
function mac_handle_collision_start!(ctx, mac::MacState)
    mac.collision = true
    _mac_emit!(mac, ctx, :collision, 1)
    if mac.fsm === MAC_TRANSMITTING
        # Abort tx: end frame tx, start JAM signal.
        cancel!(mac.tx_timer)
        mac.downlink.end_frame_tx(ctx)
        mac.downlink.start_signal_tx(ctx, SIG_JAM)
        _mac_transition!(mac, ctx, MAC_JAMMING)
        # jam_timer = 3.2 µs @ 10 Mb
        schedule_timer!(ctx, to_simtime((JAM_SIGNAL_BYTES * 8) / mac.bitrate),
            mac.module_id, mac.jam_timer,
            function (ctx2) _mac_end_jam!(ctx2, mac) end)
    end
end

function mac_handle_collision_end!(ctx, mac::MacState)
    mac.collision = false
    _mac_emit!(mac, ctx, :collision, 0)
end

"Called when PLCA delivers a received DATA frame."
function mac_handle_reception_end!(ctx, mac::MacState, kind::EthernetSignalKind,
                                    packet::Union{Nothing,Packet})
    kind === SIG_DATA || return                         # ignore JAM etc.
    packet === nothing && return
    _process_received_frame!(ctx, mac, packet)
end

# ---------- app-facing hook -------------------------------------------------

"App/queue pushes a packet onto the egress queue. MAC dequeues at IDLE."
function mac_upper_packet!(ctx, mac::MacState, packet::Packet)
    push!(mac.queue, packet)
    if mac.fsm === MAC_IDLE && mac.current_tx_frame === nothing
        _dequeue_and_transmit!(ctx, mac)
    end
end

# ---------- internal transitions -------------------------------------------

function _dequeue_and_transmit!(ctx, mac::MacState)
    isempty(mac.queue) && return
    mac.current_tx_frame = popfirst!(mac.queue)
    _start_frame_transmission!(ctx, mac)
end

function _start_frame_transmission!(ctx, mac::MacState)
    _mac_transition!(mac, ctx, MAC_TRANSMITTING)
    mac.num_retries = 0
    pk = mac.current_tx_frame::Packet
    # tx_timer = (frame_bits + phy_hdr + phy_esd) / bitrate.
    frame_bits = data_length(pk).bits
    tx_bits = frame_bits + ETHERNET_PHY_HEADER_LEN_BYTES * 8 + mac.phy_esd_length_bits
    schedule_timer!(ctx, to_simtime(tx_bits / mac.bitrate),
        mac.module_id, mac.tx_timer,
        function (ctx2) _mac_end_tx!(ctx2, mac) end)
    # ESD kind is chosen by PLCA (data FSM); pass a placeholder — the
    # downlink adapter can rewrap if needed.
    mac.downlink.start_frame_tx(ctx, pk, ESD_ESD)
end

function _mac_end_tx!(ctx, mac::MacState)
    mac.fsm === MAC_TRANSMITTING || return
    mac.downlink.end_frame_tx(ctx)
    mac.current_tx_frame = nothing
    mac.num_frames_sent += 1
    _mac_emit!(mac, ctx, :numFramesSent, mac.num_frames_sent)
    mac.upcalls.frame_sent(ctx, mac)
    if mac.carrier_sense
        _mac_transition!(mac, ctx, MAC_RECEIVING)
    else
        _start_ifg!(ctx, mac)
    end
end

function _mac_end_jam!(ctx, mac::MacState)
    mac.fsm === MAC_JAMMING || return
    mac.downlink.end_signal_tx(ctx)
    mac.num_retries += 1
    if mac.num_retries >= MAX_ATTEMPTS
        # Give up.
        mac.current_tx_frame = nothing
        if mac.carrier_sense
            _mac_transition!(mac, ctx, MAC_RECEIVING)
        else
            _start_ifg!(ctx, mac)
        end
    else
        # BACKOFF: schedule backoff timer.
        _mac_transition!(mac, ctx, MAC_BACKOFF)
        slot_max = 1 << min(mac.num_retries, BACKOFF_RANGE_LIMIT)
        slot = rand(mac.rng, 0:slot_max - 1)
        schedule_timer!(ctx, to_simtime((slot * SLOT_BIT_LENGTH_10MB) / mac.bitrate),
            mac.module_id, mac.backoff_timer,
            function (ctx2) _mac_end_backoff!(ctx2, mac) end)
    end
end

function _mac_end_backoff!(ctx, mac::MacState)
    mac.fsm === MAC_BACKOFF || return
    if mac.carrier_sense
        _mac_transition!(mac, ctx, MAC_RECEIVING)
    else
        _start_ifg!(ctx, mac)
    end
end

function _start_ifg!(ctx, mac::MacState)
    _mac_transition!(mac, ctx, MAC_WAIT_IFG)
    schedule_timer!(ctx, to_simtime(INTERFRAME_GAP_BITS / mac.bitrate),
        mac.module_id, mac.ifg_timer,
        function (ctx2) _mac_end_ifg!(ctx2, mac) end)
end

function _mac_end_ifg!(ctx, mac::MacState)
    mac.fsm === MAC_WAIT_IFG || return
    if mac.current_tx_frame !== nothing
        _start_frame_transmission!(ctx, mac)
    elseif !isempty(mac.queue)
        _dequeue_and_transmit!(ctx, mac)
    elseif mac.carrier_sense
        _mac_transition!(mac, ctx, MAC_RECEIVING)
    else
        _mac_transition!(mac, ctx, MAC_IDLE)
    end
end

function _process_received_frame!(ctx, mac::MacState, packet::Packet)
    # MAC-level dst filter unless promiscuous.
    hdr = peek(packet, EthernetMacHeader)
    dst = mac_pack(hdr.dst_mac_hi, hdr.dst_mac_lo)
    is_broadcast = dst == 0xFFFFFFFFFFFF
    if mac.promiscuous || dst == mac.address || is_broadcast
        mac.num_frames_received += 1
        _mac_emit!(mac, ctx, :numFramesReceived, mac.num_frames_received)
        mac.upcalls.frame_received(ctx, mac, packet)
    end
end
