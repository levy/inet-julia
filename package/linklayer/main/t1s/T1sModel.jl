# ============================================================================
# T1sModel — the `AbstractModel` wrapper that glues everything together.
# Uses T1sModule (t1s/) for the FSM/PHY/wire building blocks.
#
# Topology: coordinator + (N-1) followers on a chain of N junctions, matching
# INET's MultidropNetwork.ned:44-49:
#
#   coord ---[d_seg]--- j[0] ---[d_seg]--- j[1] --- ... --- j[N-1]
#                        |                   |                 |
#                     [d_stub]            [d_stub]           [d_stub]
#                        |                   |                 |
#                    node[0]              node[1]           node[N-1]
#
# Every "node" (coord + N-1 nodes) has its own PHY + PLCA + MAC + App, all
# on ONE module_id (Q5 answered: consolidate to reduce dispatch overhead).
# Each junction gets its own module_id.
#
# For notraffic: N=5 total (1 coord + 4 followers), no app source, only PLCA
# cycle activity. bestcase / worstcase configure specific per-node source
# offsets. Golden hashes pinned in `test/t1s/phase9_model.jl`.
# ============================================================================

using .T1sModule

const T1S_BARRIER_MODULE_ID = 1        # convention — module 1 is the barrier

# Segment delays: 100 cm main-chain segments, 50 cm node stubs. From
# MultidropNetwork.ned's EthernetMultidropLink parameters.
const _DEFAULT_D_SEG  = 1.00 / 2e8    # 5 ns
const _DEFAULT_D_STUB = 0.50 / 2e8    # 2.5 ns

# Wire everything together for one node — creates PhyState, PlcaState,
# MacState, AppState and cross-plugs the callbacks.
mutable struct T1sNode
    module_id::Int
    address::UInt64
    is_coord::Bool
    phy::PhyState
    plca::PlcaState
    mac::MacState
    app::AppState
end

mutable struct T1sModelState
    nodes::Vector{T1sNode}
    junctions::Vector{WireJunctionState}
    time_limit::SimTime
end

# @document is used for the reactive shadowing pattern of the simulator
# framework. Fields exposed on the model type; the state struct is opaque
# behind `state::Any`, same idiom as MM1KModel.
@native_document struct T1sModel <: AbstractModel
    n_nodes::Int                         # coordinator + (n_nodes-1) followers
    n_modules::Int                       # total for the scheduler
    time_limit::SimTime
    d_seg::Float64                       # segment (main chain) delay in seconds
    d_stub::Float64                      # node stub delay in seconds
    max_bc::Int
    # Per-node source config: index 1 = coord, 2..N = followers. `nothing` = sink-only.
    sources::Vector{Union{Nothing,SourceConfig}}
    seed::Int
    vec_path::String                     # "" ⇒ no .vec writer; else output path
    state::Any                           # T1sModelState — mutable per-run state
end

model_module_count(m::AT1sModel)   = m.n_modules
model_barrier_module(m::AT1sModel) = T1S_BARRIER_MODULE_ID
# All nodes and junctions transitively reach each other via the shared bus,
# so ONE cluster — no delay-edge graph structure the parallel engine can
# exploit. Empty edges → parallel engine treats as single cluster (barrier).
model_delay_edges(m::AT1sModel)    = Tuple{Int,Int,SimTime}[]

model_description(::Type{T1sModel}) =
    "10BASE-T1S multidrop bus with PLCA arbitration (IEEE 802.3cg-2019)."

model_parameter_space(::Type{T1sModel}) = ParameterSpace(Parameter[
    Parameter(:n_nodes,    5,        nothing, StructuralDOF),
    Parameter(:time_limit, 100e-6,   nothing, StructuralDOF),
    Parameter(:d_seg,      _DEFAULT_D_SEG,  nothing, StructuralDOF),
    Parameter(:d_stub,     _DEFAULT_D_STUB, nothing, StructuralDOF),
    Parameter(:max_bc,     0,        nothing, StructuralDOF),
    Parameter(:seed,       42,       nothing, StochasticDOF),
    # Topology preset — :notraffic, :bestcase, :worstcase, or :custom.
    Parameter(:scenario,   :notraffic, [:notraffic, :bestcase, :worstcase], StructuralDOF),
    # Optional .vec output path — empty ⇒ recording still happens in memory
    # (available via SimulationResult.vectors), but no file is written.
    Parameter(:vec_path,   "",       nothing, IterationDOF),
])

# ---------- build_model -----------------------------------------------------

