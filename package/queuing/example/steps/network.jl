# ────────────────────────────────────────────────────────────────────────────
# The model the "Complex examples" step runs: most of the elements seen so far,
# in one network.
#
# Nothing new is introduced here. The point is that nothing new is *needed*:
# the elements compose, and a bigger network is the same parts wired together
# — including a compound one, which is a piece of network with a name.
# ────────────────────────────────────────────────────────────────────────────

export ComplexNetworkModel

"""
    ComplexNetworkModel

Two sources feeding one priority queue through a multiplexer, drained by a
server whose output is filtered before it reaches the sink.

Every element in it appeared in an earlier step, and every one of them is doing
exactly what it did there. What is worth watching is that they did not have to
be adapted to each other: a multiplexer does not know it is feeding a compound,
and the compound does not know a filter is downstream.
"""
@document struct ComplexNetworkModel <: AbstractModel
    arrival_rate::Float64        # per source
    processing_time::Float64
    priorities::Int
    level_capacity::Int
    pass_rate::Float64           # the share the filter lets through
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AComplexNetworkModel)   = network_module_count(m.network)
model_barrier_module(m::AComplexNetworkModel) = network_barrier(m.network)
model_delay_edges(m::AComplexNetworkModel)    = network_delay_edges(m.network)
model_topology(m::AComplexNetworkModel)       = network_topology(m.network)

model_description(::Type{ComplexNetworkModel}) =
    "Two sources, a multiplexer, a priority queue, a server and a filter: the elements composed."

model_parameter_space(::Type{ComplexNetworkModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate,    8.0,   nothing, StructuralDOF),
    Parameter(:processing_time, 0.08,  nothing, StructuralDOF),
    Parameter(:priorities,      2,     nothing, StructuralDOF),
    Parameter(:level_capacity,  4,     nothing, StructuralDOF),
    Parameter(:pass_rate,       0.75,  nothing, StructuralDOF),
    Parameter(:time_limit,      100.0, nothing, StructuralDOF),
    Parameter(:seed,            42,    nothing, StochasticDOF),
])

function build_model(::Type{ComplexNetworkModel}, r::AResolvedParameters)
    m = MComplexNetworkModel(Float64(r[:arrival_rate]), Float64(r[:processing_time]),
                               Int(r[:priorities]), Int(r[:level_capacity]),
                               Float64(r[:pass_rate]), Float64(r[:time_limit]),
                               Int(r[:seed]), nothing)
    m.network = _build_complex_network(m)
    m
end

function _build_complex_network(m)
    network = Network(:Complex)
    # Two independent streams, joined into one.
    join = add_module!(network, PacketMultiplexerModule(:multiplexer; inputs = 2))
    for index in 1:2
        source = add_module!(network, ActivePacketSourceModule(Symbol(:source, index);
            production_interval = Volatile(exponential(1 / m.arrival_rate)),
            packet = PacketTemplate(length = Bytes(100)),
            seed = m.seed + index))
        connect!(source.out, join.in[index])
    end
    # One compound queue for both of them, drained by one server.
    queue = priority_queue(network, :queue, m.priorities;
        queue_parameters = (packet_capacity = m.level_capacity,))
    server = add_module!(network, PacketServerModule(:server;
        processing_time = m.processing_time))
    # And a filter on the way out, dropping rather than refusing so the chain
    # keeps running.
    rng = MersenneTwister(m.seed + 99)
    pass_rate = m.pass_rate
    filter = add_module!(network, PacketFilterModule(:filter;
        predicate = _ -> rand(rng) < pass_rate))
    sink = _step_sink(network, :sink)
    connect!(join.out, queue.in)
    connect!(queue.out, server.in)
    connect!(server.out, filter.in)
    connect!(filter.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AComplexNetworkModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AComplexNetworkModel,
                                  engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AComplexNetworkModel, recorder) = finalize_network!(m.network, recorder)
