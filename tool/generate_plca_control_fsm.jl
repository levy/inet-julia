# ============================================================================
# The PLCA state machines — control and data — as ONE `fsm` document, and the
# generator that turns them into `package/linklayer/main/t1s/PlcaFsm.jl`.
#
#     julia --project=tool tool/generate_plca_control_fsm.jl
#
# This is the machine the MAC's was not: **every transition is condition-only**.
# IEEE 802.3cg §148.4.4.6 has no event dimension at all — the machine is re-run
# whenever something it reads might have changed, and each run cascades through
# as many transitions as are enabled until it settles. Timers are not triggers
# either: they are *polled* in guards through `is_scheduled`, because a timer
# expiring is only half a condition (`!is_scheduled(to_timer) && !crs`).
#
# The two machines are declared in ONE component, which is what lets them share
# `PlcaState` directly: `fsm_control` and `fsm_data` are both fields of it, and
# so are the variables they pass between them (`packet_pending`, `tx_en`,
# `carrier_status`, `signal_status`). That replaces a real hack — the
# hand-written data FSM kept its state in a module-level `IdDict` keyed by
# `PlcaState`, because the hand-written struct had no slot for it.
#
# They inject events into each other, and every such call is deferred. The
# control machine's `CS_COMMIT` entry fires `COMMIT_TO` into the data machine;
# the data machine's entries re-run the control machine. Calling straight
# through would re-enter a cascade already in flight, which is exactly why the
# C++ wraps each of these in `FSMA_Delay_Action`.
#
# Faithfulness notes:
#
#   * `handle_with_control_fsm!` keeps the port's re-entrancy guard (`in_fsm`),
#     which returns *silently*. A PHY callback firing during an entry action's
#     `start_signal_tx` therefore never reaches the machine, and the outer
#     cascade re-evaluates with the updated variables. Because that guard is
#     outside the machine, the downlink calls stay synchronous — unlike the MAC,
#     which had no such guard and needed its outgoing calls deferred.
#   * The state statistic is emitted on every transition, with no
#     same-state suppression: `_enter_control!` had none either.
# ============================================================================

using Projectured

j(source) = juliaparse(source)

