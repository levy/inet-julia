# ────────────────────────────────────────────────────────────────────────────
# The models the "Classifying", "Scheduling" and "Filtering" steps run.
#
# All three are the same chain with one element swapped in, which is the point
# those steps make: a classifier forks it, a scheduler joins it again, and a
# filter thins it out — and nothing else in the chain has to know.
# ────────────────────────────────────────────────────────────────────────────

using InetQueuing: ActivePacketSourceModule,
    PassivePacketSinkModule, PacketQueueModule,
    PacketServerModule,
    PacketFilterModule,
    content_based_classifier, priority_classifier, priority_scheduler,
    weighted_round_robin_classifier, weighted_round_robin_scheduler, markov_classifier,
    PacketTemplate, packet_data, packet_predicate, check_packet_connections
using OmnetppSimulator.VolatileModule: Volatile, intuniform
using OmnetppSimulator: MersenneTwister
using InetQueuing: drop_at_end

export ContentBasedClassifierModel, PriorityQueueChainModel, FilterModel,
    SharedChainModel, NamedPolicyModel

# The three models below wire the same skeleton, so the pieces they share are
# built here rather than three times over.
_step_source(network, m; data = nothing) =
    add_module!(network, ActivePacketSourceModule(:source;
        production_interval = Volatile(exponential(1 / m.arrival_rate)),
        packet = PacketTemplate(length = Bytes(100), data = data),
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
@native_document struct ContentBasedClassifierModel <: AbstractModel
    arrival_rate::Float64        # packets per second
    classes::Int                 # how many values the source writes, and outputs
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AContentBasedClassifierModel)   = network_module_count(m.network)
model_barrier_module(m::AContentBasedClassifierModel) = network_barrier(m.network)
model_delay_edges(m::AContentBasedClassifierModel)    = network_delay_edges(m.network)
model_topology(m::AContentBasedClassifierModel)       = network_topology(m.network)

model_description(::Type{ContentBasedClassifierModel}) =
    "A classifier that reads the value written on each packet and forks the chain by it."

model_parameter_space(::Type{ContentBasedClassifierModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate, 10.0,  nothing, StructuralDOF),
    Parameter(:classes,      2,     nothing, StructuralDOF),
    Parameter(:time_limit,   100.0, nothing, StructuralDOF),
    Parameter(:seed,         42,    nothing, StochasticDOF),
])

function build_model(::Type{ContentBasedClassifierModel}, r::AResolvedParameters)
    m = ContentBasedClassifierModel(Float64(r[:arrival_rate]), Int(r[:classes]),
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

reset_model!(m::AContentBasedClassifierModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AContentBasedClassifierModel,
                                  engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AContentBasedClassifierModel, recorder) =
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
@native_document struct PriorityQueueChainModel <: AbstractModel
    arrival_rate::Float64
    processing_time::Float64     # seconds one packet takes to serve
    first_capacity::Int          # how many the high-priority queue holds
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::APriorityQueueChainModel)   = network_module_count(m.network)
model_barrier_module(m::APriorityQueueChainModel) = network_barrier(m.network)
model_delay_edges(m::APriorityQueueChainModel)    = network_delay_edges(m.network)
model_topology(m::APriorityQueueChainModel)       = network_topology(m.network)

model_description(::Type{PriorityQueueChainModel}) =
    "A classifier, two queues and a scheduler: a priority queue built from the parts."

model_parameter_space(::Type{PriorityQueueChainModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate,    20.0,  nothing, StructuralDOF),
    Parameter(:processing_time, 0.1,   nothing, StructuralDOF),
    Parameter(:first_capacity,  2,     nothing, StructuralDOF),
    Parameter(:time_limit,      100.0, nothing, StructuralDOF),
    Parameter(:seed,            42,    nothing, StochasticDOF),
])

