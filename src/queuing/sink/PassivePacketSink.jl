"""
    PassivePacketSinkElement

**A sink that is pushed into**: it counts what arrives and lets it go.

This is where a modelled packet's life ends. The sink accepts whatever is
pushed at it and, unless it is given a consumption interval, always has room —
which is what makes it the neutral end of a chain, measuring what reached it
without shaping what came before.

With a consumption interval it becomes a rate limit instead: after each packet
it refuses until the interval has passed, and then tells its producer that
pushing is possible again. A producer wired to it feels that as back pressure.
"""
module PassivePacketSinkElement

using OmnetppSimulator: SimTime, TIME_UNIT, to_simtime, MersenneTwister, NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network, input_gate, module_id
using OmnetppSimulator.TimerModule: TimerHandle, is_scheduled, schedule_timer!
using OmnetppSimulator.VolatileModule: evaluate
using ..PacketModule: Packet, bits, data_length
using ..LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, ActivePacketSource,
    handle_can_push_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    emit_time_statistic!, record_statistic!
using ..PacketSourceModule: packet_creation_time

export PassivePacketSinkParameters, PassivePacketSinkStates,
       PassivePacketSinkStatistics, PassivePacketSinkModule

"""
    PassivePacketSinkParameters(; consumption_interval = 0.0, initial_consumption_offset = 0.0)

How fast the sink is willing to consume. The default, zero, means no limit: any
number of packets may arrive at the same instant. A non-zero interval — usually
[`Volatile`](@ref) — makes the sink refuse until that much time has passed since
the last packet.
"""
struct PassivePacketSinkParameters
    consumption_interval::Any
    initial_consumption_offset::Float64
end

PassivePacketSinkParameters(; consumption_interval = 0.0,
                            initial_consumption_offset::Real = 0.0) =
    PassivePacketSinkParameters(consumption_interval, Float64(initial_consumption_offset))

mutable struct PassivePacketSinkStates
    rng::MersenneTwister
    seed::Int
    timer::TimerHandle
end

PassivePacketSinkStates(seed::Int) =
    PassivePacketSinkStates(MersenneTwister(seed), seed, TimerHandle())

reset_states!(states::PassivePacketSinkStates) =
    (states.rng = MersenneTwister(states.seed); states.timer = TimerHandle(); states)

"""
    PassivePacketSinkStatistics()

What reached the sink: how many packets, how much data, and how long they took
to get here. Lifetime comes from the creation time the source stamped on each
packet, and is the end-to-end delay of the chain.
"""
mutable struct PassivePacketSinkStatistics
    recording::ModuleStatistics
    num_packets::Int
    total_length::Int          # bits
    total_life_time::SimTime
end

PassivePacketSinkStatistics() =
    PassivePacketSinkStatistics(ModuleStatistics(), 0, 0, SimTime(0))

reset_statistics!(statistics::PassivePacketSinkStatistics) =
    (statistics.num_packets = 0; statistics.total_length = 0;
     statistics.total_life_time = SimTime(0); statistics)

const STATISTIC_NAMES = (:packetLengths, :packetLifeTime)

mutable struct PassivePacketSinkModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    parameters::PassivePacketSinkParameters
    states::PassivePacketSinkStates
    statistics::PassivePacketSinkStatistics
    producer::ModuleRef
end

function PassivePacketSinkModule(name::Symbol,
                                 parameters::PassivePacketSinkParameters = PassivePacketSinkParameters();
                                 seed::Int = 0)
    m = PassivePacketSinkModule(
        name, 0,
        input_gate(nothing, :in; annotations = Any[InterfaceClaim(PassivePacketSink)]),
        parameters, PassivePacketSinkStates(seed), PassivePacketSinkStatistics(),
        NO_MODULE_REF)
    m.in.owner = m
    m
end

function NetworkModule.initialize_module!(::Network, m::PassivePacketSinkModule)
    # The producer is needed only to tell it when consumption becomes possible
    # again, which a sink with no interval never does — hence optional.
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m
end

NetworkModule.register_module_statistics!(m::PassivePacketSinkModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

# A sink with an initial offset has to start refusing before the first packet
# arrives, so it needs the timer running from the outset.
NetworkModule.module_starts(m::PassivePacketSinkModule) =
    m.parameters.initial_consumption_offset > 0

function NetworkModule.start_module!(ctx, m::PassivePacketSinkModule)
    _schedule_consumption!(ctx, m, to_simtime(m.parameters.initial_consumption_offset))
    m
end

NetworkModule.reset_module!(m::PassivePacketSinkModule) =
    (reset_states!(m.states); reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::PassivePacketSinkModule, ::Any)
    statistics = m.statistics
    record_statistic!(statistics.recording, "packets:count", statistics.num_packets)
    record_statistic!(statistics.recording, "packetLengths:sum", statistics.total_length)
    statistics.num_packets == 0 && return nothing
    record_statistic!(statistics.recording, "packetLifeTime:mean",
                      statistics.total_life_time / statistics.num_packets / TIME_UNIT)
    nothing
end

# Room unless the consumption interval is still running.
PacketProtocolModule.can_push_some_packet(m::PassivePacketSinkModule, ::Gate) =
    !is_scheduled(m.states.timer)
PacketProtocolModule.can_push_packet(m::PassivePacketSinkModule, gate::Gate, ::Packet) =
    PacketProtocolModule.can_push_some_packet(m, gate)

function PacketProtocolModule.push_packet!(ctx, m::PassivePacketSinkModule, ::Gate, packet::Packet)
    is_scheduled(m.states.timer) &&
        error("push_packet!: $(m.name) is still consuming the previous packet — " *
              "the producer pushed without asking whether it could")
    _consume_packet!(ctx, m, packet)
    # Refuse for as long as consuming this one takes, then say so.
    interval = evaluate(m.parameters.consumption_interval, m.states.rng)
    interval > 0 && _schedule_consumption!(ctx, m, to_simtime(interval))
    nothing
end

function _consume_packet!(ctx, m::PassivePacketSinkModule, packet::Packet)
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

# When the interval elapses the sink has room again, and the producer — which
# stopped because it was refused — is the one who needs to know.
_schedule_consumption!(ctx, m::PassivePacketSinkModule, delay::SimTime) =
    schedule_timer!(ctx, delay, m.module_id, m.states.timer, function (c)
        is_resolved(m.producer) && handle_can_push_packet_changed!(c, m.producer)
    end)

end # module