function build_model(::Type{T1sModel}, r::AResolvedParameters)
    n_nodes = Int(r[:n_nodes])
    time_limit = to_simtime(Float64(r[:time_limit]))
    d_seg  = Float64(r[:d_seg])
    d_stub = Float64(r[:d_stub])
    max_bc = Int(r[:max_bc])
    seed   = Int(r[:seed])
    scenario = Symbol(r[:scenario])

    # Sources per scenario. For notraffic: no traffic.
    # For bestcase / worstcase: TODO in follow-up phases; use notraffic
    # config for now.
    sources = _sources_for_scenario(scenario, n_nodes)
    # INET's MultidropNetwork.ned:44-49 wires the coordinator to j[0]
    # directly; junctions total = numNodes = n_nodes - 1 (one per follower,
    # coord shares j[0] with node[0]).
    n_junctions = n_nodes - 1
    n_modules = 1 + n_nodes + n_junctions

    vec_path = haskey(r, :vec_path) ? String(r[:vec_path]) : ""
    m = T1sModel(n_nodes, n_modules, time_limit, d_seg, d_stub,
                    max_bc, sources, seed, vec_path, nothing)
    m.state = _build_state!(m)
    return m
end

_sources_for_scenario(::Val{S}, ::Int) where {S} = error("unknown scenario $S")

function _sources_for_scenario(scenario::Symbol, n_nodes::Int)
    if scenario === :notraffic
        return Union{Nothing,SourceConfig}[nothing for _ in 1:n_nodes]
    else
        # Bestcase / worstcase — placeholders using a fixed 10 µs cadence.
        # Real per-node offsets are a follow-up.
        srcs = Union{Nothing,SourceConfig}[]
        for i in 1:n_nodes
            if i == 1
                push!(srcs, nothing)              # coord: sink only
            else
                # Follower sends to coord (address 0).
                push!(srcs, SourceConfig(dst_address = UInt64(0),
                                          interval = 10e-6,
                                          packet_length = 46))
            end
        end
        return srcs
    end
end

# ---------- build state (wire everything) -----------------------------------

function _build_state!(m::AT1sModel)
    n = m.n_nodes                            # coord + followers (n = 1 + numNodes)
    n_followers = n - 1                      # INET numNodes
    d_seg  = to_simtime(m.d_seg)             # 100 cm — coord-to-j[0] AND j[i]-j[i+1]
    d_stub = to_simtime(m.d_stub)            #  50 cm — j[i]-node[i]
    # Module IDs (matches INET's MultidropNetwork):
    #   1                             : barrier
    #   2                             : coord (node "controller", local_id=0)
    #   3..2+n_followers              : followers (INET node[0..N-1], local_id 1..N)
    #   3+n_followers..2+2*n_followers: junctions (INET j[0..N-1])
    node_module_id(i) = 1 + i
    junction_module_id(i) = 2 + n_followers + i    # 1-based; matches j[i-1]

    nodes = T1sNode[]
    junctions = WireJunctionState[]

    # Build junctions: one per follower (INET's j[0..N-1]).
    for k in 1:n_followers
        push!(junctions, WireJunctionState(junction_module_id(k)))
    end

    # Build nodes.
    for i in 1:n
        addr = UInt64(i - 1)                     # coord = 0, followers = 1..
        is_coord = (i == 1)

        phy  = PhyState(node_module_id(i))
        plca = PlcaState(node_module_id(i),
                         PlcaConfig(plca_node_count = n,
                                    local_node_id = i - 1,
                                    max_bc = m.max_bc);
                         upcalls = default_plca_upcalls())
        mac  = MacState(node_module_id(i), addr; seed = m.seed + Int(addr))
        app  = AppState(node_module_id(i), addr;
                        source = m.sources[i], seed = m.seed + Int(addr))
        app.mac = mac
        push!(nodes, T1sNode(node_module_id(i), addr, is_coord, phy, plca, mac, app))

        _wire_phy_upcalls!(nodes[end])
        _wire_plca_downlink!(nodes[end])
        _wire_mac_downlink!(nodes[end])
        nodes[end].mac.upcalls = MacUpcalls(
            (ctx, mac, pk) -> app_receive!(ctx, nodes[end].app, pk),
            (ctx, mac)     -> nothing,
        )
    end

    # Wire coordinator to j[0] via 100 cm (d_seg). INET:
    #   controller.ethg++ <--> EthernetMultidropLink { length = 100cm; } <--> j[0].port++
    coord = nodes[1]
    j0 = junctions[1]
    coord_port = junction_add_port!(j0, coord.module_id, d_seg,
        (ctx, sig) -> phy_rx_start!(ctx, coord.phy, sig),
        (ctx, sig) -> phy_rx_update!(ctx, coord.phy, sig))
    coord.phy.downlink = PhyDownlink(
        (ctx, sig) -> schedule_event!(ctx, d_seg, j0.module_id,
                                ctx2 -> junction_receive!(ctx2, j0, coord_port, sig)),
        (ctx, sig) -> schedule_event!(ctx, d_seg, j0.module_id,
                                ctx2 -> junction_update!(ctx2, j0, coord_port, sig)),
    )

    # Wire each follower node[k-1] (INET's node[k-1]) to junction[k] via 50 cm.
    # `nodes[1+k]` is our follower with local_node_id = k.
    for k in 1:n_followers
        node = nodes[1 + k]
        j = junctions[k]
        stub_port = junction_add_port!(j, node.module_id, d_stub,
            (ctx, sig) -> phy_rx_start!(ctx, node.phy, sig),
            (ctx, sig) -> phy_rx_update!(ctx, node.phy, sig))
        node.phy.downlink = PhyDownlink(
            (ctx, sig) -> schedule_event!(ctx, d_stub, j.module_id,
                                    ctx2 -> junction_receive!(ctx2, j, stub_port, sig)),
            (ctx, sig) -> schedule_event!(ctx, d_stub, j.module_id,
                                    ctx2 -> junction_update!(ctx2, j, stub_port, sig)),
        )
    end

    # Chain junctions: j[k] ↔ j[k+1] via 100 cm.
    for k in 1:(n_followers - 1)
        j1 = junctions[k]
        j2 = junctions[k + 1]
        p1_at_j1 = Ref(0)
        p2_at_j2 = Ref(0)
        p1_at_j1[] = junction_add_port!(j1, j2.module_id, d_seg,
            (ctx, sig) -> junction_receive!(ctx, j2, p2_at_j2[], sig),
            (ctx, sig) -> junction_update!(ctx, j2, p2_at_j2[], sig))
        p2_at_j2[] = junction_add_port!(j2, j1.module_id, d_seg,
            (ctx, sig) -> junction_receive!(ctx, j1, p1_at_j1[], sig),
            (ctx, sig) -> junction_update!(ctx, j1, p1_at_j1[], sig))
    end

    return T1sModelState(nodes, junctions, m.time_limit)
