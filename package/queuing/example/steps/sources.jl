# ────────────────────────────────────────────────────────────────────────────
# The models the "Sources and Sinks" steps run.
#
# A step's model is ordinary example code — it is not part of the element
# library, and the tutorial embeds its source by name so the reader sees the
# very network that runs. Each model is small on purpose: the point of a step
# is one idea, and everything else stays at its default.
# ────────────────────────────────────────────────────────────────────────────

using InetQueuing: ActivePacketSourceModule,
    PassivePacketSourceModule,
    ActivePacketSinkModule,
    PassivePacketSinkModule, PacketTemplate, check_packet_connections
using OmnetppSimulator: AbstractModel, AbstractEngine, AResolvedParameters,
    Parameter, ParameterSpace, StructuralDOF, StochasticDOF, LimitReached,
    schedule_root!, stop!, to_simtime
using OmnetppSimulator.NetworkModule: Network, add_module!, connect_gates!,
    network_module_count, network_barrier, network_delay_edges, network_topology,
    initialize_network!, register_network_statistics!, start_network!,
    reset_network!, finalize_network!
using OmnetppSimulator.VolatileModule: Volatile, exponential
using InetPacket.PacketModule: Bytes
import OmnetppSimulator: model_module_count, model_barrier_module, model_delay_edges,
    model_topology, model_description, model_parameter_space, build_model,
    reset_model!, schedule_initial_events!, finalize_model!

export ActiveSourcePassiveSinkModel, PassiveSourceActiveSinkModel

"""
    ActiveSourcePassiveSinkModel

The smallest queueing network there is: a source that decides when a packet
appears, pushing straight into a sink that takes whatever arrives.

Nothing waits and nothing is served, so what the run shows is the production
process itself — how many packets a given interval produces, and how a random
interval differs from a fixed one.
"""
@native_document struct ActiveSourcePassiveSinkModel <: AbstractModel
    production_interval::Float64   # seconds between packets (mean, when random)
    random_intervals::Bool         # exponential rather than fixed
    packet_bytes::Int
    time_limit::Float64            # seconds
    seed::Int
    network::Any                   # the live Network of modules
end

model_module_count(m::AActiveSourcePassiveSinkModel)   = network_module_count(m.network)
model_barrier_module(m::AActiveSourcePassiveSinkModel) = network_barrier(m.network)
model_delay_edges(m::AActiveSourcePassiveSinkModel)    = network_delay_edges(m.network)
model_topology(m::AActiveSourcePassiveSinkModel)       = network_topology(m.network)

model_description(::Type{ActiveSourcePassiveSinkModel}) =
    "A source that produces packets on its own, pushing them into a sink that counts them."

model_parameter_space(::Type{ActiveSourcePassiveSinkModel}) = ParameterSpace(Parameter[
    Parameter(:production_interval, 0.1,   nothing, StructuralDOF),
    Parameter(:random_intervals,    false, nothing, StructuralDOF),
    Parameter(:packet_bytes,        100,   nothing, StructuralDOF),
    Parameter(:time_limit,          10.0,  nothing, StructuralDOF),
    Parameter(:seed,                42,    nothing, StochasticDOF),
])

function build_model(::Type{ActiveSourcePassiveSinkModel}, r::AResolvedParameters)
    m = ActiveSourcePassiveSinkModel(Float64(r[:production_interval]),
                                        Bool(r[:random_intervals]),
                                        Int(r[:packet_bytes]),
                                        Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_source_sink_network(m)
    m
end

function _build_source_sink_network(m)
    network = Network(:SourceSink; rules = queuing_rng_rules(source = m.seed))
    # A fixed interval produces a packet like clockwork; an exponential one
    # produces a Poisson process with the same mean, which is what the arrival
    # streams of every later step are made of.
    interval = m.random_intervals ? Volatile(exponential(m.production_interval)) :
                                    m.production_interval
    source = add_module!(network, ActivePacketSourceModule(:source;
        production_interval = interval,
        packet = PacketTemplate(length = Bytes(m.packet_bytes))))
    sink = add_module!(network, PassivePacketSinkModule(:sink))
    connect_gates!(source.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AActiveSourcePassiveSinkModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AActiveSourcePassiveSinkModel,
                                  engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, LimitReached(:simulation_time)))
    engine
end

finalize_model!(m::AActiveSourcePassiveSinkModel, recorder) =
    finalize_network!(m.network, recorder)

"""
    PassiveSourceActiveSinkModel

The same two elements with the initiative the other way round: the sink decides
when it wants a packet, and the source hands one over on request.

Nothing about the packets changes — what changes is who drives. Every element
in this library plays one of these two roles at each of its gates, which is why
a queue can sit between a pushing source and a pulling server without either
knowing about the other.
"""
@native_document struct PassiveSourceActiveSinkModel <: AbstractModel
    collection_interval::Float64   # seconds between collections (mean, when random)
    random_intervals::Bool
    packet_bytes::Int
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::APassiveSourceActiveSinkModel)   = network_module_count(m.network)
model_barrier_module(m::APassiveSourceActiveSinkModel) = network_barrier(m.network)
model_delay_edges(m::APassiveSourceActiveSinkModel)    = network_delay_edges(m.network)
model_topology(m::APassiveSourceActiveSinkModel)       = network_topology(m.network)

model_description(::Type{PassiveSourceActiveSinkModel}) =
    "A sink that collects packets on its own from a source that provides them on request."

model_parameter_space(::Type{PassiveSourceActiveSinkModel}) = ParameterSpace(Parameter[
    Parameter(:collection_interval, 0.2,   nothing, StructuralDOF),
    Parameter(:random_intervals,    false, nothing, StructuralDOF),
    Parameter(:packet_bytes,        50,    nothing, StructuralDOF),
    Parameter(:time_limit,          10.0,  nothing, StructuralDOF),
    Parameter(:seed,                42,    nothing, StochasticDOF),
])

function build_model(::Type{PassiveSourceActiveSinkModel}, r::AResolvedParameters)
    m = PassiveSourceActiveSinkModel(Float64(r[:collection_interval]),
                                        Bool(r[:random_intervals]),
                                        Int(r[:packet_bytes]),
                                        Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_pull_network(m)
    m
end

function _build_pull_network(m)
    network = Network(:PullSourceSink; rules = queuing_rng_rules(source = m.seed, sink = m.seed + 1))
    source = add_module!(network, PassivePacketSourceModule(:source;
        packet = PacketTemplate(length = Bytes(m.packet_bytes))))
    interval = m.random_intervals ? Volatile(exponential(m.collection_interval)) :
                                    m.collection_interval
    sink = add_module!(network, ActivePacketSinkModule(:sink;
        collection_interval = interval))
    connect_gates!(source.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::APassiveSourceActiveSinkModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::APassiveSourceActiveSinkModel,
                                  engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, LimitReached(:simulation_time)))
    engine
end

finalize_model!(m::APassiveSourceActiveSinkModel, recorder) =
    finalize_network!(m.network, recorder)
