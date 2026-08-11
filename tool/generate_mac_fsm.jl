# ============================================================================
# The EthernetCsmaMac state machine, as an `fsm` document, and the generator
# that turns it into `package/linklayer/main/t1s/MacFsm.jl`.
#
# This is the source of the MAC's transition logic. `MacFsm.jl` is output —
# regenerate it with:
#
#     julia --project=tool tool/generate_mac_fsm.jl
#
# Run from the repository root. The environment needs `Projectured` (the state
# machine domain lives there); the link-layer package itself does not, which is
# why this is a tool rather than part of the package.
#
# Faithfulness notes, where the machine's shape differs from a naive reading of
# the hand-written `Mac.jl` it replaces:
#
#   * Variables that every event updates regardless of state (`carrier_sense`,
#     `collision`) are NOT modelled as transitions in every state. They are
#     updated by the handler that receives the event, which then dispatches —
#     exactly what the C++ `handleCarrierSenseStart()` does before calling
#     `handleWithFsm`. That handler layer is the component's `helpers`.
#   * `_mac_end_jam!` increments `num_retries` and then branches on the *new*
#     value. A guard must not have side effects, so the increment happens in
#     the timer's own callback before it dispatches — the same seam.
#   * `on_unhandled = :ignore` matches the hand-written port, whose timer
#     callbacks silently `return` when the state has moved on. The C++ is
#     exhaustiveness-checked; the Julia port is not, and this pilot reproduces
#     the port.
# ============================================================================

using Projectured

j(source) = juliaparse(source)

