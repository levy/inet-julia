"""
    ActivePacketSinkElement

**A sink that pulls**: every collection interval it takes a packet from
whatever is connected to its input, counts it and lets it go.

It is the driver of its connection, so it is also the one left waiting. When
the interval elapses and the provider has nothing, the sink does not set a new
timer: it stops, and waits to be told there is something to pull again.
"""
module ActivePacketSinkElement

using OmnetppSimulator: SimTime, seconds, to_simtime, ZERO_DELAY, schedule_event!, MersenneTwister, NetworkModule
using OmnetppSimulator.NetworkModule: SimulationModule, Gate, Network, module_id,
    @simulation_module, decorate_module!
using OmnetppSimulator.TimerModule: TimerHandle, is_scheduled, schedule_timer!
using OmnetppSimulator.VolatileModule: evaluate
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, resolve_interface
using ..PacketProtocolModule: PacketProtocolModule, ActivePacketSink, PassivePacketSource,
    can_pull_some_packet, pull_packet!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    emit_time_statistic!, record_statistic!
using ..PacketSourceModule: packet_creation_time

export ActivePacketSinkModule

"""
    ActivePacketSinkModule(name; collection_interval, …)

The module, declared by the kind of each of its fields.

`collection_interval` is how often the sink collects, in seconds, and it has no
default because a sink that never collects has nothing to say.
`initial_collection_offset` is when it starts, and negative — the default —
means it collects its first packet as the simulation starts.
"""
@simulation_module struct ActivePacketSinkModule
    @parameters begin
        collection_interval::Any                       # no default: it must be given
        initial_collection_offset::Float64 = -1.0
        seed::Int = 0
    end
    @gates begin
        in::InputGate
    end
    @stream rng::MersenneTwister = MersenneTwister(seed)
    @variables begin
        timer::TimerHandle = TimerHandle()
        offset_scheduled::Bool = false
        provider::ModuleRef = NO_MODULE_REF
    end
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_packets::Int = 0
        total_length::Int = 0                          # bits
        total_life_time::SimTime = SimTime(0)
    end
end

# The claim a lookup reads off the gate. It must be there before any lookup
# walks the wiring, so it belongs to construction rather than to initialization.
NetworkModule.decorate_module!(m::ActivePacketSinkModule) =
    (push!(m.in.annotations, InterfaceClaim(ActivePacketSink)); m)

const STATISTIC_NAMES = (:packetLengths, :packetLifeTime)

function NetworkModule.initialize_module!(::Network, m::ActivePacketSinkModule)
    m.provider = resolve_interface(m.in, PassivePacketSource)
    m
end

NetworkModule.register_module_statistics!(m::ActivePacketSinkModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.start_module!(root, m::ActivePacketSinkModule) =
    (schedule_event!(root, ZERO_DELAY, ctx -> _schedule_and_collect!(ctx, m)); m)

NetworkModule.module_icon(::ActivePacketSinkModule) = "block/sink"

function NetworkModule.finish_module!(m::ActivePacketSinkModule, ::Any)
    record_statistic!(m.recording, "packets:count", m.num_packets)
    record_statistic!(m.recording, "packetLengths:sum", m.total_length)
    m.num_packets == 0 && return nothing
    record_statistic!(m.recording, "packetLifeTime:mean",
                      seconds(m.total_life_time / m.num_packets))
    nothing
end

# Told there may be something to pull. Only acted on while stopped: with a timer
# outstanding the interval has not elapsed, and collecting now would be sooner
# than the interval allows.
function PacketProtocolModule.handle_can_pull_packet_changed!(ctx, m::ActivePacketSinkModule,
                                                              ::Gate)
    is_scheduled(m.timer) || _schedule_and_collect!(ctx, m)
    nothing
end

function _schedule_and_collect!(ctx, m::ActivePacketSinkModule)
    if !m.offset_scheduled && m.initial_collection_offset >= 0
        _schedule_collection!(ctx, m, to_simtime(m.initial_collection_offset))
        m.offset_scheduled = true
    elseif can_pull_some_packet(m.provider)
        _schedule_collection!(ctx, m, to_simtime(evaluate(m.collection_interval, m.rng)))
        _collect_packet!(ctx, m)
    end
    # Otherwise the provider is empty: no packet, and no timer, until it says
    # there is something to pull.
    nothing
end

_schedule_collection!(ctx, m::ActivePacketSinkModule, delay::SimTime) =
    schedule_timer!(ctx, delay, m.module_id, m.timer, c -> _schedule_and_collect!(c, m))

function _collect_packet!(ctx, m::ActivePacketSinkModule)
    packet = pull_packet!(ctx, m.provider)
    length = bits(data_length(packet))
    m.num_packets += 1
    m.total_length += length
    emit_statistic!(m.recording, ctx, :packetLengths, length)
    created = packet_creation_time(packet)
    if created !== nothing
        life_time = ctx.timestamp - created
        m.total_life_time += life_time
        emit_time_statistic!(m.recording, ctx, :packetLifeTime, life_time)
    end
    nothing
end

end # module
