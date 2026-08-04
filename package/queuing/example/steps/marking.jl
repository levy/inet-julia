# ────────────────────────────────────────────────────────────────────────────
# The models the "Labelling and copying" steps run.
#
# Both use elements that change a packet rather than route one: a labeler
# writes a value on it, a cloner makes copies of it, a duplicator sends some of
# them twice.
# ────────────────────────────────────────────────────────────────────────────

using InetQueuing: PacketLabelerModule, PacketLabelerParameters,
    PacketClonerModule, PacketDuplicatorModule, PacketDuplicatorParameters,
    ordinal_predicate, data_predicate

export LabelerModel, ClonerModel

"""
    LabelerModel

A source that says nothing about its packets, a labeler that writes a value on
each one, and a classifier that sorts them by it.

The content-based classifier step had a source that labelled its own packets.
This is the general case: the property a stream is sorted by is put there by an
element on the way, which is what you need when the traffic comes from
somewhere that does not know about your classification.
"""
@document struct LabelerModel <: AbstractModel
    arrival_rate::Float64
    labels::Int                  # how many different labels are written
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AbstractLabelerModel)   = network_module_count(m.network)
model_barrier_module(m::AbstractLabelerModel) = network_barrier(m.network)
model_delay_edges(m::AbstractLabelerModel)    = network_delay_edges(m.network)
model_topology(m::AbstractLabelerModel)       = network_topology(m.network)

model_description(::Type{LabelerModel}) =
    "A labeler that writes the value a classifier downstream sorts by."

model_parameter_space(::Type{LabelerModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate, 10.0,  nothing, StructuralDOF),
    Parameter(:labels,       2,     nothing, StructuralDOF),
    Parameter(:time_limit,   100.0, nothing, StructuralDOF),
    Parameter(:seed,         42,    nothing, StochasticDOF),
])

function build_model(::Type{LabelerModel}, r::AbstractResolvedParameters)
    m = LabelerModelMut(Float64(r[:arrival_rate]), Int(r[:labels]),
                        Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_labeler_network(m)
    m
end

function _build_labeler_network(m)
    network = Network(:Labeling)
    # The source writes nothing — the packets are plain.
    source = _step_source(network, m)
    labeler = add_module!(network, PacketLabelerModule(:labeler,
        PacketLabelerParameters(label = Volatile(intuniform(1, m.labels)));
        seed = m.seed + 1))
    # And the classifier sorts by exactly what the labeler wrote.
    predicates = Any[]
    for label in 1:(m.labels - 1)
        push!(predicates, data_predicate(==, label))
    end
    push!(predicates, _ -> true)
    fork = add_module!(network, content_based_classifier(:classifier, predicates))
    connect!(source.out, labeler.in)
    connect!(labeler.out, fork.in)
    for index in 1:m.labels
        sink = _step_sink(network, Symbol(:sink, index))
        connect!(fork.out[index], sink.in)
    end
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AbstractLabelerModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AbstractLabelerModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AbstractLabelerModel, recorder) = finalize_network!(m.network, recorder)

"""
    ClonerModel

A source, a cloner that sends a copy of every packet down each of two paths,
and a duplicator on one of them that sends some packets twice again.

Two ways of making more packets, side by side: one fans a stream out, the other
thickens it in place. The counts at the two sinks are what tells them apart.
"""
@document struct ClonerModel <: AbstractModel
    arrival_rate::Float64
    branches::Int                # how many copies the cloner makes
    duplicate_every::Int         # the duplicator sends every k-th packet twice
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AbstractClonerModel)   = network_module_count(m.network)
model_barrier_module(m::AbstractClonerModel) = network_barrier(m.network)
model_delay_edges(m::AbstractClonerModel)    = network_delay_edges(m.network)
model_topology(m::AbstractClonerModel)       = network_topology(m.network)

model_description(::Type{ClonerModel}) =
    "A cloner fanning a stream out, and a duplicator thickening one branch of it."

model_parameter_space(::Type{ClonerModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate,     10.0,  nothing, StructuralDOF),
    Parameter(:branches,         2,     nothing, StructuralDOF),
    Parameter(:duplicate_every,  2,     nothing, StructuralDOF),
    Parameter(:time_limit,       100.0, nothing, StructuralDOF),
    Parameter(:seed,             42,    nothing, StochasticDOF),
])

function build_model(::Type{ClonerModel}, r::AbstractResolvedParameters)
    m = ClonerModelMut(Float64(r[:arrival_rate]), Int(r[:branches]),
                       Int(r[:duplicate_every]), Float64(r[:time_limit]),
                       Int(r[:seed]), nothing)
    m.network = _build_cloner_network(m)
    m
end

function _build_cloner_network(m)
    network = Network(:Cloning)
    source = _step_source(network, m)
    cloner = add_module!(network, PacketClonerModule(:cloner, m.branches))
    connect!(source.out, cloner.in)
    # The first branch is thickened again; the rest go straight to a sink, so
    # the counts can be compared.
    every = m.duplicate_every
    duplicator = add_module!(network, PacketDuplicatorModule(:duplicator,
        PacketDuplicatorParameters(predicate = ordinal_predicate(n -> n % every == 0))))
    first_sink = _step_sink(network, :sink1)
    connect!(cloner.out[1], duplicator.in)
    connect!(duplicator.out, first_sink.in)
    for index in 2:m.branches
        sink = _step_sink(network, Symbol(:sink, index))
        connect!(cloner.out[index], sink.in)
    end
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AbstractClonerModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AbstractClonerModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AbstractClonerModel, recorder) = finalize_network!(m.network, recorder)