function ethernet_csma_mac_component()
    # ── events ───────────────────────────────────────────────────────────
    carrier_start = FsmEvent("CARRIER_SENSE_START")
    carrier_end   = FsmEvent("CARRIER_SENSE_END")
    collision     = FsmEvent("COLLISION_START")
    upper_packet  = FsmEvent("UPPER_PACKET")

    # ── timers ───────────────────────────────────────────────────────────
    tx_timer      = FsmTimer("tx_timer")
    ifg_timer     = FsmTimer("ifg_timer")
    jam_timer     = FsmTimer("jam_timer")
    backoff_timer = FsmTimer("backoff_timer")

    # ── states ───────────────────────────────────────────────────────────
    # Declaration order fixes the recorded state values (0-based), so it must
    # match the `MacFsmState` enum this replaces — those numbers appear in the
    # .vec output and in the network hash.
    idle         = FsmState("IDLE")
    wait_ifg     = FsmState("WAIT_IFG";
        entry = j("_mac_start_ifg_timer!(ctx, m)"))
    transmitting = FsmState("TRANSMITTING";
        entry = j("_mac_start_frame_transmission!(ctx, m)"))
    jamming      = FsmState("JAMMING";
        entry = j("_mac_start_jam_timer!(ctx, m)"))
    backoff      = FsmState("BACKOFF";
        entry = j("_mac_start_backoff_timer!(ctx, m)"))
    receiving    = FsmState("RECEIVING")

    tr(state; kwargs...) = push!(state.transitions, FsmTransition(; kwargs...))

    # IDLE — carrier means someone else is talking; a packet from above goes
    # out straight away.
    tr(idle, trigger = carrier_start, target = receiving)
    tr(idle, trigger = upper_packet,
             guard  = j("m.current_tx_frame === nothing && !isempty(m.queue)"),
             action = j("m.current_tx_frame = popfirst!(m.queue)"),
             target = transmitting)

    # WAIT_IFG — the inter-frame gap has passed; take the next thing there is
    # to do, in the hand-written order.
    tr(wait_ifg, trigger = ifg_timer,
                 guard  = j("m.current_tx_frame !== nothing"),
                 target = transmitting)
    tr(wait_ifg, trigger = ifg_timer,
                 guard  = j("!isempty(m.queue)"),
                 action = j("m.current_tx_frame = popfirst!(m.queue)"),
                 target = transmitting)
    tr(wait_ifg, trigger = ifg_timer, guard = j("m.carrier_sense"), target = receiving)
    tr(wait_ifg, trigger = ifg_timer, target = idle)

    # TRANSMITTING — a collision aborts into the jam signal; otherwise the
    # frame finishes and the gap begins.
    tr(transmitting, trigger = collision,
                     action = j("_mac_abort_transmission!(ctx, m)"),
                     target = jamming)
    tr(transmitting, trigger = tx_timer,
                     guard  = j("m.carrier_sense"),
                     action = j("_mac_finish_transmission!(ctx, m)"),
                     target = receiving)
    tr(transmitting, trigger = tx_timer,
                     action = j("_mac_finish_transmission!(ctx, m)"),
                     target = wait_ifg)

    # JAMMING — the jam signal is over. `num_retries` has already been bumped
    # by the timer callback, so these guards only read it.
    tr(jamming, trigger = jam_timer,
                guard  = j("m.num_retries >= MAX_ATTEMPTS && m.carrier_sense"),
                action = j("m.current_tx_frame = nothing"),
                target = receiving)
    tr(jamming, trigger = jam_timer,
                guard  = j("m.num_retries >= MAX_ATTEMPTS"),
                action = j("m.current_tx_frame = nothing"),
                target = wait_ifg)
    tr(jamming, trigger = jam_timer, target = backoff)

    # BACKOFF — the slot has passed.
    tr(backoff, trigger = backoff_timer, guard = j("m.carrier_sense"), target = receiving)
    tr(backoff, trigger = backoff_timer, target = wait_ifg)

    # RECEIVING — the line went quiet.
    tr(receiving, trigger = carrier_end, target = wait_ifg)

    machine = FsmMachine("Mac";
        initial = idle,
        states = [idle, wait_ifg, transmitting, jamming, backoff, receiving],
        # The hand-written port's timer callbacks return silently when the
        # state has moved on, and a carrier event outside IDLE/RECEIVING
        # simply does not transition. That is `:ignore`, not the C++'s
        # exhaustiveness check.
        on_unhandled = :ignore)

    variables = [
        FsmVariable("module_id"; type = j("Int")),
        FsmVariable("current_tx_frame"; type = j("Union{Nothing, Packet}"), default = j("nothing")),
        FsmVariable("queue"; type = j("Vector{Packet}"), default = j("Packet[]")),
        FsmVariable("num_retries"; type = j("Int"), default = j("0")),
        FsmVariable("carrier_sense"; type = j("Bool"), default = j("false")),
        FsmVariable("collision"; type = j("Bool"), default = j("false")),
        FsmVariable("rng"; type = j("MersenneTwister"), default = j("MersenneTwister(0)")),
        FsmVariable("bitrate"; type = j("Float64"), default = j("10.0e6")),
        FsmVariable("address"; type = j("UInt64"), default = j("0")),
        FsmVariable("promiscuous"; type = j("Bool"), default = j("false")),
        FsmVariable("downlink"; type = j("MacDownlink"), default = j("NO_MAC_DOWNLINK")),
        FsmVariable("upcalls"; type = j("MacUpcalls"), default = j("NO_MAC_UPCALLS")),
        FsmVariable("phy_esd_length_bits"; type = j("Int"),
                    default = j("ETHERNET_PHY_ESD_LEN_BYTES * 8")),
        FsmVariable("recorder"; type = j("Any"), default = j("nothing")),
        FsmVariable("node_idx"; type = j("Int"), default = j("0")),
        FsmVariable("stat_handles"; type = j("Dict{Symbol,Int}"), default = j("Dict{Symbol,Int}()")),
        FsmVariable("num_frames_sent"; type = j("Int"), default = j("0")),
        FsmVariable("num_frames_received"; type = j("Int"), default = j("0")),
    ]

    FsmComponent("Mac";
        variables = variables,
        timers = [tx_timer, ifg_timer, jam_timer, backoff_timer],
        events = [carrier_start, carrier_end, collision, upper_packet],
        machines = [machine],
        helpers = mac_helpers())
end

