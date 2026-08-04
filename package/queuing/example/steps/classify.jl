# ────────────────────────────────────────────────────────────────────────────
# The models the "Classifying", "Scheduling" and "Filtering" steps run.
#
# All three are the same chain with one element swapped in, which is the point
# those steps make: a classifier forks it, a scheduler joins it again, and a
# filter thins it out — and nothing else in the chain has to know.
# ────────────────────────────────────────────────────────────────────────────

using InetQueuing: ActivePacketSourceModule, ActivePacketSourceParameters,
    PassivePacketSinkModule, PacketQueueModule, PacketQueueParameters,
    PacketServerModule, PacketServerParameters,
    PacketFilterModule, PacketFilterParameters,
    content_based_classifier, priority_classifier, priority_scheduler,
    PacketTemplate, packet_data, check_packet_connections
using OmnetppSimulator.VolatileModule: Volatile, intuniform

export ContentBasedClassifierModel, PriorityQueueChainModel, FilterModel

# The three models below wire the same skeleton, so the pieces they share are
# built here rather than three times over.
_step_source(network, m; data = nothing) =
    add_module!(network, ActivePacketSourceModule(:source,
        ActivePacketSourceParameters(
            production_interval = Volatile(exponential(1 / m.arrival_rate)),
            packet = PacketTemplate(length = Bytes(100), data = data));
        seed = m.seed))

_step_sink(network, name::Symbol) = add_module!(network, PassivePacketSinkModule(name))

# ── Classifying ─────────────────────────────────────────────────────────────

"""
    ContentBasedClassifierModel

A source whose packets carry a value, a classifier that reads it, and one sink
per class.

This is the first step where a packet is more than its length: the source
writes a number on each one, and the classifier's predicates are what decide
where it goes. Everything downstream of the fork sees only its own share.
"""
@document struct ContentBasedClassifierModel <: AbstractModel
    arrival_rate::Float64        # packets per second
    classes::Int                 # how many values the source writes, and outputs
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AbstractContentBasedClassifierModel)   = network_module_count(m.network)
model_barrier_module(m::AbstractContentBasedClassifierModel) = network_barrier(m.network)
model_delay_edges(m::AbstractContentBasedClassifierModel)    = network_delay_edges(m.network)
model_topology(m::AbstractContentBasedClassifierModel)       = network_topology(m.network)

model_description(::Type{ContentBasedClassifierModel}) =
    "A classifier that reads the value written on each packet and forks the chain by it."

model_parameter_space(::Type{ContentBasedClassifierModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate, 10.0,  nothing, StructuralDOF),
    Parameter(:classes,      2,     nothing, StructuralDOF),
    Parameter(:time_limit,   100.0, nothing, StructuralDOF),
    Parameter(:seed,         42,    nothing, StochasticDOF),
])

function build_model(::Type{ContentBasedClassifierModel}, r::AbstractResolvedParameters)
    m = ContentBasedClassifierModelMut(Float64(r[:arrival_rate]), Int(r[:classes]),
                                       Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_content_classifier_network(m)
    m
end

# The predicate for one class, as a function of its own so the class it looks
# for is captured once rather than shared by every predicate.
_class_predicate(class::Int) = packet -> packet_data(packet) == class

function _build_content_classifier_network(m)
    network = Network(:ContentClassifier)
    # Each packet gets a class written on it, drawn uniformly.
    source = _step_source(network, m; data = Volatile(intuniform(1, m.classes)))
    # One predicate per output, reading the value back off the packet. The last
    # one takes everything that is left, so no packet is ever unplaceable.
    predicates = Any[]
    for class in 1:(m.classes - 1)
        push!(predicates, _class_predicate(class))
    end
    push!(predicates, _ -> true)
    fork = add_module!(network, content_based_classifier(:classifier, predicates))
    connect!(source.out, fork.in)
    for index in 1:m.classes
        sink = _step_sink(network, Symbol(:sink, index))
        connect!(fork.out[index], sink.in)
    end
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AbstractContentBasedClassifierModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AbstractContentBasedClassifierModel,
                                  engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AbstractContentBasedClassifierModel, recorder) =
    finalize_network!(m.network, recorder)

# ── Scheduling ──────────────────────────────────────────────────────────────

