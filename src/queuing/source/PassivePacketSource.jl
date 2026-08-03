"""
    PassivePacketSourceElement

**A source that is pulled from**: it has a packet ready whenever asked, and
whoever is connected to its output decides when to take one.

The packet is made when it is first looked at, not when it is taken, because a
collector may want to see what it would get before committing to it. The same
packet is then handed over by the pull that follows.

A providing interval turns it into a rate limit: after handing one over the
source has nothing until the interval passes, and then tells its collector
that there is something to pull again.
"""
module PassivePacketSourceElement

using OmnetppSimulator: SimTime, to_simtime, MersenneTwister, NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network, output_gate, module_id
using OmnetppSimulator.TimerModule: TimerHandle, is_scheduled, schedule_timer!
using OmnetppSimulator.VolatileModule: evaluate
using ..PacketModule: Packet, bits, data_length
using ..LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSource, ActivePacketSink,
    handle_can_pull_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!
using ..PacketSourceModule: PacketTemplate, create_packet

export PassivePacketSourceParameters, PassivePacketSourceStates,
       PassivePacketSourceStatistics, PassivePacketSourceModule

"""
    PassivePacketSourceParameters(; providing_interval = 0.0, initial_providing_offset = 0.0,
                                    packet = PacketTemplate())

How fast the source is willing to be pulled from, and what it hands over. The
default interval, zero, means no limit.
"""
struct PassivePacketSourceParameters
    providing_interval::Any
    initial_providing_offset::Float64
    packet::PacketTemplate
end

PassivePacketSourceParameters(; providing_interval = 0.0,
                              initial_providing_offset::Real = 0.0,
                              packet::PacketTemplate = PacketTemplate()) =
    PassivePacketSourceParameters(providing_interval, Float64(initial_providing_offset), packet)

mutable struct PassivePacketSourceStates
    rng::MersenneTwister
    seed::Int
    timer::TimerHandle
    next_packet::Union{Packet,Nothing}
end

PassivePacketSourceStates(seed::Int) =
    PassivePacketSourceStates(MersenneTwister(seed), seed, TimerHandle(), nothing)

reset_states!(states::PassivePacketSourceStates) =
    (states.rng = MersenneTwister(states.seed); states.timer = TimerHandle();
     states.next_packet = nothing; states)

mutable struct PassivePacketSourceStatistics
    recording::ModuleStatistics
    num_packets::Int
    total_length::Int      # bits
end

PassivePacketSourceStatistics() = PassivePacketSourceStatistics(ModuleStatistics(), 0, 0)

reset_statistics!(statistics::PassivePacketSourceStatistics) =
    (statistics.num_packets = 0; statistics.total_length = 0; statistics)

const STATISTIC_NAMES = (:packetLengths,)

mutable struct PassivePacketSourceModule <: AbstractModule
    name::Symbol
    module_id::Int
    out::Gate
    parameters::PassivePacketSourceParameters
    states::PassivePacketSourceStates
    statistics::PassivePacketSourceStatistics
    collector::ModuleRef
end

function PassivePacketSourceModule(name::Symbol,
                                   parameters::PassivePacketSourceParameters = PassivePacketSourceParameters();
                                   seed::Int = 0)
    m = PassivePacketSourceModule(
        name, 0,
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(PassivePacketSource)]),
        parameters, PassivePacketSourceStates(seed), PassivePacketSourceStatistics(),
        NO_MODULE_REF)
    m.out.owner = m
    m
end

function NetworkModule.initialize_module!(::Network, m::PassivePacketSourceModule)
    m.collector = resolve_interface(m.out, ActivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PassivePacketSourceModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_starts(m::PassivePacketSourceModule) =
    m.parameters.initial_providing_offset > 0

function NetworkModule.start_module!(ctx, m::PassivePacketSourceModule)
    _schedule_providing!(ctx, m, to_simtime(m.parameters.initial_providing_offset))
    m
end

NetworkModule.reset_module!(m::PassivePacketSourceModule) =
    (reset_states!(m.states); reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::PassivePacketSourceModule, ::Any)
    record_statistic!(m.statistics.recording, "packets:count", m.statistics.num_packets)
    record_statistic!(m.statistics.recording, "packetLengths:sum", m.statistics.total_length)
    nothing
end

PacketProtocolModule.can_pull_some_packet(m::PassivePacketSourceModule, ::Gate) =
    !is_scheduled(m.states.timer)

# Looking is allowed to make the packet: a collector deciding whether to take
# one needs to see it, and the pull that follows hands over this same packet.
function PacketProtocolModule.can_pull_packet(m::PassivePacketSourceModule, ::Gate)
    is_scheduled(m.states.timer) && return nothing
    states = m.states
    states.next_packet === nothing &&
        (states.next_packet = create_packet(m.parameters.packet, states.rng, SimTime(0)))
    states.next_packet
end

function PacketProtocolModule.pull_packet!(ctx, m::PassivePacketSourceModule, ::Gate)
    states = m.states
    is_scheduled(states.timer) &&
        error("pull_packet!: $(m.name) is still providing the previous packet — " *
              "the collector pulled without asking whether it could")
    packet = states.next_packet
    if packet === nothing
        packet = create_packet(m.parameters.packet, states.rng, ctx.timestamp)
    else
        states.next_packet = nothing
    end
    statistics = m.statistics
    length = bits(data_length(packet))
    statistics.num_packets += 1
    statistics.total_length += length
    emit_statistic!(statistics.recording, ctx, :packetLengths, length)
    interval = evaluate(m.parameters.providing_interval, states.rng)
    interval > 0 && _schedule_providing!(ctx, m, to_simtime(interval))
    packet
end

_schedule_providing!(ctx, m::PassivePacketSourceModule, delay::SimTime) =
    schedule_timer!(ctx, delay, m.module_id, m.states.timer, function (c)
        is_resolved(m.collector) && handle_can_pull_packet_changed!(c, m.collector)
    end)

end # module
