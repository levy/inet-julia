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
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network, module_id,
    @simulation_module, decorate_module!
using OmnetppSimulator.TimerModule: TimerHandle, is_scheduled, schedule_timer!
using OmnetppSimulator.VolatileModule: evaluate
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSource, ActivePacketSink,
    handle_can_pull_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!
using ..PacketSourceModule: PacketTemplate, create_packet

export PassivePacketSourceModule

"""
    PassivePacketSourceModule(name; providing_interval = 0.0, …)

The module, declared by the kind of each of its fields.

`providing_interval` is how fast the source is willing to be pulled from, in
seconds. The default, zero, means no limit. `initial_providing_offset` is how
long it refuses before the first pull. `next_packet` holds what a collector saw
when it looked, so that the pull which follows hands over that same packet.
"""
@simulation_module struct PassivePacketSourceModule
    @parameters begin
        providing_interval::Any = 0.0
        initial_providing_offset::Float64 = 0.0
        packet::PacketTemplate = PacketTemplate()
        seed::Int = 0
    end
    @gates begin
        out::OutputGate
    end
    @stream rng::MersenneTwister = MersenneTwister(seed)
    @variables begin
        timer::TimerHandle = TimerHandle()
        next_packet::Union{Packet,Nothing} = nothing
        collector::ModuleRef = NO_MODULE_REF
    end
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_packets::Int = 0
        total_length::Int = 0                          # bits
    end
end

# The claim a lookup reads off the gate. It must be there before any lookup
# walks the wiring, so it belongs to construction rather than to initialization.
NetworkModule.decorate_module!(m::PassivePacketSourceModule) =
    (push!(m.out.annotations, InterfaceClaim(PassivePacketSource)); m)

const STATISTIC_NAMES = (:packetLengths,)

function NetworkModule.initialize_module!(::Network, m::PassivePacketSourceModule)
    m.collector = resolve_interface(m.out, ActivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PassivePacketSourceModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_starts(m::PassivePacketSourceModule) =
    m.initial_providing_offset > 0

function NetworkModule.start_module!(ctx, m::PassivePacketSourceModule)
    _schedule_providing!(ctx, m, to_simtime(m.initial_providing_offset))
    m
end

NetworkModule.module_icon(::PassivePacketSourceModule) = "block/source"

function NetworkModule.finalize_module!(m::PassivePacketSourceModule, ::Any)
    record_statistic!(m.recording, "packets:count", m.num_packets)
    record_statistic!(m.recording, "packetLengths:sum", m.total_length)
    nothing
end

PacketProtocolModule.can_pull_some_packet(m::PassivePacketSourceModule, ::Gate) =
    !is_scheduled(m.timer)

# Looking is allowed to make the packet: a collector deciding whether to take
# one needs to see it, and the pull that follows hands over this same packet.
function PacketProtocolModule.can_pull_packet(m::PassivePacketSourceModule, ::Gate)
    is_scheduled(m.timer) && return nothing
    m.next_packet === nothing &&
        (m.next_packet = create_packet(m.packet, m.rng, SimTime(0)))
    m.next_packet
end

function PacketProtocolModule.pull_packet!(ctx, m::PassivePacketSourceModule, ::Gate)
    is_scheduled(m.timer) &&
        error("pull_packet!: $(m.name) is still providing the previous packet — " *
              "the collector pulled without asking whether it could")
    packet = m.next_packet
    if packet === nothing
        packet = create_packet(m.packet, m.rng, ctx.timestamp)
    else
        m.next_packet = nothing
    end
    length = bits(data_length(packet))
    m.num_packets += 1
    m.total_length += length
    emit_statistic!(m.recording, ctx, :packetLengths, length)
    interval = evaluate(m.providing_interval, m.rng)
    interval > 0 && _schedule_providing!(ctx, m, to_simtime(interval))
    packet
end

_schedule_providing!(ctx, m::PassivePacketSourceModule, delay::SimTime) =
    schedule_timer!(ctx, delay, m.module_id, m.timer, function (c)
        is_resolved(m.collector) && handle_can_pull_packet_changed!(c, m.collector)
    end)

end # module
