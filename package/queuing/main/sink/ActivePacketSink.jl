"""
    ActivePacketSinkElement

**A sink that pulls**: every collection interval it takes a packet from
whatever is connected to its input, counts it and lets it go.

It is the driver of its connection, so it is also the one left waiting. When
the interval elapses and the provider has nothing, the sink does not set a new
timer: it stops, and waits to be told there is something to pull again.
"""
module ActivePacketSinkElement

using OmnetppSimulator: SimTime, seconds, to_simtime, MersenneTwister, NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network, input_gate, module_id
using OmnetppSimulator.TimerModule: TimerHandle, is_scheduled, schedule_timer!
using OmnetppSimulator.VolatileModule: evaluate
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, resolve_interface
using ..PacketProtocolModule: PacketProtocolModule, ActivePacketSink, PassivePacketSource,
    can_pull_some_packet, pull_packet!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    emit_time_statistic!, record_statistic!
using ..PacketSourceModule: packet_creation_time

export ActivePacketSinkParameters, ActivePacketSinkStates,
       ActivePacketSinkStatistics, ActivePacketSinkModule

"""
    ActivePacketSinkParameters(; collection_interval, initial_collection_offset = -1.0)

How often the sink collects, and when it starts. A negative offset — the
default — means it collects its first packet as the simulation starts.
"""
struct ActivePacketSinkParameters
    collection_interval::Any
    initial_collection_offset::Float64
end

ActivePacketSinkParameters(; collection_interval,
                           initial_collection_offset::Real = -1.0) =
    ActivePacketSinkParameters(collection_interval, Float64(initial_collection_offset))

mutable struct ActivePacketSinkStates
    rng::MersenneTwister
    seed::Int
    timer::TimerHandle
    offset_scheduled::Bool
end

ActivePacketSinkStates(seed::Int) =
    ActivePacketSinkStates(MersenneTwister(seed), seed, TimerHandle(), false)

reset_states!(states::ActivePacketSinkStates) =
    (states.rng = MersenneTwister(states.seed); states.timer = TimerHandle();
     states.offset_scheduled = false; states)

mutable struct ActivePacketSinkStatistics
    recording::ModuleStatistics
    num_packets::Int
    total_length::Int          # bits
    total_life_time::SimTime
end

ActivePacketSinkStatistics() = ActivePacketSinkStatistics(ModuleStatistics(), 0, 0, SimTime(0))

reset_statistics!(statistics::ActivePacketSinkStatistics) =
    (statistics.num_packets = 0; statistics.total_length = 0;
     statistics.total_life_time = SimTime(0); statistics)

const STATISTIC_NAMES = (:packetLengths, :packetLifeTime)

mutable struct ActivePacketSinkModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    parameters::ActivePacketSinkParameters
    states::ActivePacketSinkStates
    statistics::ActivePacketSinkStatistics
    provider::ModuleRef
end

function ActivePacketSinkModule(name::Symbol, parameters::ActivePacketSinkParameters;
                                seed::Int = 0)
    m = ActivePacketSinkModule(
        name, 0,
        input_gate(nothing, :in; annotations = Any[InterfaceClaim(ActivePacketSink)]),
        parameters, ActivePacketSinkStates(seed), ActivePacketSinkStatistics(),
        NO_MODULE_REF)
    m.in.owner = m
    m
end

function NetworkModule.initialize_module!(::Network, m::ActivePacketSinkModule)
    m.provider = resolve_interface(m.in, PassivePacketSource)
    m
end

NetworkModule.register_module_statistics!(m::ActivePacketSinkModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_starts(::ActivePacketSinkModule) = true

NetworkModule.start_module!(ctx, m::ActivePacketSinkModule) =
    (_schedule_and_collect!(ctx, m); m)

NetworkModule.module_icon(::ActivePacketSinkModule) = "block/sink"

NetworkModule.reset_module!(m::ActivePacketSinkModule) =
    (reset_states!(m.states); reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::ActivePacketSinkModule, ::Any)
    statistics = m.statistics
    record_statistic!(statistics.recording, "packets:count", statistics.num_packets)
    record_statistic!(statistics.recording, "packetLengths:sum", statistics.total_length)
    statistics.num_packets == 0 && return nothing
    record_statistic!(statistics.recording, "packetLifeTime:mean",
                      seconds(statistics.total_life_time / statistics.num_packets))
    nothing
end

# Told there may be something to pull. Only acted on while stopped: with a timer
# outstanding the interval has not elapsed, and collecting now would be sooner
# than the interval allows.
function PacketProtocolModule.handle_can_pull_packet_changed!(ctx, m::ActivePacketSinkModule,
                                                              ::Gate)
    is_scheduled(m.states.timer) || _schedule_and_collect!(ctx, m)
    nothing
end

function _schedule_and_collect!(ctx, m::ActivePacketSinkModule)
    parameters, states = m.parameters, m.states
    if !states.offset_scheduled && parameters.initial_collection_offset >= 0
        _schedule_collection!(ctx, m, to_simtime(parameters.initial_collection_offset))
        states.offset_scheduled = true
    elseif can_pull_some_packet(m.provider)
        _schedule_collection!(ctx, m, to_simtime(evaluate(parameters.collection_interval, states.rng)))
        _collect_packet!(ctx, m)
    end
    # Otherwise the provider is empty: no packet, and no timer, until it says
    # there is something to pull.
    nothing
end

_schedule_collection!(ctx, m::ActivePacketSinkModule, delay::SimTime) =
    schedule_timer!(ctx, delay, m.module_id, m.states.timer, c -> _schedule_and_collect!(c, m))

function _collect_packet!(ctx, m::ActivePacketSinkModule)
    packet = pull_packet!(ctx, m.provider)
    statistics = m.statistics
    length = bits(data_length(packet))
    statistics.num_packets += 1
    statistics.total_length += length
    emit_statistic!(statistics.recording, ctx, :packetLengths, length)
    created = packet_creation_time(packet)
    if created !== nothing
        life_time = ctx.timestamp - created
        statistics.total_life_time += life_time
        emit_time_statistic!(statistics.recording, ctx, :packetLifeTime, life_time)
    end
    nothing
end

end # module
