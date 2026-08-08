# ────────────────────────────────────────────────────────────────────────────
# The models the "Generic elements" steps run: a delayer, a multiplexer and a
# demultiplexer.
#
# None of the three decides anything about a packet. They are the plumbing a
# network is assembled with — hold a packet, join chains, split one — and each
# step is about the shape of the network rather than about the packets in it.
# ────────────────────────────────────────────────────────────────────────────

using InetQueuing: PacketDelayerModule, PacketDelayerParameters,
    PacketMultiplexerModule, PacketDemultiplexerModule,
    PassivePacketSourceModule, PassivePacketSourceParameters,
    ActivePacketSinkModule, ActivePacketSinkParameters

export DelayerModel, MultiplexerModel, DemultiplexerModel

# ── Delaying ────────────────────────────────────────────────────────────────

"""
    DelayerModel

A source, a delayer and a sink: every packet is held for a while on the way.

With a fixed delay the packets come out in the order they went in, just later.
With a random one they can overtake each other — which is what a path whose
delay varies does to a stream, and why the later link-layer steps care.
"""
@document struct DelayerModel <: AbstractModel
    arrival_rate::Float64
    delay::Float64               # seconds each packet is held (mean, when random)
    random_delay::Bool
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AbstractDelayerModel)   = network_module_count(m.network)
model_barrier_module(m::AbstractDelayerModel) = network_barrier(m.network)
model_delay_edges(m::AbstractDelayerModel)    = network_delay_edges(m.network)
model_topology(m::AbstractDelayerModel)       = network_topology(m.network)

model_description(::Type{DelayerModel}) =
    "A delayer that holds every packet for a while on its way from source to sink."

model_parameter_space(::Type{DelayerModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate, 10.0,  nothing, StructuralDOF),
    Parameter(:delay,        0.5,   nothing, StructuralDOF),
    Parameter(:random_delay, false, nothing, StructuralDOF),
    Parameter(:time_limit,   100.0, nothing, StructuralDOF),
    Parameter(:seed,         42,    nothing, StochasticDOF),
])

function build_model(::Type{DelayerModel}, r::AbstractResolvedParameters)
    m = DelayerModelMut(Float64(r[:arrival_rate]), Float64(r[:delay]),
                        Bool(r[:random_delay]), Float64(r[:time_limit]),
                        Int(r[:seed]), nothing)
    m.network = _build_delayer_network(m)
    m
end

function _build_delayer_network(m)
    network = Network(:Delayer)
    source = _step_source(network, m)
    delay = m.random_delay ? Volatile(exponential(m.delay)) : m.delay
    delayer = add_module!(network, PacketDelayerModule(:delayer,
        PacketDelayerParameters(delay = delay); seed = m.seed + 1))
    sink = _step_sink(network, :sink)
    connect!(source.out, delayer.in)
    connect!(delayer.out, sink.in)
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AbstractDelayerModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AbstractDelayerModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AbstractDelayerModel, recorder) = finalize_network!(m.network, recorder)

# ── Joining ─────────────────────────────────────────────────────────────────

"""
    MultiplexerModel

Several sources pushing into one sink through a multiplexer.

A multiplexer holds nothing and decides nothing: it forwards what arrives on
any input to its one output, so the sink sees one stream made of several. It is
what lets a chain be fed from more than one place without the chain knowing.
"""
@document struct MultiplexerModel <: AbstractModel
    arrival_rate::Float64        # per source
    sources::Int
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AbstractMultiplexerModel)   = network_module_count(m.network)
model_barrier_module(m::AbstractMultiplexerModel) = network_barrier(m.network)
model_delay_edges(m::AbstractMultiplexerModel)    = network_delay_edges(m.network)
model_topology(m::AbstractMultiplexerModel)       = network_topology(m.network)

model_description(::Type{MultiplexerModel}) =
    "Several sources feeding one sink through a multiplexer."

model_parameter_space(::Type{MultiplexerModel}) = ParameterSpace(Parameter[
    Parameter(:arrival_rate, 5.0,   nothing, StructuralDOF),
    Parameter(:sources,      3,     nothing, StructuralDOF),
    Parameter(:time_limit,   100.0, nothing, StructuralDOF),
    Parameter(:seed,         42,    nothing, StochasticDOF),
])

