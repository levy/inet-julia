"""
    PacketFilterElement

**The sieve**: packets are pushed in, those that match are passed on, the rest
are dropped.

What matches is a Julia predicate on the packet. INET writes those as match
expressions in a small filter language, or as registered C++ classes; here the
predicate is a function, and a filter on length, on a tag, on anything the model
can compute is the same element with a different function in it.

Whether a non-matching packet counts as "can be pushed" is the `backpressure`
parameter, and it decides which of two things the filter is. Without it — the
default — the filter always accepts, and quietly drops what does not match: it
is a sieve, and the producer never learns. With it, the filter accepts only what
it will pass on, so a producer offering an unwanted packet is refused and the
packet stays upstream.
"""
module PacketFilterElement

using OmnetppSimulator: NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network,
    input_gate, output_gate, module_id
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, ActivePacketSource,
    can_push_some_packet, can_push_packet, push_or_schedule!,
    handle_can_push_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!

export PacketFilterParameters, PacketFilterStatistics, PacketFilterModule

"""
    PacketFilterParameters(; predicate, backpressure = false)

`predicate` is `packet -> Bool`: whether the packet is passed on. With
`backpressure`, a packet that fails it is refused rather than dropped.
"""
struct PacketFilterParameters
    predicate::Any
    backpressure::Bool
end

PacketFilterParameters(; predicate, backpressure::Bool = false) =
    PacketFilterParameters(predicate, backpressure)

mutable struct PacketFilterStatistics
    recording::ModuleStatistics
    num_passed::Int
    num_dropped::Int
    dropped_length::Int      # bits
end

PacketFilterStatistics() = PacketFilterStatistics(ModuleStatistics(), 0, 0, 0)

reset_statistics!(statistics::PacketFilterStatistics) =
    (statistics.num_passed = 0; statistics.num_dropped = 0;
     statistics.dropped_length = 0; statistics)

const STATISTIC_NAMES = (:outgoingPacketLengths, :droppedPacketLengths)

mutable struct PacketFilterModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Gate
    parameters::PacketFilterParameters
    statistics::PacketFilterStatistics
    producer::ModuleRef
    consumer::ModuleRef
end

function PacketFilterModule(name::Symbol, parameters::PacketFilterParameters)
    m = PacketFilterModule(
        name, 0,
        input_gate(nothing, :in;
                   annotations = Any[ForwardClaim(PassivePacketSink, :out)]),
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(ActivePacketSource)]),
        parameters, PacketFilterStatistics(), NO_MODULE_REF, NO_MODULE_REF)
    m.in.owner = m
    m.out.owner = m
    m
end

function NetworkModule.initialize_module!(::Network, m::PacketFilterModule)
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketFilterModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_icon(::PacketFilterModule) = "block/filter"

NetworkModule.reset_module!(m::PacketFilterModule) = (reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::PacketFilterModule, ::Any)
    recording = m.statistics.recording
    record_statistic!(recording, "packets:count", m.statistics.num_passed)
    record_statistic!(recording, "droppedPackets:count", m.statistics.num_dropped)
    record_statistic!(recording, "droppedPacketLengths:sum", m.statistics.dropped_length)
    nothing
end

PacketProtocolModule.can_push_some_packet(m::PacketFilterModule, ::Gate) =
    can_push_some_packet(m.consumer)

function PacketProtocolModule.can_push_packet(m::PacketFilterModule, ::Gate, packet::Packet)
    matches = m.parameters.predicate(packet)
    m.parameters.backpressure && return matches && can_push_packet(m.consumer, packet)
    # A packet about to be dropped needs no room downstream, so refusing it
    # would be refusing on someone else's behalf.
    matches || return true
    can_push_packet(m.consumer, packet)
end

function PacketProtocolModule.push_packet!(ctx, m::PacketFilterModule, ::Gate, packet::Packet)
    statistics = m.statistics
    if m.parameters.predicate(packet)
        statistics.num_passed += 1
        emit_statistic!(statistics.recording, ctx, :outgoingPacketLengths, bits(data_length(packet)))
        push_or_schedule!(ctx, m.consumer, packet)
    else
        length = bits(data_length(packet))
        statistics.num_dropped += 1
        statistics.dropped_length += length
        emit_statistic!(statistics.recording, ctx, :droppedPacketLengths, length)
    end
    nothing
end

# A filter holds nothing, so what changes downstream changes upstream too.
function PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::PacketFilterModule, ::Gate)
    is_resolved(m.producer) && handle_can_push_packet_changed!(ctx, m.producer)
    nothing
end

end # module