function plca_component()
    # No events: this machine is driven by re-evaluation alone.
    #
    # No timer *triggers* either. All nine timers are declared because they are
    # fields of the shared struct, and the control machine's guards poll five of
    # them with `is_scheduled`.
    timers = [FsmTimer(name) for name in
              ("beacon_timer", "beacon_det_timer", "to_timer", "syncing_timer",
               "burst_timer", "hold_timer", "pending_timer", "commit_timer", "tx_timer")]
    by_name = Dict(t.name => t for t in timers)

    # ── states ───────────────────────────────────────────────────────────
    # Declaration order fixes the recorded values (0-based), so it matches the
    # `PlcaControlState` enum this replaces.
    disable       = FsmState("DISABLE";       entry = j("_plca_enter_disable!(ctx, m)"))
    resync        = FsmState("RESYNC")
    recover       = FsmState("RECOVER")
    send_beacon   = FsmState("SEND_BEACON";   entry = j("_plca_enter_send_beacon!(ctx, m)"))
    syncing       = FsmState("SYNCING";       entry = j("_plca_enter_syncing!(ctx, m)"))
    wait_to       = FsmState("WAIT_TO";       entry = j("_plca_enter_wait_to!(ctx, m)"))
    early_receive = FsmState("EARLY_RECEIVE"; entry = j("_plca_enter_early_receive!(ctx, m)"))
    commit        = FsmState("COMMIT";        entry = j("_plca_enter_commit!(ctx, m)"))
    yield_        = FsmState("YIELD";         entry = j("_plca_enter_yield!(ctx, m)"))
    receive       = FsmState("RECEIVE")
    transmit      = FsmState("TRANSMIT";      entry = j("_plca_enter_transmit!(ctx, m)"))
    burst         = FsmState("BURST";         entry = j("_plca_enter_burst!(ctx, m)"))
    abort         = FsmState("ABORT";         entry = j("_plca_enter_abort!(ctx, m)"))
    next_to       = FsmState("NEXT_TX_OPPORTUNITY";
                             entry = j("_plca_enter_next_tx_opportunity!(ctx, m)"))

    states = [disable, resync, recover, send_beacon, syncing, wait_to, early_receive,
              commit, yield_, receive, transmit, burst, abort, next_to]

    tr(state; kwargs...) = push!(state.transitions, FsmTransition(; kwargs...))

    # DISABLE — leave immediately, by role.
    tr(disable, guard = j("_plca_is_coord(m)"), target = recover)
    tr(disable, target = resync)

    # RESYNC — a follower that hears carrier goes to early receive; the
    # coordinator with a quiet line sends the beacon.
    tr(resync, guard = j("!_plca_is_coord(m) && m.crs"), target = early_receive)
    tr(resync, guard = j("!m.crs && _plca_is_coord(m)"), target = send_beacon)

    # RECOVER — unconditional.
    tr(recover, target = wait_to)

    # SEND_BEACON — the beacon has been on the wire long enough.
    tr(send_beacon, guard = j("!is_scheduled(m.beacon_timer)"), target = syncing)

    # SYNCING — the line is quiet and the 1 ns spacer has passed. This is the
    # cycle boundary, so the cycle statistics are emitted and the token resets.
    tr(syncing, guard = j("!m.crs && !is_scheduled(m.syncing_timer)"),
                action = j("_plca_finish_cycle!(ctx, m)"),
                target = wait_to)

    # WAIT_TO — the four ways a transmit opportunity ends. Order is the
    # hand-written order, and first match wins.
    tr(wait_to, guard = j("m.crs"), target = early_receive)
    tr(wait_to, guard = j("m.cur_id == m.config.local_node_id && m.packet_pending && !m.crs"),
                target = commit)
    tr(wait_to, guard = j("!is_scheduled(m.to_timer) && m.cur_id != m.config.local_node_id && !m.crs"),
                target = next_to)
    tr(wait_to, guard = j("m.cur_id == m.config.local_node_id && !m.packet_pending && !m.crs"),
                target = yield_)

    # EARLY_RECEIVE — is this a beacon, a real reception, or noise?
    tr(early_receive, guard = j("!m.crs && _plca_is_coord(m)"), target = recover)
    tr(early_receive, guard = j("m.receiving && m.crs"), target = receive)
    tr(early_receive,
       guard = j("!_plca_is_coord(m) && !m.receiving && (m.rx_cmd === CMD_BEACON || (!m.crs && is_scheduled(m.beacon_det_timer)))"),
       target = syncing)
    tr(early_receive,
       guard = j("!_plca_is_coord(m) && !m.crs && m.rx_cmd !== CMD_BEACON && !is_scheduled(m.beacon_det_timer)"),
       target = resync)

    # YIELD — we had the token and nothing to send.
    tr(yield_, guard = j("m.crs && is_scheduled(m.to_timer)"), target = early_receive)
    tr(yield_, guard = j("!is_scheduled(m.to_timer)"), target = next_to)

    # RECEIVE — until the line goes quiet.
    tr(receive, guard = j("!m.crs"), target = next_to)

    # COMMIT — the MAC either starts transmitting or gives up.
    tr(commit, guard = j("m.tx_en"), target = transmit)
    tr(commit, guard = j("!m.tx_en && !m.packet_pending"), target = abort)

    # TRANSMIT — burst again, or hand the token on.
    tr(transmit, guard = j("!m.tx_en && !m.crs && m.bc >= m.config.max_bc"), target = next_to)
    tr(transmit, guard = j("!m.tx_en && m.bc < m.config.max_bc"), target = burst)

    # BURST — the next frame arrived in time, or it did not.
    tr(burst, guard = j("m.tx_en"), action = j("cancel!(m.burst_timer)"), target = transmit)
    tr(burst, guard = j("!m.tx_en && !is_scheduled(m.burst_timer)"), target = abort)

    # ABORT — wait for quiet.
    tr(abort, guard = j("!m.crs"), target = next_to)

    # NEXT_TX_OPPORTUNITY — the coordinator wraps the ring; everyone else takes
    # the next slot. Unconditional either way.
    tr(next_to, guard = j("_plca_is_coord(m) && m.cur_id >= m.config.plca_node_count"),
                target = resync)
    tr(next_to, target = wait_to)

    machine = FsmMachine("Control";
        initial = disable,
        states = states,
        # There are no events, so nothing can go unhandled: a settled machine
        # is the normal outcome of every run.
        on_unhandled = :ignore)

    data_events, data_machine = plca_data_machine(by_name)

    FsmComponent("Plca";
        variables = plca_variables(),
        timers = timers,
        events = data_events,
        machines = [machine, data_machine],
        helpers = vcat(plca_helpers(), plca_data_helpers()))
