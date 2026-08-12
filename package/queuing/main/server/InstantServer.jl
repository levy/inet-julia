"""
    InstantServerElement

**A server that takes no time**: it moves packets from what is upstream to what
is downstream, as many as it can, without any of them spending time in it.

Where a [`PacketServerElement`](@ref) models something that takes a while — a
transmitter, a processing stage — this one models the absence of one. It is
what joins a pull chain to a push chain when nothing about the join should show
up in the timing, and it is the simplest thing that can drive a queue.

Because it takes no time it does not stop after one packet: it keeps going
while there is something to take and room to put it, which is why moving a
whole burst is one event and not one event per packet.
"""
module InstantServerElement

using OmnetppSimulator: SimTime, ZERO_DELAY, schedule_event!, NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network, module_id,
    @simulation_module, decorate_module!
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, PassivePacketSource,
    ActivePacketSource, ActivePacketSink,
    can_pull_packet, can_push_packet, pull_packet!, push_or_schedule!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!

export InstantServerModule

"""
    InstantServerModule(name)

The module, declared by the kind of each of its fields. It takes no parameter:
an instant server has nothing to set.

`serving` says whether the server is already moving packets. It calls into its
peers, which may call back into it, and without the guard a burst would be
moved twice over.
"""
@simulation_module struct InstantServerModule
    @gates begin
        in::InputGate
        out::OutputGate
    end
    @variables begin
        serving::Bool = false
        provider::ModuleRef = NO_MODULE_REF
        consumer::ModuleRef = NO_MODULE_REF
    end
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_packets::Int = 0
        total_length::Int = 0                          # bits
    end
end

# The claims a lookup reads off the gates, set before any lookup walks the
# wiring.
function NetworkModule.decorate_module!(m::InstantServerModule)
    push!(m.in.annotations, ForwardClaim(ActivePacketSink, :out;
                                         forwarded = PassivePacketSink))
    push!(m.out.annotations, InterfaceClaim(ActivePacketSource))
    m
end

const STATISTIC_NAMES = (:packetLengths,)

function NetworkModule.initialize_module!(::Network, m::InstantServerModule)
    m.provider = resolve_interface(m.in, PassivePacketSource)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::InstantServerModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.start_module!(root, m::InstantServerModule) =
    (schedule_event!(root, ZERO_DELAY, ctx -> _serve_all!(ctx, m)); m)

NetworkModule.module_icon(::InstantServerModule) = "block/server"

function NetworkModule.finalize_module!(m::InstantServerModule, ::Any)
    record_statistic!(m.recording, "packets:count", m.num_packets)
    record_statistic!(m.recording, "packetLengths:sum", m.total_length)
    nothing
end

PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::InstantServerModule, ::Gate) =
    (_serve_all!(ctx, m); nothing)
PacketProtocolModule.handle_can_pull_packet_changed!(ctx, m::InstantServerModule, ::Gate) =
    (_serve_all!(ctx, m); nothing)

function _serve_all!(ctx, m::InstantServerModule)
    # Pushing a packet on can make the peers call straight back in; the guard
    # keeps this the only loop moving them.
    m.serving && return nothing
    m.serving = true
    try
        while true
            packet = can_pull_packet(m.provider)
            packet === nothing && break
            can_push_packet(m.consumer, packet) || break
            _serve_packet!(ctx, m)
        end
    finally
        m.serving = false
    end
    nothing
end

function _serve_packet!(ctx, m::InstantServerModule)
    packet = pull_packet!(ctx, m.provider)
    length = bits(data_length(packet))
    m.num_packets += 1
    m.total_length += length
    emit_statistic!(m.recording, ctx, :packetLengths, length)
    push_or_schedule!(ctx, m.consumer, packet)
    nothing
end

end # module