end

# Wire PHY's upcalls → PLCA (carrier/collision) + MAC (via PLCA's edge detection).
function _wire_phy_upcalls!(node::T1sNode)
    plca = node.plca
    mac  = node.mac
    node.phy.upcalls = PhyUpcalls(
        (ctx, _) -> plca_on_carrier_sense_start!(ctx, plca),
        (ctx, _) -> plca_on_carrier_sense_end!(ctx, plca),
        (ctx, _) -> plca_on_collision_start!(ctx, plca),
        (ctx, _) -> plca_on_collision_end!(ctx, plca),
        (ctx, _, sig) -> begin
            plca_on_reception_start!(ctx, plca, sig)
            plca_data_on_reception_start!(ctx, plca, sig)
        end,
        (ctx, _, sig) -> begin
            plca_on_reception_end!(ctx, plca, sig)
            plca_data_on_reception_end!(ctx, plca, sig)
            # Deliver received DATA frames to MAC.
            if sig.kind === SIG_DATA && sig.packet !== nothing
                mac_handle_reception_end!(ctx, mac, sig.kind, sig.packet)
            end
        end,
    )
    # PLCA's carrier/collision edges → MAC.
    plca.upcalls = PlcaControlUpcalls(
        (ctx, p) -> plca_commit_to!(ctx, p),
        (ctx, p) -> begin
            if p.carrier_status
                mac_handle_carrier_sense_start!(ctx, mac)
            else
                mac_handle_carrier_sense_end!(ctx, mac)
            end
        end,
        (ctx, p) -> begin
            if p.signal_status
                mac_handle_collision_start!(ctx, mac)
            else
                mac_handle_collision_end!(ctx, mac)
            end
        end,
    )
end

function _wire_plca_downlink!(node::T1sNode)
    phy = node.phy
    node.plca.downlink = PlcaDownlink(
        (ctx, kind) -> phy_start_signal_transmission!(ctx, phy, kind),
        (ctx)       -> phy_end_signal_transmission!(ctx, phy),
        (ctx, pk, esd) -> phy_start_frame_transmission!(ctx, phy, pk, esd),
        (ctx)          -> phy_end_frame_transmission!(ctx, phy),
    )
