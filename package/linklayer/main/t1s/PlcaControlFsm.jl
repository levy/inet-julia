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
  const T_BEACON_TIMER = Int32(1)
  const T_BEACON_DET_TIMER = Int32(2)
  const T_TO_TIMER = Int32(3)
  const T_SYNCING_TIMER = Int32(4)
  const T_BURST_TIMER = Int32(5)
  const T_HOLD_TIMER = Int32(6)
  const T_PENDING_TIMER = Int32(7)
  const T_COMMIT_TIMER = Int32(8)
  const T_TX_TIMER = Int32(9)
  mutable struct PlcaState

    fsm_control::Fsm
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
    ds::UInt8
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
  end
  PlcaState() = PlcaState(Fsm(Symbol("Control"), CONTROL_S_DISABLE), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), TimerHandle(), nothing, nothing, 1.0e7, 0, false, false, false, false, false, false, false, CMD_NONE, CMD_NONE, 0, 0, false, false, false, false, NO_PLCA_UPCALLS, NO_PLCA_DOWNLINK, nothing, 0, Dict{Symbol, Int}(), SimTime(0), SimTime(0), 0, 0, 0)
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
                        if !_plca_is_coord(m) && !m.receiving && m.rx_cmd === CMD_BEACON || !m.crs && is_scheduled(m.beacon_det_timer)
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
    return nothing
  end
  function expire_pending_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    return nothing
  end
  function expire_commit_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
    return nothing
  end
  function expire_tx_timer!(ctx, m::PlcaState)
    control_dispatch!(ctx, m, Int32(0), nothing)
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
    m.upcalls.commit_to(ctx, m)
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