function build_model(::Type{MultiplexerModel}, r::AbstractResolvedParameters)
    m = MultiplexerModelMut(Float64(r[:arrival_rate]), Int(r[:sources]),
                            Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_multiplexer_network(m)
    m
end

function _build_multiplexer_network(m)
    network = Network(:Multiplexer)
    join = add_module!(network, PacketMultiplexerModule(:multiplexer, m.sources))
    sink = _step_sink(network, :sink)
    connect!(join.out, sink.in)
    # Each source gets its own seed, or they would all produce the same stream.
    for index in 1:m.sources
        source = add_module!(network, ActivePacketSourceModule(Symbol(:source, index);
            production_interval = Volatile(exponential(1 / m.arrival_rate)),
            packet = PacketTemplate(length = Bytes(100)),
            seed = m.seed + index))
        connect!(source.out, join.in[index])
    end
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AbstractMultiplexerModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AbstractMultiplexerModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AbstractMultiplexerModel, recorder) = finalize_network!(m.network, recorder)

# ── Splitting ───────────────────────────────────────────────────────────────

"""
    DemultiplexerModel

Several sinks pulling from one source through a demultiplexer.

The multiplexer's mirror, and it works in the other direction: a multiplexer
joins several *pushing* chains, a demultiplexer lets several *pulling* ones
share one provider. Whichever sink asks first gets the packet — so where a
packet goes says something about the collectors' timing, not about the packet.
That is what separates it from a classifier, which reads the packet and
chooses.
"""
@document struct DemultiplexerModel <: AbstractModel
    collection_interval::Float64   # seconds between collections, per sink
    sinks::Int
    time_limit::Float64
    seed::Int
    network::Any
end

model_module_count(m::AbstractDemultiplexerModel)   = network_module_count(m.network)
model_barrier_module(m::AbstractDemultiplexerModel) = network_barrier(m.network)
model_delay_edges(m::AbstractDemultiplexerModel)    = network_delay_edges(m.network)
model_topology(m::AbstractDemultiplexerModel)       = network_topology(m.network)

model_description(::Type{DemultiplexerModel}) =
    "Several sinks pulling from one source through a demultiplexer."

model_parameter_space(::Type{DemultiplexerModel}) = ParameterSpace(Parameter[
    Parameter(:collection_interval, 0.2,   nothing, StructuralDOF),
    Parameter(:sinks,               2,     nothing, StructuralDOF),
    Parameter(:time_limit,          100.0, nothing, StructuralDOF),
    Parameter(:seed,                42,    nothing, StochasticDOF),
])

function build_model(::Type{DemultiplexerModel}, r::AbstractResolvedParameters)
    m = DemultiplexerModelMut(Float64(r[:collection_interval]), Int(r[:sinks]),
                              Float64(r[:time_limit]), Int(r[:seed]), nothing)
    m.network = _build_demultiplexer_network(m)
    m
end

function _build_demultiplexer_network(m)
    network = Network(:Demultiplexer)
    # A demultiplexer sits on the PULL side: one provider, several collectors.
    source = add_module!(network, PassivePacketSourceModule(:source,
        PassivePacketSourceParameters(packet = PacketTemplate(length = Bytes(100)));
        seed = m.seed))
    fork = add_module!(network, PacketDemultiplexerModule(:demultiplexer, m.sinks))
    connect!(source.out, fork.in)
    # Each sink collects on its own clock, so which one gets a given packet is
    # decided by who asks first.
    for index in 1:m.sinks
        sink = add_module!(network, ActivePacketSinkModule(Symbol(:sink, index),
            ActivePacketSinkParameters(collection_interval = m.collection_interval);
            seed = m.seed + index))
        connect!(fork.out[index], sink.in)
    end
    initialize_network!(network)
    check_packet_connections(network)
    network
end

reset_model!(m::AbstractDemultiplexerModel) = (reset_network!(m.network); m)

function schedule_initial_events!(m::AbstractDemultiplexerModel, engine::AbstractEngine, recorder)
    register_network_statistics!(m.network, recorder)
    start_network!(engine, m.network)
    schedule_root!(engine, to_simtime(m.time_limit), model_barrier_module(m),
                   ctx -> stop!(ctx.sim, SimTimeLimit))
    engine
end

finalize_model!(m::AbstractDemultiplexerModel, recorder) = finalize_network!(m.network, recorder)