# Everything around the machine: the constants and interface structs it needs,
# the constructor the model builds it with, the statistics emitter wired to the
# machine's transition hook, the entry-action bodies, and the handler layer
# that turns a PLCA callback into a dispatch.
function mac_helpers()
    [
        j("const MAX_ATTEMPTS = 16"),
        j("const BACKOFF_RANGE_LIMIT = 10"),
        j("const SLOT_BIT_LENGTH_10MB = 512"),

        # `MacDownlink` / `MacUpcalls` are NOT here either. The generated host
        # struct annotates fields with them, so they have to exist *before* it,
        # while helpers are emitted *after* the struct because they dispatch on
        # it. They live in the `Mac.jl` companion, ahead of the include.

        # The keyword constructor the model builds a MAC with is NOT here:
        # the julia domain models keyword arguments in a *call* but not in a
        # function *definition*, so it lives in the hand-written `Mac.jl`
        # companion beside the generated file. Everything the machine itself
        # needs is generated.

        # ── statistics ──────────────────────────────────────────────────
        j("""
          function _mac_emit!(mac::MacState, ctx, name::Symbol, value::Real)
              mac.recorder === nothing && return
              idx = get(mac.stat_handles, name, 0)
              idx > 0 || return
              emit_indexed_vector!(mac.recorder, idx, ctx, Float64(value))
          end
          """),
        # The transition hook has no schedule context, so the state signal is
        # emitted against the recorder's current time — the same instant the
        # hand-written `_mac_transition!` used.
        # The hand-written `_mac_transition!` emitted nothing when the state
        # did not actually change; the hook reproduces that.
        j("""
          function _mac_on_transition(mac::MacState, from, to)
              from == to && return nothing
              _mac_emit_state!(mac, to)
              nothing
          end
          """),
        j("""
          function _mac_emit_state!(mac::MacState, state)
              mac.recorder === nothing && return
              idx = get(mac.stat_handles, :state, 0)
              idx > 0 || return
              emit_indexed_vector!(mac.recorder, idx, _mac_ctx[], Float64(UInt8(state)))
          end
          """),
        # The context of the dispatch in flight, so the transition hook can
        # emit at the right simulation time without threading it through the
        # runtime's hook signature.
        j("const _mac_ctx = Ref{Any}(nothing)"),

        # ── entry actions ───────────────────────────────────────────────
        j("""
          function _mac_start_frame_transmission!(ctx, m::MacState)
              m.num_retries = 0
              pk = m.current_tx_frame::Packet
              frame_bits = data_length(pk).bits
              tx_bits = frame_bits + ETHERNET_PHY_HEADER_LEN_BYTES * 8 + m.phy_esd_length_bits
              schedule_timer!(ctx, to_simtime(tx_bits / m.bitrate), m.module_id, m.tx_timer,
                  (ctx2) -> _mac_expire_tx_timer!(ctx2, m))
              fsm_defer!(m.fsm_mac, () -> m.downlink.start_frame_tx(ctx, pk, ESD_ESD))
          end
          """),
        j("""
          function _mac_start_ifg_timer!(ctx, m::MacState)
              schedule_timer!(ctx, to_simtime(INTERFRAME_GAP_BITS / m.bitrate),
                  m.module_id, m.ifg_timer,
                  (ctx2) -> _mac_expire_ifg_timer!(ctx2, m))
          end
          """),
        j("""
          function _mac_start_jam_timer!(ctx, m::MacState)
              schedule_timer!(ctx, to_simtime((JAM_SIGNAL_BYTES * 8) / m.bitrate),
                  m.module_id, m.jam_timer,
                  (ctx2) -> _mac_expire_jam_timer!(ctx2, m))
          end
          """),
        j("""
          function _mac_start_backoff_timer!(ctx, m::MacState)
              slot_max = 1 << min(m.num_retries, BACKOFF_RANGE_LIMIT)
              slot = rand(m.rng, 0:slot_max - 1)
              schedule_timer!(ctx, to_simtime((slot * SLOT_BIT_LENGTH_10MB) / m.bitrate),
                  m.module_id, m.backoff_timer,
                  (ctx2) -> _mac_expire_backoff_timer!(ctx2, m))
          end
          """),

        # ── transition actions ──────────────────────────────────────────
        j("""
          function _mac_abort_transmission!(ctx, m::MacState)
              cancel!(m.tx_timer)
              fsm_defer!(m.fsm_mac, () -> m.downlink.end_frame_tx(ctx))
              fsm_defer!(m.fsm_mac, () -> m.downlink.start_signal_tx(ctx, SIG_JAM))
          end
          """),
        j("""
          function _mac_finish_transmission!(ctx, m::MacState)
              fsm_defer!(m.fsm_mac, () -> m.downlink.end_frame_tx(ctx))
              m.current_tx_frame = nothing
              m.num_frames_sent = m.num_frames_sent + 1
              _mac_emit!(m, ctx, :numFramesSent, m.num_frames_sent)
              fsm_defer!(m.fsm_mac, () -> m.upcalls.frame_sent(ctx, m))
          end
          """),

        # ── timer callbacks ─────────────────────────────────────────────
        # Each records the context for the transition hook, does whatever must
        # happen before the guards are evaluated, then dispatches.
        j("""
          function _mac_expire_tx_timer!(ctx, m::MacState)
              _mac_ctx[] = ctx
              mac_dispatch!(ctx, m, T_TX_TIMER, nothing)
          end
          """),
        j("""
          function _mac_expire_ifg_timer!(ctx, m::MacState)
              _mac_ctx[] = ctx
              mac_dispatch!(ctx, m, T_IFG_TIMER, nothing)
          end
          """),
        j("""
          function _mac_expire_jam_timer!(ctx, m::MacState)
              _mac_ctx[] = ctx
              m.downlink.end_signal_tx(ctx)
              m.num_retries = m.num_retries + 1
              mac_dispatch!(ctx, m, T_JAM_TIMER, nothing)
          end
          """),
        j("""
          function _mac_expire_backoff_timer!(ctx, m::MacState)
              _mac_ctx[] = ctx
              mac_dispatch!(ctx, m, T_BACKOFF_TIMER, nothing)
          end
          """),

        # ── the handler layer (the classifier seam) ─────────────────────
        # A PLCA callback updates the shared variables and then dispatches;
        # the machine itself never has to repeat that update per state.
        j("""
          function mac_handle_carrier_sense_start!(ctx, mac::MacState)
              _mac_ctx[] = ctx
              mac.carrier_sense = true
              _mac_emit!(mac, ctx, :carrierSense, 1)
              mac_dispatch!(ctx, mac, E_CARRIER_SENSE_START, nothing)
          end
          """),
        j("""
          function mac_handle_carrier_sense_end!(ctx, mac::MacState)
              _mac_ctx[] = ctx
              mac.carrier_sense = false
              _mac_emit!(mac, ctx, :carrierSense, 0)
              mac_dispatch!(ctx, mac, E_CARRIER_SENSE_END, nothing)
          end
          """),
        j("""
          function mac_handle_collision_start!(ctx, mac::MacState)
              _mac_ctx[] = ctx
              mac.collision = true
              _mac_emit!(mac, ctx, :collision, 1)
              mac_dispatch!(ctx, mac, E_COLLISION_START, nothing)
          end
          """),
        # Collision end changes no state at all — it is a variable update, so
        # it never reaches the machine.
        j("""
          function mac_handle_collision_end!(ctx, mac::MacState)
              mac.collision = false
              _mac_emit!(mac, ctx, :collision, 0)
              nothing
          end
          """),
        j("""
          function mac_handle_reception_end!(ctx, mac::MacState, kind::EthernetSignalKind, packet::Union{Nothing,Packet})
              kind === SIG_DATA || return
              packet === nothing && return
              _mac_process_received_frame!(ctx, mac, packet)
          end
          """),
        j("""
          function _mac_process_received_frame!(ctx, mac::MacState, packet::Packet)
              hdr = peek(packet, EthernetMacHeader)
              dst = hdr.destination.value
              is_broadcast = dst == 0xFFFFFFFFFFFF
              if mac.promiscuous || dst == mac.address || is_broadcast
                  mac.num_frames_received = mac.num_frames_received + 1
                  _mac_emit!(mac, ctx, :numFramesReceived, mac.num_frames_received)
                  mac.upcalls.frame_received(ctx, mac, packet)
              end
          end
          """),
        j("""
          function mac_upper_packet!(ctx, mac::MacState, packet::Packet)
              _mac_ctx[] = ctx
              push!(mac.queue, packet)
              mac_dispatch!(ctx, mac, E_UPPER_PACKET, nothing)
          end
          """),
    ]
end

# ── generate ────────────────────────────────────────────────────────────────

const OUTPUT = joinpath(@__DIR__, "..", "package", "linklayer", "main", "t1s", "MacFsm.jl")

function main()
    component = ethernet_csma_mac_component()
    # No module wrapper: `T1s.jl` includes its nine files into one module.
    export_component(component, normpath(OUTPUT); wrap_module = false)
    println("wrote ", normpath(OUTPUT))
end

# Only regenerate when this file is *run*. Including it (the watch example does,
# to get the machine document the diagram projects) must not write anything.
if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    main()
end
