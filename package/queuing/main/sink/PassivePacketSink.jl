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

using OmnetppSimulator: SimTime, seconds, to_simtime, ZERO_DELAY, schedule_event!, MersenneTwister, NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network, module_id,
    @simulation_module, decorate_module!
using OmnetppSimulator.TimerModule: TimerHandle, is_scheduled, schedule_timer!
using OmnetppSimulator.VolatileModule: evaluate
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, ActivePacketSource,
    handle_can_push_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    emit_time_statistic!, record_statistic!
using ..PacketSourceModule: packet_creation_time

export PassivePacketSinkModule

"""
    PassivePacketSinkModule(name; consumption_interval = 0.0, …)

The module, declared by the kind of each of its fields.

`consumption_interval` is how fast the sink is willing to consume, in seconds.
The default, zero, means no limit: any number of packets may arrive at the same
instant. A non-zero interval — usually [`Volatile`](@ref) — makes the sink
refuse until that much time has passed since the last packet.

`total_life_time` comes from the creation time the source stamped on each
packet, and is the end-to-end delay of the chain.
"""
@simulation_module struct PassivePacketSinkModule
    @parameters begin
        consumption_interval::Any = 0.0
        initial_consumption_offset::Float64 = 0.0
        seed::Int = 0
    end
    @gates begin
        in::InputGate
    end
    @stream rng::MersenneTwister = MersenneTwister(seed)
    @variables begin
        timer::TimerHandle = TimerHandle()
        producer::ModuleRef = NO_MODULE_REF
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
NetworkModule.decorate_module!(m::PassivePacketSinkModule) =
    (push!(m.in.annotations, InterfaceClaim(PassivePacketSink)); m)

const STATISTIC_NAMES = (:packetLengths, :packetLifeTime)

function NetworkModule.initialize_module!(::Network, m::PassivePacketSinkModule)
    # The producer is needed only to tell it when consumption becomes possible
    # again, which a sink with no interval never does — hence optional.
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m
end

NetworkModule.register_module_statistics!(m::PassivePacketSinkModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

# A sink with an initial offset has to start refusing before the first packet
# arrives, so it needs the timer running from the outset.
function NetworkModule.start_module!(root, m::PassivePacketSinkModule)
    m.initial_consumption_offset > 0 || return m
    schedule_event!(root, ZERO_DELAY, ctx ->
        _schedule_consumption!(ctx, m, to_simtime(m.initial_consumption_offset)))
    m
end

NetworkModule.module_status(m::PassivePacketSinkModule) =
    string(m.num_packets, " received")

NetworkModule.module_icon(::PassivePacketSinkModule) = "block/sink"

function NetworkModule.finish_module!(m::PassivePacketSinkModule, ::Any)
    record_statistic!(m.recording, "packets:count", m.num_packets)
    record_statistic!(m.recording, "packetLengths:sum", m.total_length)
    m.num_packets == 0 && return nothing
    record_statistic!(m.recording, "packetLifeTime:mean",
                      seconds(m.total_life_time / m.num_packets))
    nothing
end

# Room unless the consumption interval is still running.
PacketProtocolModule.can_push_some_packet(m::PassivePacketSinkModule, ::Gate) =
    !is_scheduled(m.timer)
PacketProtocolModule.can_push_packet(m::PassivePacketSinkModule, gate::Gate, ::Packet) =
    PacketProtocolModule.can_push_some_packet(m, gate)

function PacketProtocolModule.push_packet!(ctx, m::PassivePacketSinkModule, ::Gate, packet::Packet)
    is_scheduled(m.timer) &&
        error("push_packet!: $(m.name) is still consuming the previous packet — " *
              "the producer pushed without asking whether it could")
    _consume_packet!(ctx, m, packet)
    # Refuse for as long as consuming this one takes, then say so.
    interval = evaluate(m.consumption_interval, m.rng)
    interval > 0 && _schedule_consumption!(ctx, m, to_simtime(interval))
    nothing
end

function _consume_packet!(ctx, m::PassivePacketSinkModule, packet::Packet)
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

# When the interval elapses the sink has room again, and the producer — which
# stopped because it was refused — is the one who needs to know.
_schedule_consumption!(ctx, m::PassivePacketSinkModule, delay::SimTime) =
    schedule_timer!(ctx, delay, m.module_id, m.timer, function (c)
        is_resolved(m.producer) && handle_can_push_packet_changed!(c, m.producer)
    end)

end # module