"""
    PriorityQueueChainModel

A priority queue assembled from parts: a classifier fans packets into a queue
each, a scheduler drains them in order, and one server takes them away.

The first queue is small, so the classifier has to use the second once it is
full — and the scheduler always empties the first before touching the second.
Together that is what "priority" means here, and nothing in the chain had to be
told about priorities.
"""
@document struct PriorityQueueChainModel <: AbstractModel
    arrival_rate::Float64
    processing_time::Float64     # seconds one packet takes to serve
    first_capacity::Int          # how many the high-priority queue holds
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AbstractPriorityQueueChainModel)   = network_module_count(m.network)
model_barrier_module(m::AbstractPriorityQueueChainModel) = network_barrier(m.network)
model_delay_edges(m::AbstractPriorityQueueChainModel)    = network_delay_edges(m.network)
model_topology(m::AbstractPriorityQueueChainModel)       = network_topology(m.network)

model_description(::Type{PriorityQueueChainModel}) =
    "A classifier, two queues and a scheduler: a priority queue built from the parts."

model_parameter_space(::Type{PriorityQueueChainModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate,    20.0,  nothing, StructuralDOF),
    Parameter(:processing_time, 0.1,   nothing, StructuralDOF),
    Parameter(:first_capacity,  2,     nothing, StructuralDOF),
    Parameter(:time_limit,      100.0, nothing, StructuralDOF),
    Parameter(:seed,            42,    nothing, StochasticDOF),
])

function build_model(::Type{PriorityQueueChainModel}, r::AbstractResolvedParameters)
    m = PriorityQueueChainModelMut(Float64(r[:arrival_rate]), Float64(r[:processing_time]),
                                   Int(r[:first_capacity]), Float64(r[:time_limit]),
                                   Int(r[:seed]), nothing)
    m.network = _build_priority_chain_network(m)
    m
end

function _build_priority_chain_network(m)
    network = Network(:Priority)
    source = _step_source(network, m)
    # A priority classifier sends each packet to the first output that will
    # take it, so the small queue is preferred until it is full.
    fork = add_module!(network, priority_classifier(:classifier, 2))
    first = add_module!(network, PacketQueueModule(:first,
        PacketQueueParameters(packet_capacity = m.first_capacity)))
    second = add_module!(network, PacketQueueModule(:second))
    join = add_module!(network, priority_scheduler(:scheduler, 2))
    server = add_module!(network, PacketServerModule(:server,
        PacketServerParameters(processing_time = m.processing_time)))
    sink = _step_sink(network, :sink)
    connect!(source.out, fork.in)
    connect!(fork.out[1], first.in)
    connect!(fork.out[2], second.in)
    connect!(first.out, join.in[1])
    connect!(second.out, join.in[2])
    connect!(join.out, server.in)
    connect!(server.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AbstractPriorityQueueChainModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AbstractPriorityQueueChainModel,
                                  engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AbstractPriorityQueueChainModel, recorder) =
    finalize_network!(m.network, recorder)

# ── Filtering ───────────────────────────────────────────────────────────────

"""
    FilterModel

A source, a filter and a sink: only the packets the predicate accepts get
through, and the rest are dropped where they stand.

The predicate reads the value the source wrote, so which packets survive is a
property of the packets rather than of the wiring — the same filter with a
different predicate is a different step.
"""
@document struct FilterModel <: AbstractModel
    arrival_rate::Float64
    classes::Int                 # values the source writes
    keep::Int                    # the one value that gets through
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AbstractFilterModel)   = network_module_count(m.network)
model_barrier_module(m::AbstractFilterModel) = network_barrier(m.network)
model_delay_edges(m::AbstractFilterModel)    = network_delay_edges(m.network)
model_topology(m::AbstractFilterModel)       = network_topology(m.network)

model_description(::Type{FilterModel}) =
    "A filter that passes on only the packets whose value it is looking for."

model_parameter_space(::Type{FilterModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate, 10.0,  nothing, StructuralDOF),
    Parameter(:classes,      4,     nothing, StructuralDOF),
    Parameter(:keep,         1,     nothing, StructuralDOF),
    Parameter(:time_limit,   100.0, nothing, StructuralDOF),
    Parameter(:seed,         42,    nothing, StochasticDOF),
])

function build_model(::Type{FilterModel}, r::AbstractResolvedParameters)
    m = FilterModelMut(Float64(r[:arrival_rate]), Int(r[:classes]), Int(r[:keep]),
                       Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_filter_network(m)
    m
end

function _build_filter_network(m)
    network = Network(:Filter)
    source = _step_source(network, m; data = Volatile(intuniform(1, m.classes)))
    keep = m.keep
    filter = add_module!(network, PacketFilterModule(:filter,
        PacketFilterParameters(predicate = packet -> packet_data(packet) == keep)))
    sink = _step_sink(network, :sink)
    connect!(source.out, filter.in)
    connect!(filter.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AbstractFilterModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AbstractFilterModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AbstractFilterModel, recorder) = finalize_network!(m.network, recorder)
