# Generated from the state machine `Mac` — edit the machine, not this file.


  const MAC_S_IDLE = Int32(0)
  const MAC_S_WAIT_IFG = Int32(1)
  const MAC_S_TRANSMITTING = Int32(2)
  const MAC_S_JAMMING = Int32(3)
  const MAC_S_BACKOFF = Int32(4)
  const MAC_S_RECEIVING = Int32(5)
  const MAC_STATE_NAMES = ("IDLE", "WAIT_IFG", "TRANSMITTING", "JAMMING", "BACKOFF", "RECEIVING")
  const E_CARRIER_SENSE_START = Int32(1)
  const E_CARRIER_SENSE_END = Int32(2)
  const E_COLLISION_START = Int32(3)
  const E_UPPER_PACKET = Int32(4)
  const T_TX_TIMER = Int32(5)
  const T_IFG_TIMER = Int32(6)
  const T_JAM_TIMER = Int32(7)
  const T_BACKOFF_TIMER = Int32(8)
  mutable struct MacState

    fsm_mac::Fsm
    tx_timer::TimerHandle
    ifg_timer::TimerHandle
    jam_timer::TimerHandle
    backoff_timer::TimerHandle
    module_id::Int
    current_tx_frame::Union{Nothing, Packet}
    queue::Vector{Packet}
    num_retries::Int
    carrier_sense::Bool
    collision::Bool
    rng::MersenneTwister
    bitrate::Float64
    address::UInt64
    promiscuous::Bool
    downlink::MacDownlink
    upcalls::MacUpcalls
    phy_esd_length_bits::Int
    recorder::Any
    node_idx::Int
    stat_handles::Dict{Symbol, Int}
    num_frames_sent::Int
    num_frames_received::Int
  end
  MacState() = MacState(Fsm(Symbol("Mac"), MAC_S_IDLE), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), nothing, nothing, Packet[], 0, false, false, MersenneTwister(0), 1.0e7, 0, false, NO_MAC_DOWNLINK, NO_MAC_UPCALLS, ETHERNET_PHY_ESD_LEN_BYTES * 8, nothing, 0, Dict{Symbol, Int}(), 0, 0)
  function mac_dispatch!(ctx, m::MacState, event::Int32, payload)
    fsm_enter!(m.fsm_mac)
    _is_event = event != Int32(0)
    _consumed = !_is_event
    _steps = 0
    while true
      _fired = false
      _from = fsm_state(m.fsm_mac)
      if fsm_state(m.fsm_mac) == MAC_S_IDLE
        if _is_event && event == E_CARRIER_SENSE_START
          fsm_goto!(m.fsm_mac, MAC_S_RECEIVING, 1)
          _fired = true
        else
          if _is_event && event == E_UPPER_PACKET && m.current_tx_frame === nothing && !isempty(m.queue)
            m.current_tx_frame = popfirst!(m.queue)
            fsm_goto!(m.fsm_mac, MAC_S_TRANSMITTING, 2)
            prev = _from
            ev = event
            _mac_start_frame_transmission!(ctx, m)
            _fired = true
          
          end
        end
      else
        if fsm_state(m.fsm_mac) == MAC_S_WAIT_IFG
          if _is_event && event == T_IFG_TIMER && m.current_tx_frame !== nothing
            fsm_goto!(m.fsm_mac, MAC_S_TRANSMITTING, 3)
            prev = _from
            ev = event
            _mac_start_frame_transmission!(ctx, m)
            _fired = true
          else
            if _is_event && event == T_IFG_TIMER && !isempty(m.queue)
              m.current_tx_frame = popfirst!(m.queue)
              fsm_goto!(m.fsm_mac, MAC_S_TRANSMITTING, 4)
              prev = _from
              ev = event
              _mac_start_frame_transmission!(ctx, m)
              _fired = true
            else
              if _is_event && event == T_IFG_TIMER && m.carrier_sense
                fsm_goto!(m.fsm_mac, MAC_S_RECEIVING, 5)
                _fired = true
              else
                if _is_event && event == T_IFG_TIMER
                  fsm_goto!(m.fsm_mac, MAC_S_IDLE, 6)
                  _fired = true
                
                end
              end
            end
          end
        else
          if fsm_state(m.fsm_mac) == MAC_S_TRANSMITTING
            if _is_event && event == E_COLLISION_START
              _mac_abort_transmission!(ctx, m)
              fsm_goto!(m.fsm_mac, MAC_S_JAMMING, 7)
              prev = _from
              ev = event
              _mac_start_jam_timer!(ctx, m)
              _fired = true
            else
              if _is_event && event == T_TX_TIMER && m.carrier_sense
                _mac_finish_transmission!(ctx, m)
                fsm_goto!(m.fsm_mac, MAC_S_RECEIVING, 8)
                _fired = true
              else
                if _is_event && event == T_TX_TIMER
                  _mac_finish_transmission!(ctx, m)
                  fsm_goto!(m.fsm_mac, MAC_S_WAIT_IFG, 9)
                  prev = _from
                  ev = event
                  _mac_start_ifg_timer!(ctx, m)
                  _fired = true
                
                end
              end
            end
          else
            if fsm_state(m.fsm_mac) == MAC_S_JAMMING
              if _is_event && event == T_JAM_TIMER && m.num_retries >= MAX_ATTEMPTS && m.carrier_sense
                m.current_tx_frame = nothing
                fsm_goto!(m.fsm_mac, MAC_S_RECEIVING, 10)
                _fired = true
              else
                if _is_event && event == T_JAM_TIMER && m.num_retries >= MAX_ATTEMPTS
                  m.current_tx_frame = nothing
                  fsm_goto!(m.fsm_mac, MAC_S_WAIT_IFG, 11)
                  prev = _from
                  ev = event
                  _mac_start_ifg_timer!(ctx, m)
                  _fired = true
                else
                  if _is_event && event == T_JAM_TIMER
                    fsm_goto!(m.fsm_mac, MAC_S_BACKOFF, 12)
                    prev = _from
                    ev = event
                    _mac_start_backoff_timer!(ctx, m)
                    _fired = true
                  
                  end
                end
              end
            else
              if fsm_state(m.fsm_mac) == MAC_S_BACKOFF
                if _is_event && event == T_BACKOFF_TIMER && m.carrier_sense
                  fsm_goto!(m.fsm_mac, MAC_S_RECEIVING, 13)
                  _fired = true
                else
                  if _is_event && event == T_BACKOFF_TIMER
                    fsm_goto!(m.fsm_mac, MAC_S_WAIT_IFG, 14)
                    prev = _from
                    ev = event
                    _mac_start_ifg_timer!(ctx, m)
                    _fired = true
                  
                  end
                end
              else
                if fsm_state(m.fsm_mac) == MAC_S_RECEIVING
                  if _is_event && event == E_CARRIER_SENSE_END
                    fsm_goto!(m.fsm_mac, MAC_S_WAIT_IFG, 15)
                    prev = _from
                    ev = event
                    _mac_start_ifg_timer!(ctx, m)
                    _fired = true
                  
                  end
                
                end
              end
            end
          end
        end
      end
      if !_fired
        break
      
      end
      _consumed = true
      _is_event = false
      _steps = _steps + 1
      if _steps > FSM_CASCADE_LIMIT
        fsm_cascade_error(m.fsm_mac)
      
      end
    end
    fsm_leave!(m.fsm_mac)
    fsm_drain!(m.fsm_mac)
    return nothing
  end
  function expire_tx_timer!(ctx, m::MacState)
    mac_dispatch!(ctx, m, T_TX_TIMER, nothing)
    return nothing
  end
  function expire_ifg_timer!(ctx, m::MacState)
    mac_dispatch!(ctx, m, T_IFG_TIMER, nothing)
    return nothing
  end
  function expire_jam_timer!(ctx, m::MacState)
    mac_dispatch!(ctx, m, T_JAM_TIMER, nothing)
    return nothing
  end
  function expire_backoff_timer!(ctx, m::MacState)
    mac_dispatch!(ctx, m, T_BACKOFF_TIMER, nothing)
    return nothing
  end
  const MAX_ATTEMPTS = 16
  const BACKOFF_RANGE_LIMIT = 10
  const SLOT_BIT_LENGTH_10MB = 512
  function _mac_emit!(mac::MacState, ctx, name::Symbol, value::Real)
    mac.recorder === nothing && return
    idx = get(mac.stat_handles, name, 0)
    idx > 0 || return
    emit_indexed_vector!(mac.recorder, idx, ctx, Float64(value))
  end
  function _mac_on_transition(mac::MacState, from, to)
    from == to && return nothing
    _mac_emit_state!(mac, to)
    nothing
  end
  function _mac_emit_state!(mac::MacState, state)
    mac.recorder === nothing && return
    idx = get(mac.stat_handles, :state, 0)
    idx > 0 || return
    emit_indexed_vector!(mac.recorder, idx, _mac_ctx[], Float64(UInt8(state)))
  end
  const _mac_ctx = Ref{Any}(nothing)
  function _mac_start_frame_transmission!(ctx, m::MacState)
    m.num_retries = 0
    pk = m.current_tx_frame::Packet
    frame_bits = data_length(pk).bits
    tx_bits = +(frame_bits, ETHERNET_PHY_HEADER_LEN_BYTES * 8, m.phy_esd_length_bits)
    schedule_timer!(ctx, to_simtime(tx_bits / m.bitrate), m.module_id, m.tx_timer, (ctx2) -> _mac_expire_tx_timer!(ctx2, m))
    fsm_defer!(m.fsm_mac, () -> m.downlink.start_frame_tx(ctx, pk, ESD_ESD))
  end
  function _mac_start_ifg_timer!(ctx, m::MacState)
    schedule_timer!(ctx, to_simtime(INTERFRAME_GAP_BITS / m.bitrate), m.module_id, m.ifg_timer, (ctx2) -> _mac_expire_ifg_timer!(ctx2, m))
  end
  function _mac_start_jam_timer!(ctx, m::MacState)
    schedule_timer!(ctx, to_simtime(JAM_SIGNAL_BYTES * 8 / m.bitrate), m.module_id, m.jam_timer, (ctx2) -> _mac_expire_jam_timer!(ctx2, m))
  end
  function _mac_start_backoff_timer!(ctx, m::MacState)
    slot_max = <<(1, min(m.num_retries, BACKOFF_RANGE_LIMIT))
    slot = rand(m.rng, 0:slot_max - 1)
    schedule_timer!(ctx, to_simtime(slot * SLOT_BIT_LENGTH_10MB / m.bitrate), m.module_id, m.backoff_timer, (ctx2) -> _mac_expire_backoff_timer!(ctx2, m))
  end
  function _mac_abort_transmission!(ctx, m::MacState)
    cancel!(m.tx_timer)
    fsm_defer!(m.fsm_mac, () -> m.downlink.end_frame_tx(ctx))
    fsm_defer!(m.fsm_mac, () -> m.downlink.start_signal_tx(ctx, SIG_JAM))
  end
  function _mac_finish_transmission!(ctx, m::MacState)
    fsm_defer!(m.fsm_mac, () -> m.downlink.end_frame_tx(ctx))
    m.current_tx_frame = nothing
    m.num_frames_sent = m.num_frames_sent + 1
    _mac_emit!(m, ctx, :numFramesSent, m.num_frames_sent)
    fsm_defer!(m.fsm_mac, () -> m.upcalls.frame_sent(ctx, m))
  end
  function _mac_expire_tx_timer!(ctx, m::MacState)
    _mac_ctx[] = ctx
    mac_dispatch!(ctx, m, T_TX_TIMER, nothing)
  end
  function _mac_expire_ifg_timer!(ctx, m::MacState)
    _mac_ctx[] = ctx
    mac_dispatch!(ctx, m, T_IFG_TIMER, nothing)
  end
  function _mac_expire_jam_timer!(ctx, m::MacState)
    _mac_ctx[] = ctx
    m.downlink.end_signal_tx(ctx)
    m.num_retries = m.num_retries + 1
    mac_dispatch!(ctx, m, T_JAM_TIMER, nothing)
  end
  function _mac_expire_backoff_timer!(ctx, m::MacState)
    _mac_ctx[] = ctx
    mac_dispatch!(ctx, m, T_BACKOFF_TIMER, nothing)
  end
  function mac_handle_carrier_sense_start!(ctx, mac::MacState)
    _mac_ctx[] = ctx
    mac.carrier_sense = true
    _mac_emit!(mac, ctx, :carrierSense, 1)
    mac_dispatch!(ctx, mac, E_CARRIER_SENSE_START, nothing)
  end
  function mac_handle_carrier_sense_end!(ctx, mac::MacState)
    _mac_ctx[] = ctx
    mac.carrier_sense = false
    _mac_emit!(mac, ctx, :carrierSense, 0)
    mac_dispatch!(ctx, mac, E_CARRIER_SENSE_END, nothing)
  end
  function mac_handle_collision_start!(ctx, mac::MacState)
    _mac_ctx[] = ctx
    mac.collision = true
    _mac_emit!(mac, ctx, :collision, 1)
    mac_dispatch!(ctx, mac, E_COLLISION_START, nothing)
  end
  function mac_handle_collision_end!(ctx, mac::MacState)
    mac.collision = false
    _mac_emit!(mac, ctx, :collision, 0)
    nothing
  end
  function mac_handle_reception_end!(ctx, mac::MacState, kind::EthernetSignalKind, packet::Union{Nothing, Packet})
    kind === SIG_DATA || return
    packet === nothing && return
    _mac_process_received_frame!(ctx, mac, packet)
  end
  function _mac_process_received_frame!(ctx, mac::MacState, packet::Packet)
    hdr = peek(packet, EthernetMacHeader)
    dst = hdr.destination.value
    is_broadcast = dst == 281474976710655
    if mac.promiscuous || dst == mac.address || is_broadcast
      mac.num_frames_received = mac.num_frames_received + 1
      _mac_emit!(mac, ctx, :numFramesReceived, mac.num_frames_received)
      mac.upcalls.frame_received(ctx, mac, packet)
    end
  end
  function mac_upper_packet!(ctx, mac::MacState, packet::Packet)
    _mac_ctx[] = ctx
    push!(mac.queue, packet)
    mac_dispatch!(ctx, mac, E_UPPER_PACKET, nothing)
  end