function build_model(::Type{PriorityQueueChainModel}, r::AResolvedParameters)
    m = PriorityQueueChainModel(Float64(r[:arrival_rate]), Float64(r[:processing_time]),
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
    first = add_module!(network, PacketQueueModule(:first;
        packet_capacity = m.first_capacity))
    second = add_module!(network, PacketQueueModule(:second))
    join = add_module!(network, priority_scheduler(:scheduler, 2))
    server = add_module!(network, PacketServerModule(:server;
        processing_time = m.processing_time))
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

reset_model!(m::APriorityQueueChainModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::APriorityQueueChainModel,
                                  engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::APriorityQueueChainModel, recorder) =
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
@native_document struct FilterModel <: AbstractModel
    arrival_rate::Float64
    classes::Int                 # values the source writes
    keep::Int                    # the one value that gets through
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AFilterModel)   = network_module_count(m.network)
model_barrier_module(m::AFilterModel) = network_barrier(m.network)
model_delay_edges(m::AFilterModel)    = network_delay_edges(m.network)
model_topology(m::AFilterModel)       = network_topology(m.network)

model_description(::Type{FilterModel}) =
    "A filter that passes on only the packets whose value it is looking for."

model_parameter_space(::Type{FilterModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate, 10.0,  nothing, StructuralDOF),
    Parameter(:classes,      4,     nothing, StructuralDOF),
    Parameter(:keep,         1,     nothing, StructuralDOF),
    Parameter(:time_limit,   100.0, nothing, StructuralDOF),
    Parameter(:seed,         42,    nothing, StochasticDOF),
])

function build_model(::Type{FilterModel}, r::AResolvedParameters)
    m = FilterModel(Float64(r[:arrival_rate]), Int(r[:classes]), Int(r[:keep]),
                       Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_filter_network(m)
    m
end

function _build_filter_network(m)
    network = Network(:Filter)
    source = _step_source(network, m; data = Volatile(intuniform(1, m.classes)))
    keep = m.keep
    filter = add_module!(network, PacketFilterModule(:filter;
        predicate = packet -> packet_data(packet) == keep))
    sink = _step_sink(network, :sink)
    connect!(source.out, filter.in)
    connect!(filter.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AFilterModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AFilterModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AFilterModel, recorder) = finalize_network!(m.network, recorder)

# ── Sharing a chain out ─────────────────────────────────────────────────────

"""
    SharedChainModel

One source, one server, and two sinks that have to share what the server can
manage — with the policy that decides the share as a parameter.

`policy` picks how the chain is split: `:priority` fills the first queue and
overflows into the second, `:round_robin` alternates by weight, and `:markov`
walks a state machine, which gives the same long-run shares in bursts. The
network is otherwise identical, so what changes between runs is only the
policy.
"""
@native_document struct SharedChainModel <: AbstractModel
    arrival_rate::Float64
    processing_time::Float64
    policy::Symbol               # :priority | :round_robin | :markov
    first_weight::Int            # the first output's share, under :round_robin
    second_weight::Int
    stickiness::Float64          # how often :markov stays where it is
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::ASharedChainModel)   = network_module_count(m.network)
model_barrier_module(m::ASharedChainModel) = network_barrier(m.network)
model_delay_edges(m::ASharedChainModel)    = network_delay_edges(m.network)
model_topology(m::ASharedChainModel)       = network_topology(m.network)

model_description(::Type{SharedChainModel}) =
    "Two queues sharing one server, with the sharing policy as a parameter."

model_parameter_space(::Type{SharedChainModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate,    20.0,          nothing, StructuralDOF),
    Parameter(:processing_time, 0.1,           nothing, StructuralDOF),
    Parameter(:policy,          :round_robin,  nothing, StructuralDOF),
    Parameter(:first_weight,    3,             nothing, StructuralDOF),
    Parameter(:second_weight,   1,             nothing, StructuralDOF),
    Parameter(:stickiness,      0.9,           nothing, StructuralDOF),
    Parameter(:time_limit,      100.0,         nothing, StructuralDOF),
    Parameter(:seed,            42,            nothing, StochasticDOF),
])

