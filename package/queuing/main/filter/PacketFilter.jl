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
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network, module_id,
    @simulation_module, decorate_module!
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, ActivePacketSource,
    can_push_some_packet, can_push_packet, push_or_schedule!,
    handle_can_push_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!

export PacketFilterModule

"""
    PacketFilterModule(name; predicate, backpressure = false)

The module, declared by the kind of each of its fields.

`predicate` is `packet -> Bool`: whether the packet is passed on. With
`backpressure`, a packet that fails it is refused rather than dropped.
"""
@simulation_module struct PacketFilterModule
    @parameters begin
        predicate::Any                                 # no default: filter by what?
        backpressure::Bool = false
    end
    @gates begin
        in::InputGate
        out::OutputGate
    end
    @variables begin
        producer::ModuleRef = NO_MODULE_REF
        consumer::ModuleRef = NO_MODULE_REF
    end
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_passed::Int = 0
        num_dropped::Int = 0
        dropped_length::Int = 0                        # bits
    end
end

# The claims a lookup reads off the gates, set before any lookup walks the
# wiring.
function NetworkModule.decorate_module!(m::PacketFilterModule)
    push!(m.in.annotations, ForwardClaim(PassivePacketSink, :out))
    push!(m.out.annotations, InterfaceClaim(ActivePacketSource))
    m
end

const STATISTIC_NAMES = (:outgoingPacketLengths, :droppedPacketLengths)

function NetworkModule.initialize_module!(::Network, m::PacketFilterModule)
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketFilterModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_icon(::PacketFilterModule) = "block/filter"

function NetworkModule.finalize_module!(m::PacketFilterModule, ::Any)
    record_statistic!(m.recording, "packets:count", m.num_passed)
    record_statistic!(m.recording, "droppedPackets:count", m.num_dropped)
    record_statistic!(m.recording, "droppedPacketLengths:sum", m.dropped_length)
    nothing
end

PacketProtocolModule.can_push_some_packet(m::PacketFilterModule, ::Gate) =
    can_push_some_packet(m.consumer)

function PacketProtocolModule.can_push_packet(m::PacketFilterModule, ::Gate, packet::Packet)
    matches = m.predicate(packet)
    m.backpressure && return matches && can_push_packet(m.consumer, packet)
    # A packet about to be dropped needs no room downstream, so refusing it
    # would be refusing on someone else's behalf.
    matches || return true
    can_push_packet(m.consumer, packet)
end

function PacketProtocolModule.push_packet!(ctx, m::PacketFilterModule, ::Gate, packet::Packet)
    if m.predicate(packet)
        m.num_passed += 1
        emit_statistic!(m.recording, ctx, :outgoingPacketLengths, bits(data_length(packet)))
        push_or_schedule!(ctx, m.consumer, packet)
    else
        length = bits(data_length(packet))
        m.num_dropped += 1
        m.dropped_length += length
        emit_statistic!(m.recording, ctx, :droppedPacketLengths, length)
    end
    nothing
end

# A filter holds nothing, so what changes downstream changes upstream too.
function PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::PacketFilterModule, ::Gate)
    is_resolved(m.producer) && handle_can_push_packet_changed!(ctx, m.producer)
    nothing
end

end # module
