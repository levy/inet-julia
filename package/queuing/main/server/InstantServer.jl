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

using OmnetppSimulator: SimTime, NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network,
    input_gate, output_gate, module_id
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, PassivePacketSource,
    ActivePacketSource, ActivePacketSink,
    can_pull_packet, can_push_packet, pull_packet!, push_or_schedule!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!

export InstantServerStates, InstantServerStatistics, InstantServerModule

"""
    InstantServerStates()

Only whether the server is already moving packets. It calls into its peers,
which may call back into it, and without the guard a burst would be moved
twice over.
"""
mutable struct InstantServerStates
    serving::Bool
end

InstantServerStates() = InstantServerStates(false)

reset_states!(states::InstantServerStates) = (states.serving = false; states)

mutable struct InstantServerStatistics
    recording::ModuleStatistics
    num_packets::Int
    total_length::Int      # bits
end

InstantServerStatistics() = InstantServerStatistics(ModuleStatistics(), 0, 0)

reset_statistics!(statistics::InstantServerStatistics) =
    (statistics.num_packets = 0; statistics.total_length = 0; statistics)

const STATISTIC_NAMES = (:packetLengths,)

mutable struct InstantServerModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Gate
    states::InstantServerStates
    statistics::InstantServerStatistics
    provider::ModuleRef
    consumer::ModuleRef
end

function InstantServerModule(name::Symbol)
    m = InstantServerModule(
        name, 0,
        input_gate(nothing, :in;
                   annotations = Any[ForwardClaim(ActivePacketSink, :out;
                                                  forwarded = PassivePacketSink)]),
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(ActivePacketSource)]),
        InstantServerStates(), InstantServerStatistics(), NO_MODULE_REF, NO_MODULE_REF)
    m.in.owner = m
    m.out.owner = m
    m
end

function NetworkModule.initialize_module!(::Network, m::InstantServerModule)
    m.provider = resolve_interface(m.in, PassivePacketSource)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::InstantServerModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_starts(::InstantServerModule) = true

NetworkModule.start_module!(ctx, m::InstantServerModule) = (_serve_all!(ctx, m); m)

NetworkModule.module_icon(::InstantServerModule) = "block/server"

NetworkModule.reset_module!(m::InstantServerModule) =
    (reset_states!(m.states); reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::InstantServerModule, ::Any)
    record_statistic!(m.statistics.recording, "packets:count", m.statistics.num_packets)
    record_statistic!(m.statistics.recording, "packetLengths:sum", m.statistics.total_length)
    nothing
end

PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::InstantServerModule, ::Gate) =
    (_serve_all!(ctx, m); nothing)
PacketProtocolModule.handle_can_pull_packet_changed!(ctx, m::InstantServerModule, ::Gate) =
    (_serve_all!(ctx, m); nothing)

function _serve_all!(ctx, m::InstantServerModule)
    states = m.states
    # Pushing a packet on can make the peers call straight back in; the guard
    # keeps this the only loop moving them.
    states.serving && return nothing
    states.serving = true
    try
        while true
            packet = can_pull_packet(m.provider)
            packet === nothing && break
            can_push_packet(m.consumer, packet) || break
            _serve_packet!(ctx, m)
        end
    finally
        states.serving = false
    end
    nothing
end

function _serve_packet!(ctx, m::InstantServerModule)
    packet = pull_packet!(ctx, m.provider)
    statistics = m.statistics
    length = bits(data_length(packet))
    statistics.num_packets += 1
    statistics.total_length += length
    emit_statistic!(statistics.recording, ctx, :packetLengths, length)
    push_or_schedule!(ctx, m.consumer, packet)
    nothing
end

end # module