end

# The data machine: nine states, genuinely event-driven, sharing every variable
# with the control machine above. State order fixes the recorded values, so it
# matches INET's `DataState` enum (WAIT_IDLE = 0).
function plca_data_machine(timer)
    start_frame = FsmEvent("START_FRAME_TRANSMISSION")
    end_signal  = FsmEvent("END_SIGNAL_TRANSMISSION")
    commit_to   = FsmEvent("COMMIT_TO")
    rx_start    = FsmEvent("RECEPTION_START")
    rx_end      = FsmEvent("RECEPTION_END")
    events = [start_frame, end_signal, commit_to, rx_start, rx_end]

    wait_idle     = FsmState("WAIT_IDLE";     entry = j("_plca_enter_wait_idle!(ctx, m)"))
    idle          = FsmState("IDLE";          entry = j("_plca_enter_idle!(ctx, m)"))
    receive       = FsmState("RECEIVE";       entry = j("_plca_enter_receive!(ctx, m)"))
    hold          = FsmState("HOLD";          entry = j("_plca_enter_hold!(ctx, m)"))
    collide       = FsmState("COLLIDE";       entry = j("_plca_enter_collide!(ctx, m)"))
    delay_pending = FsmState("DELAY_PENDING"; entry = j("_plca_enter_delay_pending!(ctx, m)"))
    pending       = FsmState("PENDING";       entry = j("_plca_enter_pending!(ctx, m)"))
    wait_mac      = FsmState("WAIT_MAC";      entry = j("_plca_enter_wait_mac!(ctx, m)"))
    transmit      = FsmState("TRANSMIT";      entry = j("_plca_enter_transmit_data!(ctx, m)"))

    tr(state; kwargs...) = push!(state.transitions, FsmTransition(; kwargs...))

    # IDLE — a frame from the MAC is held until our transmit opportunity; a
    # peer's data puts us in receive.
    tr(idle, trigger = start_frame,
             action = j("_plca_accept_frame!(ctx, m, payload)"), target = hold)
    tr(idle, trigger = rx_start, guard = j("payload.kind === SIG_DATA"), target = receive)

    # WAIT_IDLE — the opportunity is still ours, so a frame goes straight out.
    tr(wait_idle, trigger = start_frame,
                  action = j("_plca_accept_frame!(ctx, m, payload)"), target = transmit)

    # RECEIVE — the MAC handing us a frame mid-reception is a collision.
    tr(receive, trigger = start_frame, action = j("m.current_tx = nothing"), target = collide)
    tr(receive, trigger = rx_end, target = idle)

    # HOLD — the token arrives, a peer starts talking, or we waited too long.
    tr(hold, trigger = commit_to, action = j("cancel!(m.hold_timer)"), target = transmit)
    tr(hold, trigger = rx_start, guard = j("payload.kind === SIG_DATA"),
             action = j("_plca_abandon_frame!(ctx, m)"), target = collide)
    tr(hold, trigger = timer["hold_timer"], action = j("m.current_tx = nothing"), target = collide)

    # COLLIDE — the MAC's jam finished.
    tr(collide, trigger = end_signal, target = delay_pending)

    # DELAY_PENDING / PENDING — back off, then wait for the token again.
    tr(delay_pending, trigger = timer["pending_timer"], target = pending)
    tr(pending, trigger = commit_to, target = wait_mac)

    # WAIT_MAC — the MAC retransmits, or it does not.
    # The arrival time is deliberately NOT reset here: the pending delay is
    # measured from the frame's original arrival, across recovery cycles.
    tr(wait_mac, trigger = start_frame, action = j("m.current_tx = payload"), target = transmit)
    tr(wait_mac, trigger = timer["commit_timer"], target = wait_idle)

    # TRANSMIT — until the frame is on the wire.
    tr(transmit, trigger = timer["tx_timer"],
                 action = j("_plca_finish_frame!(ctx, m)"), target = wait_idle)

    machine = FsmMachine("Data";
        initial = idle,
        states = [wait_idle, idle, receive, hold, collide, delay_pending,
                  pending, wait_mac, transmit],
        # The hand-written entry points silently ignored an event that did not
        # apply — except `plca_start_frame_transmission!`, which errored. That
        # one check lives in the handler, where it can name the state.
        on_unhandled = :ignore)

    (events, machine)
