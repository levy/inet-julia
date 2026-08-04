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

using OmnetppSimulator: SimTime, seconds, to_simtime, MersenneTwister, NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network,
    input_gate, output_gate, module_id
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

export PacketServerParameters, PacketServerStates, PacketServerStatistics, PacketServerModule

"""
    PacketServerParameters(; processing_time = 0.0, processing_bitrate = Inf)

How long serving a packet takes: `processing_time` seconds, plus the packet's
length divided by `processing_bitrate` bits per second. Either may be
[`Volatile`](@ref), and then it is drawn per packet.
"""
struct PacketServerParameters
    processing_time::Any
    processing_bitrate::Any
end

PacketServerParameters(; processing_time = 0.0, processing_bitrate = Inf) =
    PacketServerParameters(processing_time, processing_bitrate)

mutable struct PacketServerStates
    rng::MersenneTwister
    seed::Int
    timer::TimerHandle
    packet::Union{Packet,Nothing}     # the packet being served
    service_started::SimTime
    # Set before the packet is taken, not after. Taking one frees room upstream,
    # and being told about that reaches this server again before its timer is
    # running — without the flag it would start serving a second packet on top
    # of the one it is holding.
    serving::Bool
end

PacketServerStates(seed::Int) =
    PacketServerStates(MersenneTwister(seed), seed, TimerHandle(), nothing, SimTime(0), false)

reset_states!(states::PacketServerStates) =
    (states.rng = MersenneTwister(states.seed); states.timer = TimerHandle();
     states.packet = nothing; states.service_started = SimTime(0);
     states.serving = false; states)

mutable struct PacketServerStatistics
    recording::ModuleStatistics
    num_packets::Int
    total_length::Int              # bits
    total_service_time::SimTime
end

PacketServerStatistics() = PacketServerStatistics(ModuleStatistics(), 0, 0, SimTime(0))

reset_statistics!(statistics::PacketServerStatistics) =
    (statistics.num_packets = 0; statistics.total_length = 0;
     statistics.total_service_time = SimTime(0); statistics)

const STATISTIC_NAMES = (:packetLengths, :processingTime)

mutable struct PacketServerModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Gate
    parameters::PacketServerParameters
    states::PacketServerStates
    statistics::PacketServerStatistics
    provider::ModuleRef
    consumer::ModuleRef
end

function PacketServerModule(name::Symbol,
                            parameters::PacketServerParameters = PacketServerParameters();
                            seed::Int = 0)
    m = PacketServerModule(
        name, 0,
        # A server answers a lookup for something that will pull only when it
        # has somewhere to put what it pulls.
        input_gate(nothing, :in;
                   annotations = Any[ForwardClaim(ActivePacketSink, :out;
                                                  forwarded = PassivePacketSink)]),
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(ActivePacketSource)]),
        parameters, PacketServerStates(seed), PacketServerStatistics(),
        NO_MODULE_REF, NO_MODULE_REF)
    m.in.owner = m
    m.out.owner = m
    m
end

function NetworkModule.initialize_module!(::Network, m::PacketServerModule)
    m.provider = resolve_interface(m.in, PassivePacketSource)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketServerModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_starts(::PacketServerModule) = true

NetworkModule.start_module!(ctx, m::PacketServerModule) = (_start_if_possible!(ctx, m); m)

# A server is either working on something or it is not; how long it has been at
# it is a statistic, not a badge.
NetworkModule.module_status(m::PacketServerModule) =
    m.states.packet === nothing ? "idle" : "serving"

NetworkModule.reset_module!(m::PacketServerModule) =
    (reset_states!(m.states); reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::PacketServerModule, ::Any)
    statistics = m.statistics
    recording = statistics.recording
    record_statistic!(recording, "packets:count", statistics.num_packets)
    record_statistic!(recording, "packetLengths:sum", statistics.total_length)
    statistics.num_packets == 0 && return nothing
    record_statistic!(recording, "processingTime:mean",
                      seconds(statistics.total_service_time / statistics.num_packets))
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
    states = m.states
    (states.serving || is_scheduled(states.timer)) && return nothing
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
    parameters, states = m.parameters, m.states
    states.serving = true
    packet = pull_packet!(ctx, m.provider)
    states.packet = packet
    states.service_started = ctx.timestamp
    duration = evaluate(parameters.processing_time, states.rng)
    bitrate = evaluate(parameters.processing_bitrate, states.rng)
    isfinite(bitrate) && (duration += bits(data_length(packet)) / bitrate)
    schedule_timer!(ctx, to_simtime(duration), m.module_id, states.timer,
                    c -> _finish_service!(c, m))
    nothing
end

function _finish_service!(ctx, m::PacketServerModule)
    states, statistics = m.states, m.statistics
    packet = states.packet
    states.packet = nothing
    states.serving = false
    length = bits(data_length(packet))
    service_time = ctx.timestamp - states.service_started
    statistics.num_packets += 1
    statistics.total_length += length
    statistics.total_service_time += service_time
    emit_statistic!(statistics.recording, ctx, :packetLengths, length)
    emit_time_statistic!(statistics.recording, ctx, :processingTime, service_time)
    push_or_schedule!(ctx, m.consumer, packet)
    # Straight on to the next one, if there is one and there is room.
    _start_if_possible!(ctx, m)
    nothing
end

end # module
