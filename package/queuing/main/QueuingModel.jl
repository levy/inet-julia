# ============================================================================
# A queuing network as a model the lifecycle can run: the canonical chain of
# source, queue, server and sink, with its parameters exposed as degrees of
# freedom so the workbench can sweep them.
#
# This is the demonstration that the queuing elements are a model library and
# not just a set of parts — everything the lifecycle needs comes from the
# network the elements form, without the model itself knowing which elements
# they are.
# ============================================================================

using .PacketProtocolModule: check_packet_connections
using .PacketSourceModule: PacketTemplate
using .ActivePacketSourceElement: ActivePacketSourceModule
using .PacketQueueElement: PacketQueueModule, drop_at_end,
    queue_length
using .PacketServerElement: PacketServerModule
using .PassivePacketSinkElement: PassivePacketSinkModule
using OmnetppSimulator.NetworkModule: Network, add_module!, connect!,
    network_module_count, network_barrier, network_delay_edges, network_topology,
    initialize_network!, register_network_statistics!, start_network!,
    reset_network!, finalize_network!
using OmnetppSimulator.VolatileModule: Volatile, exponential

"""
    QueuingModel

The canonical queuing chain — packets are produced, wait their turn, are served
one at a time and are counted — as a model the lifecycle can configure, run and
sweep.

Arrivals and service times are exponential, so with a capacity this is an
M/M/1/K queue and without one an M/M/1: the classic model whose mean queue
length and waiting time are known in closed form, which is what makes it worth
shipping as an example.
"""
@document struct QueuingModel <: AbstractModel
    arrival_rate::Float64          # packets per second
    service_rate::Float64          # packets per second one server can manage
    packet_capacity::Int           # 0 for an unbounded queue
    packet_bytes::Int
    time_limit::Float64            # seconds
    seed::Int
    network::Any                   # the live Network of modules
end

model_module_count(m::AQueuingModel)   = network_module_count(m.network)
model_barrier_module(m::AQueuingModel) = network_barrier(m.network)
model_delay_edges(m::AQueuingModel)    = network_delay_edges(m.network)
# The diagram comes from the same wiring the engine reads, so it cannot drift
# from the model it describes.
model_topology(m::AQueuingModel)       = network_topology(m.network)

model_description(::Type{QueuingModel}) =
    "A single queue served by one server: packets arrive, wait, are served, and leave."

model_parameter_space(::Type{QueuingModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate,    5.0,    nothing, StructuralDOF),
    Parameter(:service_rate,    10.0,   nothing, StructuralDOF),
    # Zero means no limit, so nothing is ever dropped and the queue is M/M/1.
    Parameter(:packet_capacity, 0,      nothing, StructuralDOF),
    Parameter(:packet_bytes,    100,    nothing, StructuralDOF),
    Parameter(:time_limit,      100.0,  nothing, StructuralDOF),
    Parameter(:seed,            42,     nothing, StochasticDOF),
])

function build_model(::Type{QueuingModel}, r::AResolvedParameters)
    m = MQueuingModel(Float64(r[:arrival_rate]), Float64(r[:service_rate]),
                        Int(r[:packet_capacity]), Int(r[:packet_bytes]),
                        Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_queuing_network(m)
    m
end

function _build_queuing_network(m)
    network = Network(:Queuing)
    source = add_module!(network, ActivePacketSourceModule(:source;
        production_interval = Volatile(exponential(1 / m.arrival_rate)),
        packet = PacketTemplate(length = Bytes(m.packet_bytes)),
        seed = m.seed))
    # A capacity with a dropper rather than back pressure: an M/M/1/K queue
    # loses what does not fit instead of stopping the arrivals.
    queue = add_module!(network, m.packet_capacity == 0 ? PacketQueueModule(:queue) :
        PacketQueueModule(:queue; packet_capacity = m.packet_capacity,
                          dropper = drop_at_end))
    server = add_module!(network, PacketServerModule(:server;
        processing_time = Volatile(exponential(1 / m.service_rate)),
        seed = m.seed + 1))
    sink = add_module!(network, PassivePacketSinkModule(:sink))
    connect!(source.out, queue.in)
    connect!(queue.out, server.in)
    connect!(server.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AQueuingModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AQueuingModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    # The run ends by the clock rather than by running out of packets: the
    # source produces for as long as it is allowed to.
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AQueuingModel, recorder) = finalize_network!(m.network, recorder)
