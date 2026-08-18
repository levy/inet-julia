"""
    PacketServerElement

**The server**: it takes one packet at a time, holds it for as long as serving
it takes, and passes it on.

It is the element that is active on both sides, and that is what makes it the
other joint of a chain: it pulls from whatever is upstream and pushes to
whatever is downstream, so a pull chain and a push chain meet here. A queue in
front of it and a server behind the queue is the shape of nearly every model
that has a bottleneck in it.

It starts serving only when both ends allow: there has to be a packet to take,
and room to put it when it is done. Whichever of those was missing, the peer
that has it says so, and the server tries again — so it is never left holding a
packet it cannot deliver.

Service time is a fixed processing time plus the time it takes to put the
packet out at the processing bitrate, which is how a link's transmission time is
modelled.
"""
module PacketServerElement

using OmnetppSimulator: SimTime, seconds, to_simtime, ZERO_DELAY, schedule_event!, MersenneTwister, NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network, module_id,
    @simulation_module, decorate_module!
using OmnetppSimulator.TimerModule: TimerHandle, is_scheduled, schedule_timer!
using OmnetppSimulator.VolatileModule: evaluate
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, PassivePacketSource,
    ActivePacketSource, ActivePacketSink,
    can_pull_packet, can_push_packet, pull_packet!, push_or_schedule!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    emit_time_statistic!, record_statistic!

export PacketServerModule

"""
    PacketServerModule(name; processing_time = 0.0, …)

The module, declared by the kind of each of its fields.

How long serving a packet takes: `processing_time` seconds, plus the packet's
length divided by `processing_bitrate` bits per second. Either may be
[`Volatile`](@ref), and then it is drawn per packet.

`serving` is set before the packet is taken, not after. Taking one frees room
upstream, and being told about that reaches this server again before its timer
is running — without the flag it would start serving a second packet on top of
the one it is holding.
"""
@simulation_module struct PacketServerModule
    @parameters begin
        processing_time::Any = 0.0
        processing_bitrate::Any = Inf
    end
    @gates begin
        in::InputGate
        out::OutputGate
    end
    @rng rng::MersenneTwister
    @variables begin
        timer::TimerHandle = TimerHandle()
        packet::Union{Packet,Nothing} = nothing        # the packet being served
        service_started::SimTime = SimTime(0)
        serving::Bool = false
        provider::ModuleRef = NO_MODULE_REF
        consumer::ModuleRef = NO_MODULE_REF
    end
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_packets::Int = 0
        total_length::Int = 0                          # bits
        total_service_time::SimTime = SimTime(0)
    end
end

# The claims a lookup reads off the gates, set before any lookup walks the
# wiring. A server answers a lookup for something that will pull only when it
# has somewhere to put what it pulls.
function NetworkModule.decorate_module!(m::PacketServerModule)
    push!(m.in.annotations, ForwardClaim(ActivePacketSink, :out;
                                         forwarded = PassivePacketSink))
    push!(m.out.annotations, InterfaceClaim(ActivePacketSource))
    m
end

const STATISTIC_NAMES = (:packetLengths, :processingTime)

function NetworkModule.initialize_module!(::Network, m::PacketServerModule)
    m.provider = resolve_interface(m.in, PassivePacketSource)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketServerModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.start_module!(root, m::PacketServerModule) =
    (schedule_event!(root, ZERO_DELAY, ctx -> _start_if_possible!(ctx, m)); m)

# A server is either working on something or it is not; how long it has been at
# it is a statistic, not a badge.
NetworkModule.module_status(m::PacketServerModule) =
    m.packet === nothing ? "idle" : "serving"

NetworkModule.module_icon(::PacketServerModule) = "block/server"

function NetworkModule.finish_module!(m::PacketServerModule, ::Any)
    record_statistic!(m.recording, "packets:count", m.num_packets)
    record_statistic!(m.recording, "packetLengths:sum", m.total_length)
    m.num_packets == 0 && return nothing
    record_statistic!(m.recording, "processingTime:mean",
                      seconds(m.total_service_time / m.num_packets))
    nothing
end

# Either end saying its answer changed is the same news to a server that is
# idle: it may now be able to serve. A busy server ignores both — it will look
# again when it finishes.
PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::PacketServerModule, ::Gate) =
    (_start_if_possible!(ctx, m); nothing)
PacketProtocolModule.handle_can_pull_packet_changed!(ctx, m::PacketServerModule, ::Gate) =
    (_start_if_possible!(ctx, m); nothing)

function _start_if_possible!(ctx, m::PacketServerModule)
    (m.serving || is_scheduled(m.timer)) && return nothing
    # Both ends have to allow it: something to take, and room for it when done.
    # Checking the far end now is what keeps the server from being stuck later
    # holding a packet nobody will accept.
    packet = can_pull_packet(m.provider)
    packet === nothing && return nothing
    can_push_packet(m.consumer, packet) || return nothing
    _start_service!(ctx, m)
    nothing
end

function _start_service!(ctx, m::PacketServerModule)
    m.serving = true
    packet = pull_packet!(ctx, m.provider)
    m.packet = packet
    m.service_started = ctx.timestamp
    duration = evaluate(m.processing_time, m.rng)
    bitrate = evaluate(m.processing_bitrate, m.rng)
    isfinite(bitrate) && (duration += bits(data_length(packet)) / bitrate)
    schedule_timer!(ctx, to_simtime(duration), m.module_id, m.timer,
                    c -> _finish_service!(c, m))
    nothing
end

function _finish_service!(ctx, m::PacketServerModule)
    packet = m.packet
    m.packet = nothing
    m.serving = false
    length = bits(data_length(packet))
    service_time = ctx.timestamp - m.service_started
    m.num_packets += 1
    m.total_length += length
    m.total_service_time += service_time
    emit_statistic!(m.recording, ctx, :packetLengths, length)
    emit_time_statistic!(m.recording, ctx, :processingTime, service_time)
    push_or_schedule!(ctx, m.consumer, packet)
    # Straight on to the next one, if there is one and there is room.
    _start_if_possible!(ctx, m)
    nothing
end

end # module
