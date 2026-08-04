# Generated from the state machine `Plca` — edit the machine, not this file.


  const CONTROL_S_DISABLE = Int32(0)
  const CONTROL_S_RESYNC = Int32(1)
  const CONTROL_S_RECOVER = Int32(2)
  const CONTROL_S_SEND_BEACON = Int32(3)
  const CONTROL_S_SYNCING = Int32(4)
  const CONTROL_S_WAIT_TO = Int32(5)
  const CONTROL_S_EARLY_RECEIVE = Int32(6)
  const CONTROL_S_COMMIT = Int32(7)
  const CONTROL_S_YIELD = Int32(8)
  const CONTROL_S_RECEIVE = Int32(9)
  const CONTROL_S_TRANSMIT = Int32(10)
  const CONTROL_S_BURST = Int32(11)
  const CONTROL_S_ABORT = Int32(12)
  const CONTROL_S_NEXT_TX_OPPORTUNITY = Int32(13)
  const CONTROL_STATE_NAMES = ("DISABLE", "RESYNC", "RECOVER", "SEND_BEACON", "SYNCING", "WAIT_TO", "EARLY_RECEIVE", "COMMIT", "YIELD", "RECEIVE", "TRANSMIT", "BURST", "ABORT", "NEXT_TX_OPPORTUNITY")
  const DATA_S_WAIT_IDLE = Int32(0)
  const DATA_S_IDLE = Int32(1)
  const DATA_S_RECEIVE = Int32(2)
  const DATA_S_HOLD = Int32(3)
  const DATA_S_COLLIDE = Int32(4)
  const DATA_S_DELAY_PENDING = Int32(5)
  const DATA_S_PENDING = Int32(6)
  const DATA_S_WAIT_MAC = Int32(7)
  const DATA_S_TRANSMIT = Int32(8)
  const DATA_STATE_NAMES = ("WAIT_IDLE", "IDLE", "RECEIVE", "HOLD", "COLLIDE", "DELAY_PENDING", "PENDING", "WAIT_MAC", "TRANSMIT")
  const E_START_FRAME_TRANSMISSION = Int32(1)
  const E_END_SIGNAL_TRANSMISSION = Int32(2)
  const E_COMMIT_TO = Int32(3)
  const E_RECEPTION_START = Int32(4)
  const E_RECEPTION_END = Int32(5)
  const T_BEACON_TIMER = Int32(6)
  const T_BEACON_DET_TIMER = Int32(7)
  const T_TO_TIMER = Int32(8)
  const T_SYNCING_TIMER = Int32(9)
  const T_BURST_TIMER = Int32(10)
  const T_HOLD_TIMER = Int32(11)
  const T_PENDING_TIMER = Int32(12)
  const T_COMMIT_TIMER = Int32(13)
  const T_TX_TIMER = Int32(14)
  mutable struct PlcaState

    fsm_control::Fsm
    fsm_data::Fsm
    beacon_timer::TimerHandle
    beacon_det_timer::TimerHandle
    to_timer::TimerHandle
    syncing_timer::TimerHandle
    burst_timer::TimerHandle
    hold_timer::TimerHandle
    pending_timer::TimerHandle
    commit_timer::TimerHandle
    tx_timer::TimerHandle
    module_id::Int
    config::PlcaConfig
    bitrate::Float64
    packet_pending::Bool
    tx_en::Bool
    carrier_status::Bool
    signal_status::Bool
    crs::Bool
    col::Bool
    receiving::Bool
    rx_cmd::PlcaCmd
    tx_cmd::PlcaCmd
    cur_id::Int
    bc::Int
    committed::Bool
    prev_carrier_sense::Bool
    prev_signal_error::Bool
    in_fsm::Bool
    upcalls::PlcaControlUpcalls
    downlink::PlcaDownlink
    recorder::Any
    node_idx::Int
    stat_handles::Dict{Symbol, Int}
    cycle_start_time::SimTime
    to_start_time::SimTime
    packets_in_to::Int
    packets_in_cycle::Int
    packets_in_own_to::Int
    current_tx::Union{Nothing, Packet}
    packet_arrival_time::SimTime
    last_tx_time::SimTime
  end
  PlcaState() = PlcaState(Fsm(Symbol("Control"), CONTROL_S_DISABLE), Fsm(Symbol("Data"), DATA_S_IDLE), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), nothing, nothing, 1.0e7, false, false, false, false, false, false, false, CMD_NONE, CMD_NONE, 0, 0, false, false, false, false, NO_PLCA_UPCALLS, NO_PLCA_DOWNLINK, nothing, 0, Dict{Symbol, Int}(), SimTime(0), SimTime(0), 0, 0, 0, nothing, SimTime(0), SimTime(0))
  function control_dispatch!(ctx, m::PlcaState, event::Int32, payload)
    fsm_enter!(m.fsm_control)
    _is_event = event != Int32(0)
    _consumed = !_is_event
    _steps = 0
    while true
      _fired = false
      _from = fsm_state(m.fsm_control)
      if fsm_state(m.fsm_control) == CONTROL_S_DISABLE
        if _plca_is_coord(m)
          fsm_goto!(m.fsm_control, CONTROL_S_RECOVER, 1)
          _fired = true
        else
          if true
            fsm_goto!(m.fsm_control, CONTROL_S_RESYNC, 2)
            _fired = true
          
          end
        end
      else
        if fsm_state(m.fsm_control) == CONTROL_S_RESYNC
          if !_plca_is_coord(m) && m.crs
            fsm_goto!(m.fsm_control, CONTROL_S_EARLY_RECEIVE, 3)
            prev = _from
            ev = event
            _plca_enter_early_receive!(ctx, m)
            _fired = true
          else
            if !m.crs && _plca_is_coord(m)
              fsm_goto!(m.fsm_control, CONTROL_S_SEND_BEACON, 4)
              prev = _from
              ev = event
              _plca_enter_send_beacon!(ctx, m)
              _fired = true
            
            end
          end
        else
          if fsm_state(m.fsm_control) == CONTROL_S_RECOVER
            if true
              fsm_goto!(m.fsm_control, CONTROL_S_WAIT_TO, 5)
              prev = _from
              ev = event
              _plca_enter_wait_to!(ctx, m)
              _fired = true
            
            end
          else
            if fsm_state(m.fsm_control) == CONTROL_S_SEND_BEACON
              if !is_scheduled(m.beacon_timer)
                fsm_goto!(m.fsm_control, CONTROL_S_SYNCING, 6)
                prev = _from
                ev = event
                _plca_enter_syncing!(ctx, m)
                _fired = true
              
              end
            else
              if fsm_state(m.fsm_control) == CONTROL_S_SYNCING
                if !m.crs && !is_scheduled(m.syncing_timer)
                  _plca_finish_cycle!(ctx, m)
                  fsm_goto!(m.fsm_control, CONTROL_S_WAIT_TO, 7)
                  prev = _from
                  ev = event
                  _plca_enter_wait_to!(ctx, m)
                  _fired = true
                
                end
              else
                if fsm_state(m.fsm_control) == CONTROL_S_WAIT_TO
                  if m.crs
                    fsm_goto!(m.fsm_control, CONTROL_S_EARLY_RECEIVE, 8)
                    prev = _from
                    ev = event
                    _plca_enter_early_receive!(ctx, m)
                    _fired = true
                  else
                    if m.cur_id == m.config.local_node_id && m.packet_pending && !m.crs
                      fsm_goto!(m.fsm_control, CONTROL_S_COMMIT, 9)
                      prev = _from
                      ev = event
                      _plca_enter_commit!(ctx, m)
                      _fired = true
                    else
                      if !is_scheduled(m.to_timer) && m.cur_id != m.config.local_node_id && !m.crs
                        fsm_goto!(m.fsm_control, CONTROL_S_NEXT_TX_OPPORTUNITY, 10)
                        prev = _from
                        ev = event
                        _plca_enter_next_tx_opportunity!(ctx, m)
                        _fired = true
                      else
                        if m.cur_id == m.config.local_node_id && !m.packet_pending && !m.crs
                          fsm_goto!(m.fsm_control, CONTROL_S_YIELD, 11)
                          prev = _from
                          ev = event
                          _plca_enter_yield!(ctx, m)
                          _fired = true
                        
                        end
                      end
                    end
                  end
                else
                  if fsm_state(m.fsm_control) == CONTROL_S_EARLY_RECEIVE
                    if !m.crs && _plca_is_coord(m)
                      fsm_goto!(m.fsm_control, CONTROL_S_RECOVER, 12)
                      _fired = true
                    else
                      if m.receiving && m.crs
                        fsm_goto!(m.fsm_control, CONTROL_S_RECEIVE, 13)
                        _fired = true
                      else
                        if !_plca_is_coord(m) && !m.receiving && (m.rx_cmd === CMD_BEACON || !m.crs && is_scheduled(m.beacon_det_timer))
                          fsm_goto!(m.fsm_control, CONTROL_S_SYNCING, 14)
                          prev = _from
                          ev = event
                          _plca_enter_syncing!(ctx, m)
                          _fired = true
                        else
                          if !_plca_is_coord(m) && !m.crs && m.rx_cmd !== CMD_BEACON && !is_scheduled(m.beacon_det_timer)
                            fsm_goto!(m.fsm_control, CONTROL_S_RESYNC, 15)
                            _fired = true
                          
                          end
                        end
                      end
                    end
                  else
                    if fsm_state(m.fsm_control) == CONTROL_S_COMMIT
                      if m.tx_en
                        fsm_goto!(m.fsm_control, CONTROL_S_TRANSMIT, 16)
                        prev = _from
                        ev = event
                        _plca_enter_transmit!(ctx, m)
                        _fired = true
                      else
                        if !m.tx_en && !m.packet_pending
                          fsm_goto!(m.fsm_control, CONTROL_S_ABORT, 17)
                          prev = _from
                          ev = event
                          _plca_enter_abort!(ctx, m)
                          _fired = true
                        
                        end
                      end
                    else
                      if fsm_state(m.fsm_control) == CONTROL_S_YIELD
                        if m.crs && is_scheduled(m.to_timer)
                          fsm_goto!(m.fsm_control, CONTROL_S_EARLY_RECEIVE, 18)
                          prev = _from
                          ev = event
                          _plca_enter_early_receive!(ctx, m)
                          _fired = true
                        else
                          if !is_scheduled(m.to_timer)
                            fsm_goto!(m.fsm_control, CONTROL_S_NEXT_TX_OPPORTUNITY, 19)
                            prev = _from
                            ev = event
                            _plca_enter_next_tx_opportunity!(ctx, m)
                            _fired = true
                          
                          end
                        end
                      else
                        if fsm_state(m.fsm_control) == CONTROL_S_RECEIVE
                          if !m.crs
                            fsm_goto!(m.fsm_control, CONTROL_S_NEXT_TX_OPPORTUNITY, 20)
                            prev = _from
                            ev = event
                            _plca_enter_next_tx_opportunity!(ctx, m)
                            _fired = true
                          
                          end
                        else
                          if fsm_state(m.fsm_control) == CONTROL_S_TRANSMIT
                            if !m.tx_en && !m.crs && m.bc >= m.config.max_bc
                              fsm_goto!(m.fsm_control, CONTROL_S_NEXT_TX_OPPORTUNITY, 21)
                              prev = _from
                              ev = event
                              _plca_enter_next_tx_opportunity!(ctx, m)
                              _fired = true
                            else
                              if !m.tx_en && m.bc < m.config.max_bc
                                fsm_goto!(m.fsm_control, CONTROL_S_BURST, 22)
                                prev = _from
                                ev = event
                                _plca_enter_burst!(ctx, m)
                                _fired = true
                              
                              end
                            end
                          else
                            if fsm_state(m.fsm_control) == CONTROL_S_BURST
                              if m.tx_en
                                cancel!(m.burst_timer)
                                fsm_goto!(m.fsm_control, CONTROL_S_TRANSMIT, 23)
                                prev = _from
                                ev = event
                                _plca_enter_transmit!(ctx, m)
                                _fired = true
                              else
                                if !m.tx_en && !is_scheduled(m.burst_timer)
                                  fsm_goto!(m.fsm_control, CONTROL_S_ABORT, 24)
                                  prev = _from
                                  ev = event
                                  _plca_enter_abort!(ctx, m)
                                  _fired = true
                                
                                end
                              end
                            else
                              if fsm_state(m.fsm_control) == CONTROL_S_ABORT
                                if !m.crs
                                  fsm_goto!(m.fsm_control, CONTROL_S_NEXT_TX_OPPORTUNITY, 25)
                                  prev = _from
                                  ev = event
                                  _plca_enter_next_tx_opportunity!(ctx, m)
                                  _fired = true
                                
                                end
                              else
                                if fsm_state(m.fsm_control) == CONTROL_S_NEXT_TX_OPPORTUNITY
                                  if _plca_is_coord(m) && m.cur_id >= m.config.plca_node_count
                                    fsm_goto!(m.fsm_control, CONTROL_S_RESYNC, 26)
                                    _fired = true
                                  else
                                    if true
                                      fsm_goto!(m.fsm_control, CONTROL_S_WAIT_TO, 27)
                                      prev = _from
                                      ev = event
                                      _plca_enter_wait_to!(ctx, m)
                                      _fired = true
                                    
                                    end
                                  end
                                
                                end
                              end
                            end
                          end
                        end
                      end
                    end
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
        fsm_cascade_error(m.fsm_control)
      
      end
    end
    fsm_leave!(m.fsm_control)
    fsm_drain!(m.fsm_control)
    return nothing
  end
  function data_dispatch!(ctx, m::PlcaState, event::Int32, payload)
    fsm_enter!(m.fsm_data)
    _is_event = event != Int32(0)
    _consumed = !_is_event
    _steps = 0
    while true
      _fired = false
      _from = fsm_state(m.fsm_data)
      if fsm_state(m.fsm_data) == DATA_S_WAIT_IDLE
        if _is_event && event == E_START_FRAME_TRANSMISSION
          _plca_accept_frame!(ctx, m, payload)
          fsm_goto!(m.fsm_data, DATA_S_TRANSMIT, 1)
          prev = _from
          ev = event
          _plca_enter_transmit_data!(ctx, m)
          _fired = true
        
        end
      else
        if fsm_state(m.fsm_data) == DATA_S_IDLE
          if _is_event && event == E_START_FRAME_TRANSMISSION
            _plca_accept_frame!(ctx, m, payload)
            fsm_goto!(m.fsm_data, DATA_S_HOLD, 2)
            prev = _from
            ev = event
            _plca_enter_hold!(ctx, m)
            _fired = true
          else
            if _is_event && event == E_RECEPTION_START && payload.kind === SIG_DATA
              fsm_goto!(m.fsm_data, DATA_S_RECEIVE, 3)
              prev = _from
              ev = event
              _plca_enter_receive!(ctx, m)
              _fired = true
            
            end
          end
        else
          if fsm_state(m.fsm_data) == DATA_S_RECEIVE
            if _is_event && event == E_START_FRAME_TRANSMISSION
              m.current_tx = nothing
              fsm_goto!(m.fsm_data, DATA_S_COLLIDE, 4)
              prev = _from
              ev = event
              _plca_enter_collide!(ctx, m)
              _fired = true
            else
              if _is_event && event == E_RECEPTION_END
                fsm_goto!(m.fsm_data, DATA_S_IDLE, 5)
                prev = _from
                ev = event
                _plca_enter_idle!(ctx, m)
                _fired = true
              
              end
            end
          else
            if fsm_state(m.fsm_data) == DATA_S_HOLD
              if _is_event && event == E_COMMIT_TO
                cancel!(m.hold_timer)
                fsm_goto!(m.fsm_data, DATA_S_TRANSMIT, 6)
                prev = _from
                ev = event
                _plca_enter_transmit_data!(ctx, m)
                _fired = true
              else
                if _is_event && event == E_RECEPTION_START && payload.kind === SIG_DATA
                  _plca_abandon_frame!(ctx, m)
                  fsm_goto!(m.fsm_data, DATA_S_COLLIDE, 7)
                  prev = _from
                  ev = event
                  _plca_enter_collide!(ctx, m)
                  _fired = true
                else
                  if _is_event && event == T_HOLD_TIMER
                    m.current_tx = nothing
                    fsm_goto!(m.fsm_data, DATA_S_COLLIDE, 8)
                    prev = _from
                    ev = event
                    _plca_enter_collide!(ctx, m)
                    _fired = true
                  
                  end
                end
              end
            else
              if fsm_state(m.fsm_data) == DATA_S_COLLIDE
                if _is_event && event == E_END_SIGNAL_TRANSMISSION
                  fsm_goto!(m.fsm_data, DATA_S_DELAY_PENDING, 9)
                  prev = _from
                  ev = event
                  _plca_enter_delay_pending!(ctx, m)
                  _fired = true
                
                end
              else
                if fsm_state(m.fsm_data) == DATA_S_DELAY_PENDING
                  if _is_event && event == T_PENDING_TIMER
                    fsm_goto!(m.fsm_data, DATA_S_PENDING, 10)
                    prev = _from
                    ev = event
                    _plca_enter_pending!(ctx, m)
                    _fired = true
                  
                  end
                else
                  if fsm_state(m.fsm_data) == DATA_S_PENDING
                    if _is_event && event == E_COMMIT_TO
                      fsm_goto!(m.fsm_data, DATA_S_WAIT_MAC, 11)
                      prev = _from
                      ev = event
                      _plca_enter_wait_mac!(ctx, m)
                      _fired = true
                    
                    end
                  else
                    if fsm_state(m.fsm_data) == DATA_S_WAIT_MAC
                      if _is_event && event == E_START_FRAME_TRANSMISSION
                        m.current_tx = payload
                        fsm_goto!(m.fsm_data, DATA_S_TRANSMIT, 12)
                        prev = _from
                        ev = event
                        _plca_enter_transmit_data!(ctx, m)
                        _fired = true
                      else
                        if _is_event && event == T_COMMIT_TIMER
                          fsm_goto!(m.fsm_data, DATA_S_WAIT_IDLE, 13)
                          prev = _from
                          ev = event
                          _plca_enter_wait_idle!(ctx, m)
                          _fired = true
                        
                        end
                      end
                    else
                      if fsm_state(m.fsm_data) == DATA_S_TRANSMIT
                        if _is_event && event == T_TX_TIMER
                          _plca_finish_frame!(ctx, m)
                          fsm_goto!(m.fsm_data, DATA_S_WAIT_IDLE, 14)
                          prev = _from
                          ev = event
                          _plca_enter_wait_idle!(ctx, m)
                          _fired = true
                        
                        end
                      
                      end
                    end
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
        fsm_cascade_error(m.fsm_data)
      
      end
    end
    fsm_leave!(m.fsm_data)
    fsm_drain!(m.fsm_data)
    return nothing
  end
  function expire_beacon_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    return nothing
  end
  function expire_beacon_det_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    return nothing
  end
  function expire_to_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    return nothing
  end
  function expire_syncing_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    return nothing
  end
  function expire_burst_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    return nothing
  end
  function expire_hold_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    data_dispatch!(ctx, m, T_HOLD_TIMER, nothing)
    return nothing
  end
  function expire_pending_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    data_dispatch!(ctx, m, T_PENDING_TIMER, nothing)
    return nothing
  end
  function expire_commit_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    data_dispatch!(ctx, m, T_COMMIT_TIMER, nothing)
    return nothing
  end
  function expire_tx_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    data_dispatch!(ctx, m, T_TX_TIMER, nothing)
    return nothing
  end
  _plca_is_coord(m::PlcaState) = 
    m.config.local_node_id == 0
  
  _bits_to_time(m::PlcaState, bits) = 
    to_simtime(bits / m.bitrate)
  
  function _emit_time!(plca::PlcaState, ctx, name::Symbol, value::SimTime)
    plca.recorder === nothing && return
    idx = get(plca.stat_handles, name, 0)
    idx > 0 || return
    emit_indexed_vector!(plca.recorder, idx, ctx, seconds(value))
  end
  function _emit_count!(plca::PlcaState, ctx, name::Symbol, value::Real)
    plca.recorder === nothing && return
    idx = get(plca.stat_handles, name, 0)
    idx > 0 || return
    emit_indexed_vector!(plca.recorder, idx, ctx, Float64(value))
  end
  const _plca_ctx = Ref{Any}(nothing)
  function _plca_on_transition(plca::PlcaState, to)
    _emit_count!(plca, _plca_ctx[], :controlState, UInt8(to))
    nothing
  end
  function _set_tx_cmd!(plca::PlcaState, ctx, new::PlcaCmd)
    plca.tx_cmd === new && return
    plca.tx_cmd = new
    _emit_count!(plca, ctx, :txCmd, UInt8(new))
  end
  function _set_cur_id!(plca::PlcaState, ctx, new::Int)
    plca.cur_id == new && return
    plca.cur_id = new
    _emit_count!(plca, ctx, :curID, new)
  end
  function _plca_finish_cycle!(ctx, m::PlcaState)
    if m.cycle_start_time > zero(m.cycle_start_time)
      _emit_time!(m, ctx, :cycleLength, SimTime(ctx.timestamp - m.cycle_start_time))
      _emit_count!(m, ctx, :numPacketsPerCycle, m.packets_in_cycle)
    end
    m.cycle_start_time = ctx.timestamp
    m.packets_in_cycle = 0
    _set_cur_id!(m, ctx, 0)
  end
  function _plca_enter_disable!(ctx, m::PlcaState)
    _set_tx_cmd!(m, ctx, CMD_NONE)
    m.committed = false
    _set_cur_id!(m, ctx, 0)
  end
  function _plca_enter_send_beacon!(ctx, m::PlcaState)
    _set_tx_cmd!(m, ctx, CMD_BEACON)
    schedule_timer!(ctx, _bits_to_time(m, m.config.beacon_timer_length_bits), m.module_id, m.beacon_timer, (ctx2) -> handle_with_control_fsm!(ctx2, m))
    m.downlink.start_signal_tx(ctx, SIG_BEACON)
  end
  function _plca_enter_syncing!(ctx, m::PlcaState)
    if m.tx_cmd === CMD_BEACON
      _set_tx_cmd!(m, ctx, CMD_NONE)
      m.downlink.end_signal_tx(ctx)
    end
    if _plca_is_coord(m)
      schedule_timer!(ctx, SimTime(m.config.syncing_timer_hardcoded_ps), m.module_id, m.syncing_timer, (ctx2) -> handle_with_control_fsm!(ctx2, m))
    end
  end
  function _plca_enter_wait_to!(ctx, m::PlcaState)
    schedule_timer!(ctx, _bits_to_time(m, m.config.to_timer_length_bits), m.module_id, m.to_timer, (ctx2) -> handle_with_control_fsm!(ctx2, m))
    m.to_start_time = ctx.timestamp
    m.packets_in_to = 0
  end
  function _plca_enter_early_receive!(ctx, m::PlcaState)
    cancel!(m.to_timer)
    schedule_timer!(ctx, _bits_to_time(m, m.config.beacon_det_timer_length_bits), m.module_id, m.beacon_det_timer, (ctx2) -> handle_with_control_fsm!(ctx2, m))
  end
  function _plca_enter_commit!(ctx, m::PlcaState)
    _set_tx_cmd!(m, ctx, CMD_COMMIT)
    m.downlink.start_signal_tx(ctx, SIG_COMMIT)
    m.committed = true
    cancel!(m.to_timer)
    m.bc = 0
    fsm_defer!(m.fsm_control, () -> m.upcalls.commit_to(ctx, m))
  end
  function _plca_enter_yield!(ctx, m::PlcaState)
    _emit_count!(m, ctx, :transmitOpportunityUsed, 0)
  end
  function _plca_enter_transmit!(ctx, m::PlcaState)
    m.bc == 0 && _emit_count!(m, ctx, :transmitOpportunityUsed, 1)
    if m.tx_cmd !== CMD_NONE
      m.downlink.end_signal_tx(ctx)
      _set_tx_cmd!(m, ctx, CMD_NONE)
    end
    if m.bc >= m.config.max_bc
      m.committed = false
    end
  end
  function _plca_enter_burst!(ctx, m::PlcaState)
    m.bc = m.bc + 1
    _set_tx_cmd!(m, ctx, CMD_COMMIT)
    m.downlink.start_signal_tx(ctx, SIG_COMMIT)
    schedule_timer!(ctx, _bits_to_time(m, m.config.burst_timer_length_bits), m.module_id, m.burst_timer, (ctx2) -> handle_with_control_fsm!(ctx2, m))
  end
  function _plca_enter_abort!(ctx, m::PlcaState)
    if m.tx_cmd !== CMD_NONE
      m.downlink.end_signal_tx(ctx)
      _set_tx_cmd!(m, ctx, CMD_NONE)
    end
  end
  function _plca_enter_next_tx_opportunity!(ctx, m::PlcaState)
    to_dur = SimTime(ctx.timestamp - m.to_start_time)
    _emit_time!(m, ctx, :toLength, to_dur)
    _emit_count!(m, ctx, :numPacketsPerTo, m.packets_in_to)
    if m.cur_id == m.config.local_node_id
      _emit_time!(m, ctx, :ownToLength, to_dur)
      _emit_count!(m, ctx, :numPacketsPerOwnTo, m.packets_in_to)
    end
    _set_cur_id!(m, ctx, m.cur_id + 1)
    m.committed = false
  end
  function handle_with_control_fsm!(ctx, plca::PlcaState)
    plca.in_fsm && return nothing
    plca.in_fsm = true
    _plca_ctx[] = ctx
    try
      control_dispatch!(ctx, plca, Int32(0), nothing)
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
  _plca_run_control!(ctx, m::PlcaState) = 
    handle_with_control_fsm!(ctx, m)
  
  function _plca_accept_frame!(ctx, m::PlcaState, packet)
    m.current_tx = packet
    m.packet_arrival_time = ctx.timestamp
  end
  function _plca_abandon_frame!(ctx, m::PlcaState)
    cancel!(m.hold_timer)
    m.current_tx = nothing
  end
  function _plca_finish_frame!(ctx, m::PlcaState)
    m.downlink.end_frame_tx(ctx)
    m.current_tx = nothing
  end
  function _plca_enter_idle!(ctx, m::PlcaState)
    m.packet_pending = false
    m.carrier_status = false
    m.signal_status = false
    m.tx_en = false
    _plca_run_control!(ctx, m)
  end
  function _plca_enter_wait_idle!(ctx, m::PlcaState)
    m.packet_pending = false
    m.carrier_status = false
    m.signal_status = false
    m.tx_en = false
    _plca_run_control!(ctx, m)
  end
  function _plca_enter_hold!(ctx, m::PlcaState)
    m.packet_pending = true
    m.carrier_status = true
    hold_bits = 4 * m.config.delay_line_length
    schedule_timer!(ctx, _bits_to_time(m, hold_bits), m.module_id, m.hold_timer, (ctx2) -> data_dispatch!(ctx2, m, T_HOLD_TIMER, nothing))
    _plca_run_control!(ctx, m)
  end
  function _plca_enter_receive!(ctx, m::PlcaState)
    m.carrier_status = m.crs && m.rx_cmd !== CMD_COMMIT
    _plca_run_control!(ctx, m)
  end
  function _plca_enter_collide!(ctx, m::PlcaState)
    m.packet_pending = false
    m.carrier_status = true
    m.signal_status = true
    _plca_run_control!(ctx, m)
  end
  function _plca_enter_delay_pending!(ctx, m::PlcaState)
    m.signal_status = false
    schedule_timer!(ctx, _bits_to_time(m, m.config.pending_timer_length_bits), m.module_id, m.pending_timer, (ctx2) -> data_dispatch!(ctx2, m, T_PENDING_TIMER, nothing))
    _plca_run_control!(ctx, m)
  end
  function _plca_enter_pending!(ctx, m::PlcaState)
    m.packet_pending = true
    _plca_run_control!(ctx, m)
  end
  function _plca_enter_wait_mac!(ctx, m::PlcaState)
    m.carrier_status = false
    schedule_timer!(ctx, _bits_to_time(m, m.config.commit_timer_length_bits), m.module_id, m.commit_timer, (ctx2) -> data_dispatch!(ctx2, m, T_COMMIT_TIMER, nothing))
    _plca_run_control!(ctx, m)
  end
  function _plca_enter_transmit_data!(ctx, m::PlcaState)
    m.packet_pending = false
    m.carrier_status = true
    m.signal_status = false
    m.tx_en = true
    if m.tx_cmd === CMD_COMMIT
      m.downlink.end_signal_tx(ctx)
      _set_tx_cmd!(m, ctx, CMD_NONE)
    end
    _emit_time!(m, ctx, :packetPendingDelay, SimTime(ctx.timestamp - m.packet_arrival_time))
    if m.last_tx_time > zero(m.last_tx_time)
      _emit_time!(m, ctx, :packetInterval, SimTime(ctx.timestamp - m.last_tx_time))
    end
    m.last_tx_time = ctx.timestamp
    m.packets_in_to = m.packets_in_to + 1
    m.packets_in_cycle = m.packets_in_cycle + 1
    pk = m.current_tx::Packet
    data_bits = data_length(pk).bits
    tx_bits = +(data_bits, ETHERNET_PHY_HEADER_LEN_BYTES * 8, ETHERNET_PHY_ESD_LEN_BYTES * 8)
    schedule_timer!(ctx, to_simtime(tx_bits / m.bitrate), m.module_id, m.tx_timer, (ctx2) -> data_dispatch!(ctx2, m, T_TX_TIMER, nothing))
    esd = _plca_esd(m)
    m.downlink.start_frame_tx(ctx, pk, esd)
    _plca_run_control!(ctx, m)
  end
  _plca_esd(m::PlcaState) = 
    m.bc < m.config.max_bc - 1 ? ESD_BRS : ESD_ESD
  
  function _plca_on_data_transition(plca::PlcaState, to)
    _emit_count!(plca, _plca_ctx[], :dataState, UInt8(to))
    nothing
  end
  function plca_start_frame_transmission!(ctx, plca::PlcaState, packet::Packet)
    _plca_ctx[] = ctx
    s = fsm_state(plca.fsm_data)
    if !(s == DATA_S_IDLE || s == DATA_S_WAIT_IDLE || s == DATA_S_RECEIVE || s == DATA_S_WAIT_MAC)
      error("plca_start_frame_transmission!: unexpected ds=" * DATA_STATE_NAMES[s + 1])
    end
    data_dispatch!(ctx, plca, E_START_FRAME_TRANSMISSION, packet)
  end
  plca_end_frame_transmission!(ctx, plca::PlcaState) = 
    nothing
  
  plca_start_signal_from_mac!(ctx, plca::PlcaState, kind) = 
    nothing
  
  function plca_end_signal_from_mac!(ctx, plca::PlcaState)
    _plca_ctx[] = ctx
    data_dispatch!(ctx, plca, E_END_SIGNAL_TRANSMISSION, nothing)
  end
  function plca_commit_to!(ctx, plca::PlcaState)
    _plca_ctx[] = ctx
    data_dispatch!(ctx, plca, E_COMMIT_TO, nothing)
  end
  function plca_data_on_reception_start!(ctx, plca::PlcaState, sig)
    _plca_ctx[] = ctx
    data_dispatch!(ctx, plca, E_RECEPTION_START, sig)
  end
  function plca_data_on_reception_end!(ctx, plca::PlcaState, sig)
    _plca_ctx[] = ctx
    data_dispatch!(ctx, plca, E_RECEPTION_END, sig)
  end

