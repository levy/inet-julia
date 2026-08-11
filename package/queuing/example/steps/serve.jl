# ────────────────────────────────────────────────────────────────────────────
# The models the "Advanced queues" and back-pressure steps run.
#
# Both are about what an element does when it cannot pass a packet on: a
# priority queue overflows into its next level, and a filter with back pressure
# refuses rather than drops. Refusing is not losing, and that distinction is
# the whole of both steps.
# ────────────────────────────────────────────────────────────────────────────

using InetQueuing: priority_queue, priority_queue_length

export PriorityQueueModel, BackpressureFilterModel

# ── The priority queue as one element ───────────────────────────────────────

"""
    PriorityQueueModel

A source, a priority queue of several levels, a server and a sink.

The scheduling step assembled a priority queue from a classifier, two queues
and a scheduler. This one uses the element that *is* that assembly: the same
submodules, built and wired for you, and visible in the diagram because a
compound module's submodules are real modules in the network.
"""
@native_document struct PriorityQueueModel <: AbstractModel
    arrival_rate::Float64
    processing_time::Float64
    priorities::Int              # how many levels the queue has
    level_capacity::Int          # how many packets each level holds
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::APriorityQueueModel)   = network_module_count(m.network)
model_barrier_module(m::APriorityQueueModel) = network_barrier(m.network)
model_delay_edges(m::APriorityQueueModel)    = network_delay_edges(m.network)
model_topology(m::APriorityQueueModel)       = network_topology(m.network)

model_description(::Type{PriorityQueueModel}) =
    "A priority queue of several levels, as one element, between a source and a server."

model_parameter_space(::Type{PriorityQueueModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate,    20.0,  nothing, StructuralDOF),
    Parameter(:processing_time, 0.1,   nothing, StructuralDOF),
    Parameter(:priorities,      2,     nothing, StructuralDOF),
    Parameter(:level_capacity,  3,     nothing, StructuralDOF),
    Parameter(:time_limit,      100.0, nothing, StructuralDOF),
    Parameter(:seed,            42,    nothing, StochasticDOF),
])

function build_model(::Type{PriorityQueueModel}, r::AResolvedParameters)
    m = PriorityQueueModel(Float64(r[:arrival_rate]), Float64(r[:processing_time]),
                              Int(r[:priorities]), Int(r[:level_capacity]),
                              Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_priority_queue_network(m)
    m
end

function _build_priority_queue_network(m)
    network = Network(:PriorityQueue)
    source = _step_source(network, m)
    # One element, several submodules: `priority_queue` builds the classifier,
    # the levels and the scheduler, and registers them all in the network.
    # The levels REFUSE when full rather than dropping: a level that drops
    # accepts the packet first, and the classifier — which only moves on when an
    # output will not take a packet — would never reach the next level. Refusing
    # is what makes the overflow an overflow.
    queue = priority_queue(network, :queue, m.priorities;
        queue_parameters = (packet_capacity = m.level_capacity,))
    server = add_module!(network, PacketServerModule(:server;
        processing_time = m.processing_time))
    sink = _step_sink(network, :sink)
    connect!(source.out, queue.in)
    connect!(queue.out, server.in)
    connect!(server.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::APriorityQueueModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::APriorityQueueModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::APriorityQueueModel, recorder) = finalize_network!(m.network, recorder)

# ── Refusing rather than dropping ───────────────────────────────────────────

"""
    BackpressureFilterModel

A source, a queue, a server, a filter and a sink — with the filter set either
to drop what it will not pass on, or to refuse it.

Back pressure is only felt by a peer that asks *with a packet in hand*. A
server does: it will not start serving a packet it could not then deliver. So a
refusing filter stops the server, the queue fills, and nothing is lost; a
dropping one lets the whole chain run and throws the packets away at the end.
"""
@native_document struct BackpressureFilterModel <: AbstractModel
    arrival_rate::Float64
    processing_time::Float64
    backpressure::Bool           # refuse rather than drop
    pass_rate::Float64           # the share of packets the filter accepts
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::ABackpressureFilterModel)   = network_module_count(m.network)
model_barrier_module(m::ABackpressureFilterModel) = network_barrier(m.network)
model_delay_edges(m::ABackpressureFilterModel)    = network_delay_edges(m.network)
model_topology(m::ABackpressureFilterModel)       = network_topology(m.network)

model_description(::Type{BackpressureFilterModel}) =
    "A filter that refuses packets instead of dropping them, and the queue that fills behind it."

model_parameter_space(::Type{BackpressureFilterModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate,    10.0,  nothing, StructuralDOF),
    Parameter(:processing_time, 0.01,  nothing, StructuralDOF),
    Parameter(:backpressure,    true,  nothing, StructuralDOF),
    Parameter(:pass_rate,       0.0,   nothing, StructuralDOF),
    Parameter(:time_limit,      100.0, nothing, StructuralDOF),
    Parameter(:seed,            42,    nothing, StochasticDOF),
])

function build_model(::Type{BackpressureFilterModel}, r::AResolvedParameters)
    m = BackpressureFilterModel(Float64(r[:arrival_rate]), Float64(r[:processing_time]),
                                   Bool(r[:backpressure]), Float64(r[:pass_rate]),
                                   Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_backpressure_network(m)
    m
end

function _build_backpressure_network(m)
    network = Network(:Backpressure)
    source = _step_source(network, m)
    queue = add_module!(network, PacketQueueModule(:queue))
    server = add_module!(network, PacketServerModule(:server;
        processing_time = m.processing_time))
    # The filter's own generator decides which packets pass, so `pass_rate` is
    # a share of the traffic rather than a property of any one packet.
    rng = MersenneTwister(m.seed + 7)
    pass_rate = m.pass_rate
    filter = add_module!(network, PacketFilterModule(:filter;
        predicate = _ -> rand(rng) < pass_rate,
        backpressure = m.backpressure))
    sink = _step_sink(network, :sink)
    connect!(source.out, queue.in)
    connect!(queue.out, server.in)
    connect!(server.out, filter.in)
    connect!(filter.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::ABackpressureFilterModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::ABackpressureFilterModel,
                                  engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::ABackpressureFilterModel, recorder) =
    finalize_network!(m.network, recorder)