end

# Every field of the shared `PlcaState`, except `cs` — that is the machine.
# `ds` stays an ordinary variable: the hand-written data FSM owns it.
function plca_variables()
    v(name, type, default = nothing) =
        FsmVariable(name; type = j(type), default = default === nothing ? nothing : j(default))
    [
        v("module_id", "Int"),
        v("config", "PlcaConfig"),
        v("bitrate", "Float64", "10.0e6"),
        v("packet_pending", "Bool", "false"),
        v("tx_en", "Bool", "false"),
        v("carrier_status", "Bool", "false"),
        v("signal_status", "Bool", "false"),
        v("crs", "Bool", "false"),
        v("col", "Bool", "false"),
        v("receiving", "Bool", "false"),
        v("rx_cmd", "PlcaCmd", "CMD_NONE"),
        v("tx_cmd", "PlcaCmd", "CMD_NONE"),
        v("cur_id", "Int", "0"),
        v("bc", "Int", "0"),
        v("committed", "Bool", "false"),
        v("prev_carrier_sense", "Bool", "false"),
        v("prev_signal_error", "Bool", "false"),
        v("in_fsm", "Bool", "false"),
        v("upcalls", "PlcaControlUpcalls", "NO_PLCA_UPCALLS"),
        v("downlink", "PlcaDownlink", "NO_PLCA_DOWNLINK"),
        v("recorder", "Any", "nothing"),
        v("node_idx", "Int", "0"),
        v("stat_handles", "Dict{Symbol,Int}", "Dict{Symbol,Int}()"),
        v("cycle_start_time", "SimTime", "SimTime(0)"),
        v("to_start_time", "SimTime", "SimTime(0)"),
        v("packets_in_to", "Int", "0"),
        v("packets_in_cycle", "Int", "0"),
        v("packets_in_own_to", "Int", "0"),
        # What the hand-written data FSM kept in a module-level IdDict, because
        # its struct had no slot for them. Now they are just fields.
        v("current_tx", "Union{Nothing, Packet}", "nothing"),
        v("packet_arrival_time", "SimTime", "SimTime(0)"),
        v("last_tx_time", "SimTime", "SimTime(0)"),
    ]
end