function build_model(::Type{SharedChainModel}, r::AResolvedParameters)
    m = SharedChainModel(Float64(r[:arrival_rate]), Float64(r[:processing_time]),
                            Symbol(r[:policy]), Int(r[:first_weight]),
                            Int(r[:second_weight]), Float64(r[:stickiness]),
                            Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_shared_chain_network(m)
    m
end

# The fork the chosen policy asks for. All three answer the same question —
# which output does this packet leave by — and none of them is a different
# element.
function _shared_chain_classifier(m)
    weights = Int[m.first_weight, m.second_weight]
    m.policy === :round_robin && return weighted_round_robin_classifier(:classifier, weights)
    if m.policy === :markov
        stay = m.stickiness
        leave = 1.0 - stay
        return markov_classifier(:classifier, [[stay, leave], [leave, stay]];
                                 seed = m.seed + 3)
    end
    m.policy === :priority ||
        error("SharedChainModel: policy must be :priority, :round_robin or :markov, got ",
              m.policy)
    priority_classifier(:classifier, 2)
end

# What the queues behind the fork look like, which is not the same question for
# every policy.
#
# A priority classifier ASKS whether an output will take the packet, so its
# queues need a capacity to refuse at — refusing is the whole mechanism, and
# that is what sends the overflow to the second queue.
#
# A share-based classifier does not ask: it is told which output to use, and
# pushing into a full queue that cannot refuse is an error, not a policy. So
# its queues are unbounded, and the share the classifier hands out is exactly
# the share each queue receives.
_shared_chain_queue_parameters(m) =
    m.policy === :priority ? (packet_capacity = 10,) : (;)

function _build_shared_chain_network(m)
    network = Network(:Shared)
    source = _step_source(network, m)
    fork = add_module!(network, _shared_chain_classifier(m))
    parameters = _shared_chain_queue_parameters(m)
    first = add_module!(network, PacketQueueModule(:first; parameters...))
    second = add_module!(network, PacketQueueModule(:second; parameters...))
    join = add_module!(network, weighted_round_robin_scheduler(:scheduler,
        Int[m.first_weight, m.second_weight]))
    server = add_module!(network, PacketServerModule(:server;
        processing_time = m.processing_time))
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

reset_model!(m::ASharedChainModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::ASharedChainModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::ASharedChainModel, recorder) = finalize_network!(m.network, recorder)

# ── Naming a policy instead of writing it ───────────────────────────────────

"""
    NamedPolicyModel

A source, a filter and a sink, with the filter's rule chosen **by name**.

A step file is JSON, and JSON cannot hold a function. So a configuration names
a registered policy and its argument — `data_equals` with `3`, `every_nth` with
`4` — and the model builds the predicate from the pair. That is this library's
answer to INET's `classifierClass = "inet::…"`: a name still selects a policy,
but what it names is a function anyone can register rather than a class.
"""
@native_document struct NamedPolicyModel <: AbstractModel
    arrival_rate::Float64
    classes::Int                 # values the source writes
    policy::Symbol               # the registered predicate to use
    argument::Any                # its parameter
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::ANamedPolicyModel)   = network_module_count(m.network)
model_barrier_module(m::ANamedPolicyModel) = network_barrier(m.network)
model_delay_edges(m::ANamedPolicyModel)    = network_delay_edges(m.network)
model_topology(m::ANamedPolicyModel)       = network_topology(m.network)

model_description(::Type{NamedPolicyModel}) =
    "A filter whose rule is chosen by name from the registered policies."

model_parameter_space(::Type{NamedPolicyModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate, 10.0,          nothing, StructuralDOF),
    Parameter(:classes,      4,             nothing, StructuralDOF),
    Parameter(:policy,       :data_equals,  nothing, StructuralDOF),
    Parameter(:argument,     1,             nothing, StructuralDOF),
    Parameter(:time_limit,   100.0,         nothing, StructuralDOF),
    Parameter(:seed,         42,            nothing, StochasticDOF),
])

function build_model(::Type{NamedPolicyModel}, r::AResolvedParameters)
    m = NamedPolicyModel(Float64(r[:arrival_rate]), Int(r[:classes]),
                            Symbol(r[:policy]), r[:argument],
                            Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_named_policy_network(m)
    m
end

function _build_named_policy_network(m)
    network = Network(:NamedPolicy)
    source = _step_source(network, m; data = Volatile(intuniform(1, m.classes)))
    # The name and its argument come from the step file; the predicate is built
    # here, and an unregistered name fails loudly rather than passing nothing on.
    predicate = packet_predicate(m.policy, m.argument)
    filter = add_module!(network, PacketFilterModule(:filter; predicate = predicate))
    sink = _step_sink(network, :sink)
    connect!(source.out, filter.in)
    connect!(filter.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::ANamedPolicyModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::ANamedPolicyModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::ANamedPolicyModel, recorder) = finalize_network!(m.network, recorder)