end

function _wire_mac_downlink!(node::T1sNode)
    plca = node.plca
    node.mac.downlink = MacDownlink(
        (ctx, pk, esd) -> plca_start_frame_transmission!(ctx, plca, pk),
        (ctx)          -> plca_end_frame_transmission!(ctx, plca),
        (ctx, kind)    -> plca_start_signal_from_mac!(ctx, plca, kind),
        (ctx)          -> plca_end_signal_from_mac!(ctx, plca),
    )
end

# ---------- lifecycle -------------------------------------------------------

function reset_model!(m::AT1sModel)
    m.state = _build_state!(m)
    m
end

function schedule_initial_events!(m::AT1sModel, engine::SimulationEngine, recorder)
    # Wire the recorder into every node's state structs before scheduling.
    # See plan/done/ten-base-t1s-statistics.md §3.
    _wire_recorder!(m, recorder)
    # Fire initial-value emissions at t=0 (INET's initialize() convention)
    # and final-value emissions at time_limit (INET's finish() convention).
    # These schedule extra root events, which DOES change the network_hash.
    # We only add them when the model is writing a .vec file for INET
    # cross-comparison; in normal use (no vec_path) recording stays
    # determinism-neutral and the pre-stats network hashes still hold.
    if recorder !== nothing && !isempty(m.vec_path)
        _emit_initial_stats!(engine, m)
        _emit_final_stats!(engine, m)
    end
    st = m.state
    for node in st.nodes
        # Start PLCA.
        let plca = node.plca
            schedule_root!(engine, to_simtime(0.0), node.module_id,
                           ctx -> plca_start!(ctx, plca))
        end
        # Start app source if any.
        if node.app.source !== nothing
            let app = node.app, offset = node.app.source.initial_offset
                schedule_root!(engine, offset, node.module_id,
                               ctx -> app_generate!(ctx, app))
            end
        end
    end
    # Stop at time_limit.
    schedule_root!(engine, m.time_limit, T1S_BARRIER_MODULE_ID,
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

# ============================================================================
# Statistics wiring — call once from schedule_initial_events!.
# Registers indexed vectors per (node, signal-name) so the recorder's .vec
# writer has one column per signal per node (matching INET's grouping under
# `Net.node[i].plca`, `.mac`, `.phy`).
# ============================================================================

# Signals we emit at each layer. Kept as short symbols (:curID etc.) for
# internal lookup; the STRING name registered with the recorder appends
# `:vector` (INET's naming convention), so cross-comparison against INET's
# .vec files matches on both module path and signal name.
const _PLCA_SIGNALS = (
    :curID, :cycleLength, :toLength, :ownToLength, :packetPendingDelay,
    :packetInterval, :transmitOpportunityUsed,
    :numPacketsPerTo, :numPacketsPerOwnTo, :numPacketsPerCycle,
    :controlState, :dataState, :rxCmd, :txCmd,
    :carrierSense, :collision,     # PLCA-fabricated edges to MAC
)
const _MAC_SIGNALS = (
    :carrierSense, :collision, :state,
    :numFramesSent, :numFramesReceived,
)
const _PHY_SIGNALS = (
    :state, :receivedSignalType, :transmittedSignalType,
    :transmitting, :throughput, :busUsed,
)

# INET module-path mapping — the layer prefix under a node.
_inet_node_path(i, n) = i == 1 ? "MultidropNetwork.controller" :
                                  "MultidropNetwork.node[$(i - 2)]"

# Signal names get INET's `:vector` suffix at the .vec-writer level.
_inet_signal_name(sym::Symbol) = "$(sym):vector"

# Emit each MAC / PHY signal at t=0 with its initial value, matching
# INET's initialize() emit() convention. plca_start! handles PLCA signals.
function _emit_initial_stats!(engine::SimulationEngine, m::AT1sModel)
    st = m.state
    for (i, node) in enumerate(st.nodes)
        schedule_root!(engine, to_simtime(0.0), node.module_id,
                       ctx -> _emit_node_initial_stats!(ctx, node))
    end
end

function _emit_node_initial_stats!(ctx, node)
    mac = node.mac
    phy = node.phy
    # MAC initial values.
    if mac.recorder !== nothing
        for (name, val) in ((:state, UInt8(fsm_state(mac.fsm_mac))),
                            (:carrierSense, 0), (:collision, 0),
                            (:numFramesSent, 0), (:numFramesReceived, 0))
            idx = get(mac.stat_handles, name, 0)
            idx > 0 && emit_indexed_vector!(mac.recorder, idx, ctx, Float64(val))
        end
    end
    # PHY initial values.
    if phy.recorder !== nothing
        for (name, val) in ((:state, UInt8(phy.fsm)),
                            (:transmitting, 0),
                            (:receivedSignalType, 0),
                            (:transmittedSignalType, 0))
            idx = get(phy.stat_handles, name, 0)
            idx > 0 && emit_indexed_vector!(phy.recorder, idx, ctx, Float64(val))
        end
    end
end

# Emit each layer's CURRENT signal value at sim-end (mirrors INET's finish()).
function _emit_final_stats!(engine::SimulationEngine, m::AT1sModel)
    st = m.state
    for node in st.nodes
        schedule_root!(engine, m.time_limit, node.module_id,
                       ctx -> _emit_node_final_stats!(ctx, node))
    end
end

function _emit_node_final_stats!(ctx, node)
    plca = node.plca
    mac  = node.mac
    phy  = node.phy
    if plca.recorder !== nothing
        # Include dataState — the data FSM's current position.
        for (name, val) in ((:curID, plca.cur_id),
                            (:rxCmd, UInt8(plca.rx_cmd)),
                            (:txCmd, UInt8(plca.tx_cmd)),
                            (:controlState, UInt8(fsm_state(plca.fsm_control))),
                            (:dataState, UInt8(fsm_state(plca.fsm_data))),
                            (:carrierSense, plca.carrier_status ? 1 : 0),
                            (:collision, plca.signal_status ? 1 : 0))
            idx = get(plca.stat_handles, name, 0)
            idx > 0 && emit_indexed_vector!(plca.recorder, idx, ctx, Float64(val))
        end
    end
    if mac.recorder !== nothing
        for (name, val) in ((:state, UInt8(fsm_state(mac.fsm_mac))),
                            (:carrierSense, mac.carrier_sense ? 1 : 0),
                            (:collision, mac.collision ? 1 : 0),
                            (:numFramesSent, mac.num_frames_sent),
                            (:numFramesReceived, mac.num_frames_received))
            idx = get(mac.stat_handles, name, 0)
            idx > 0 && emit_indexed_vector!(mac.recorder, idx, ctx, Float64(val))
        end
    end
    if phy.recorder !== nothing
        for (name, val) in ((:state, UInt8(phy.fsm)),
                            (:transmitting, phy.current_tx === nothing ? 0 : 1),
                            (:receivedSignalType, 0),
                            (:transmittedSignalType, 0))
            idx = get(phy.stat_handles, name, 0)
            idx > 0 && emit_indexed_vector!(phy.recorder, idx, ctx, Float64(val))
        end
    end
end

function _wire_recorder!(m::AT1sModel, recorder)
    recorder === nothing && return
    st = m.state
    n = m.n_nodes
    for (i, node) in enumerate(st.nodes)
        base = _inet_node_path(i, n)
        # PLCA
        node.plca.recorder = recorder
        node.plca.node_idx = i
        for sig in _PLCA_SIGNALS
            node.plca.stat_handles[sig] = register_indexed_vector!(
                recorder, "$base.eth[0].plca", _inet_signal_name(sig))
        end
        # MAC
        node.mac.recorder = recorder
        node.mac.node_idx = i
        for sig in _MAC_SIGNALS
            node.mac.stat_handles[sig] = register_indexed_vector!(
                recorder, "$base.eth[0].mac", _inet_signal_name(sig))
        end
        # PHY
        node.phy.recorder = recorder
        node.phy.node_idx = i
        for sig in _PHY_SIGNALS
            node.phy.stat_handles[sig] = register_indexed_vector!(
                recorder, "$base.eth[0].phy", _inet_signal_name(sig))
        end
    end
    return nothing
end

# Attach a result sink when `:vec_path` is set (matches RoutingModel).
function make_recorder(m::AT1sModel, engine::SimulationEngine)
    rec = Recorder()
    path = _t1s_vec_path(m)
    if path !== nothing
        run_name = engine isa AbstractParallelEngine ? "parallel" : "sequential"
        attach_sink!(rec, OmnetppTextSink(path; run_name = run_name))
    end
    rec
end

# Optional per-model .vec output path — off by default so tests don't write
# files. Set via the :vec_path parameter (added below).
_t1s_vec_path(m::AT1sModel) = isempty(m.vec_path) ? nothing : m.vec_path