# The code around the machine: the statistics emitters, the small setters that
# emit on change, and one function per entry action.
function plca_helpers()
    [
        j("_plca_is_coord(m::PlcaState) = m.config.local_node_id == 0"),
        j("_bits_to_time(m::PlcaState, bits) = to_simtime(bits / m.bitrate)"),

        # ── statistics ──────────────────────────────────────────────────
        j("""
          function _emit_time!(plca::PlcaState, ctx, name::Symbol, value::SimTime)
              plca.recorder === nothing && return
              idx = get(plca.stat_handles, name, 0)
              idx > 0 || return
              emit_indexed_vector!(plca.recorder, idx, ctx, seconds(value))
          end
          """),
        j("""
          function _emit_count!(plca::PlcaState, ctx, name::Symbol, value::Real)
              plca.recorder === nothing && return
              idx = get(plca.stat_handles, name, 0)
              idx > 0 || return
              emit_indexed_vector!(plca.recorder, idx, ctx, Float64(value))
          end
          """),
        # The transition hook, and the context it emits against. The hand-written
        # `_enter_control!` emitted on every transition with no same-state check,
        # so this does not add one.
        j("const _plca_ctx = Ref{Any}(nothing)"),
        j("""
          function _plca_on_transition(plca::PlcaState, to)
              _emit_count!(plca, _plca_ctx[], :controlState, UInt8(to))
              nothing
          end
          """),

        # ── setters that emit on change ─────────────────────────────────
        j("""
          function _set_tx_cmd!(plca::PlcaState, ctx, new::PlcaCmd)
              plca.tx_cmd === new && return
              plca.tx_cmd = new
              _emit_count!(plca, ctx, :txCmd, UInt8(new))
          end
          """),
        j("""
          function _set_cur_id!(plca::PlcaState, ctx, new::Int)
              plca.cur_id == new && return
              plca.cur_id = new
              _emit_count!(plca, ctx, :curID, new)
          end
          """),

        # ── the transition action shared by SYNCING ─────────────────────
        j("""
          function _plca_finish_cycle!(ctx, m::PlcaState)
              if m.cycle_start_time > zero(m.cycle_start_time)
                  _emit_time!(m, ctx, :cycleLength, SimTime(ctx.timestamp - m.cycle_start_time))
                  _emit_count!(m, ctx, :numPacketsPerCycle, m.packets_in_cycle)
              end
              m.cycle_start_time = ctx.timestamp
              m.packets_in_cycle = 0
              _set_cur_id!(m, ctx, 0)
          end
          """),

        # ── entry actions ───────────────────────────────────────────────
        j("""
          function _plca_enter_disable!(ctx, m::PlcaState)
              _set_tx_cmd!(m, ctx, CMD_NONE)
              m.committed = false
              _set_cur_id!(m, ctx, 0)
          end
          """),
        j("""
          function _plca_enter_send_beacon!(ctx, m::PlcaState)
              _set_tx_cmd!(m, ctx, CMD_BEACON)
              schedule_timer!(ctx, _bits_to_time(m, m.config.beacon_timer_length_bits),
                  m.module_id, m.beacon_timer,
                  (ctx2) -> handle_with_control_fsm!(ctx2, m))
              m.downlink.start_signal_tx(ctx, SIG_BEACON)
          end
          """),
        j("""
          function _plca_enter_syncing!(ctx, m::PlcaState)
              if m.tx_cmd === CMD_BEACON
                  _set_tx_cmd!(m, ctx, CMD_NONE)
                  m.downlink.end_signal_tx(ctx)
              end
              if _plca_is_coord(m)
                  schedule_timer!(ctx, SimTime(m.config.syncing_timer_hardcoded_ps),
                      m.module_id, m.syncing_timer,
                      (ctx2) -> handle_with_control_fsm!(ctx2, m))
              end
          end
          """),
        j("""
          function _plca_enter_wait_to!(ctx, m::PlcaState)
              schedule_timer!(ctx, _bits_to_time(m, m.config.to_timer_length_bits),
                  m.module_id, m.to_timer,
                  (ctx2) -> handle_with_control_fsm!(ctx2, m))
              m.to_start_time = ctx.timestamp
              m.packets_in_to = 0
          end
          """),
        j("""
          function _plca_enter_early_receive!(ctx, m::PlcaState)
              cancel!(m.to_timer)
              schedule_timer!(ctx, _bits_to_time(m, m.config.beacon_det_timer_length_bits),
                  m.module_id, m.beacon_det_timer,
                  (ctx2) -> handle_with_control_fsm!(ctx2, m))
          end
          """),
        j("""
          function _plca_enter_commit!(ctx, m::PlcaState)
              _set_tx_cmd!(m, ctx, CMD_COMMIT)
              m.downlink.start_signal_tx(ctx, SIG_COMMIT)
              m.committed = true
              cancel!(m.to_timer)
              m.bc = 0
              fsm_defer!(m.fsm_control, () -> m.upcalls.commit_to(ctx, m))
          end
          """),
        j("""
          function _plca_enter_yield!(ctx, m::PlcaState)
              _emit_count!(m, ctx, :transmitOpportunityUsed, 0)
          end
          """),
        j("""
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
          """),
        j("""
          function _plca_enter_burst!(ctx, m::PlcaState)
              m.bc = m.bc + 1
              _set_tx_cmd!(m, ctx, CMD_COMMIT)
              m.downlink.start_signal_tx(ctx, SIG_COMMIT)
              schedule_timer!(ctx, _bits_to_time(m, m.config.burst_timer_length_bits),
                  m.module_id, m.burst_timer,
                  (ctx2) -> handle_with_control_fsm!(ctx2, m))
          end
          """),
        j("""
          function _plca_enter_abort!(ctx, m::PlcaState)
              if m.tx_cmd !== CMD_NONE
                  m.downlink.end_signal_tx(ctx)
                  _set_tx_cmd!(m, ctx, CMD_NONE)
              end
          end
          """),
        j("""
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
          """),

        # ── the driver ──────────────────────────────────────────────────
        # The re-entrancy guard lives HERE, outside the machine, and returns
        # silently: a PHY callback firing during an entry action's
        # `start_signal_tx` never reaches the machine, and the cascade already
        # in flight re-evaluates with the updated variables. That is why the
        # downlink calls above can stay synchronous.
        #
        # Edge detection runs after the machine settles: only a *change* in the
        # derived carrier/signal status is reported upward to the MAC.
        j("""
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
          """),
    ]
end

# The data machine's own code: the entry actions, the small shared actions, and
# the handler layer that turns a MAC or PHY call into a dispatch.
#
# Every entry re-runs the control machine, synchronously — the control
# machine's own `in_fsm` guard makes that safe, and it is the order the port
# had. The deferral sits on the OTHER side, where the C++ puts it: the control
# machine's `CS_COMMIT` entry defers its injection into the data machine, so
# control is never re-entered from inside its own cascade. Each machine drains
# its own queue, which is what keeps one machine's pending injection out of the
# other's drain.
function plca_data_helpers()
    [
        j("_plca_run_control!(ctx, m::PlcaState) = handle_with_control_fsm!(ctx, m)"),

        # ── shared transition actions ───────────────────────────────────
        j("""
          function _plca_accept_frame!(ctx, m::PlcaState, packet)
              m.current_tx = packet
              m.packet_arrival_time = ctx.timestamp
          end
          """),
        j("""
          function _plca_abandon_frame!(ctx, m::PlcaState)
              cancel!(m.hold_timer)
              m.current_tx = nothing
          end
          """),
        j("""
          function _plca_finish_frame!(ctx, m::PlcaState)
              m.downlink.end_frame_tx(ctx)
              m.current_tx = nothing
          end
          """),

        # ── entry actions ───────────────────────────────────────────────
        j("""
          function _plca_enter_idle!(ctx, m::PlcaState)
              m.packet_pending = false
              m.carrier_status = false
              m.signal_status = false
              m.tx_en = false
              _plca_run_control!(ctx, m)
          end
          """),
        j("""
          function _plca_enter_wait_idle!(ctx, m::PlcaState)
              m.packet_pending = false
              m.carrier_status = false
              m.signal_status = false
              m.tx_en = false
              _plca_run_control!(ctx, m)
          end
          """),
        j("""
          function _plca_enter_hold!(ctx, m::PlcaState)
              m.packet_pending = true
              m.carrier_status = true
              hold_bits = 4 * m.config.delay_line_length
              schedule_timer!(ctx, _bits_to_time(m, hold_bits), m.module_id, m.hold_timer,
                  (ctx2) -> data_dispatch!(ctx2, m, T_HOLD_TIMER, nothing))
              _plca_run_control!(ctx, m)
          end
          """),
        j("""
          function _plca_enter_receive!(ctx, m::PlcaState)
              m.carrier_status = m.crs && m.rx_cmd !== CMD_COMMIT
              _plca_run_control!(ctx, m)
          end
          """),
        j("""
          function _plca_enter_collide!(ctx, m::PlcaState)
              m.packet_pending = false
              m.carrier_status = true
              m.signal_status = true
              _plca_run_control!(ctx, m)
          end
          """),
        j("""
          function _plca_enter_delay_pending!(ctx, m::PlcaState)
              m.signal_status = false
              schedule_timer!(ctx, _bits_to_time(m, m.config.pending_timer_length_bits),
                  m.module_id, m.pending_timer,
                  (ctx2) -> data_dispatch!(ctx2, m, T_PENDING_TIMER, nothing))
              _plca_run_control!(ctx, m)
          end
          """),
        j("""
          function _plca_enter_pending!(ctx, m::PlcaState)
              m.packet_pending = true
              _plca_run_control!(ctx, m)
          end
          """),
        j("""
          function _plca_enter_wait_mac!(ctx, m::PlcaState)
              m.carrier_status = false
              schedule_timer!(ctx, _bits_to_time(m, m.config.commit_timer_length_bits),
                  m.module_id, m.commit_timer,
                  (ctx2) -> data_dispatch!(ctx2, m, T_COMMIT_TIMER, nothing))
              _plca_run_control!(ctx, m)
          end
          """),
        j("""
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
              tx_bits = data_bits + ETHERNET_PHY_HEADER_LEN_BYTES * 8 + ETHERNET_PHY_ESD_LEN_BYTES * 8
              schedule_timer!(ctx, to_simtime(tx_bits / m.bitrate), m.module_id, m.tx_timer,
                  (ctx2) -> data_dispatch!(ctx2, m, T_TX_TIMER, nothing))
              esd = _plca_esd(m)
              m.downlink.start_frame_tx(ctx, pk, esd)
              _plca_run_control!(ctx, m)
          end
          """),
        j("_plca_esd(m::PlcaState) = m.bc < m.config.max_bc - 1 ? ESD_BRS : ESD_ESD"),

        # ── the transition hook ─────────────────────────────────────────
        j("""
          function _plca_on_data_transition(plca::PlcaState, to)
              _emit_count!(plca, _plca_ctx[], :dataState, UInt8(to))
              nothing
          end
          """),

        # ── the handler layer ───────────────────────────────────────────
        # A MAC or PHY call becomes a dispatch. The one state check the
        # hand-written code made loudly (a frame arriving where none can be
        # accepted) stays loud, and stays here where it can name the state.
        j("""
          function plca_start_frame_transmission!(ctx, plca::PlcaState, packet::Packet)
              _plca_ctx[] = ctx
              s = fsm_state(plca.fsm_data)
              if !(s == DATA_S_IDLE || s == DATA_S_WAIT_IDLE || s == DATA_S_RECEIVE || s == DATA_S_WAIT_MAC)
                  error("plca_start_frame_transmission!: unexpected ds=" * DATA_STATE_NAMES[s + 1])
              end
              data_dispatch!(ctx, plca, E_START_FRAME_TRANSMISSION, packet)
          end
          """),
        j("plca_end_frame_transmission!(ctx, plca::PlcaState) = nothing"),
        j("plca_start_signal_from_mac!(ctx, plca::PlcaState, kind) = nothing"),
        j("""
          function plca_end_signal_from_mac!(ctx, plca::PlcaState)
              _plca_ctx[] = ctx
              data_dispatch!(ctx, plca, E_END_SIGNAL_TRANSMISSION, nothing)
          end
          """),
        j("""
          function plca_commit_to!(ctx, plca::PlcaState)
              _plca_ctx[] = ctx
              data_dispatch!(ctx, plca, E_COMMIT_TO, nothing)
          end
          """),
        j("""
          function plca_data_on_reception_start!(ctx, plca::PlcaState, sig)
              _plca_ctx[] = ctx
              data_dispatch!(ctx, plca, E_RECEPTION_START, sig)
          end
          """),
        j("""
          function plca_data_on_reception_end!(ctx, plca::PlcaState, sig)
              _plca_ctx[] = ctx
              data_dispatch!(ctx, plca, E_RECEPTION_END, sig)
          end
          """),
    ]
end

const OUTPUT = joinpath(@__DIR__, "..", "package", "linklayer", "main", "t1s",
                        "PlcaFsm.jl")

function main()
    export_component(plca_component(), normpath(OUTPUT); wrap_module = false)
    println("wrote ", normpath(OUTPUT))
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
