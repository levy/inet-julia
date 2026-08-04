"""
    PacketPlumbingElement

**The plumbing**: elements that move packets without deciding anything about
them.

A multiplexer merges several push chains into one, a demultiplexer lets several
collectors pull from one provider, and a delayer holds each packet for a while
and then passes it on. None of them chooses, filters or stores in any
interesting sense — they are the joints that let chains be built into shapes
other than a line.

The delayer is the one with timing in it. Each packet gets its own event, so
several are in flight at once and they arrive in the order their delays put
them in — which is the point, since a delayer with a drawn delay reorders
traffic exactly as a network path does.
"""
module PacketPlumbingElement

using OmnetppSimulator: SimTime, seconds, to_simtime, MersenneTwister, NetworkModule, schedule!
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, GateInput, GateOutput, Network,
    input_gate, output_gate, gate_vector, module_id
using OmnetppSimulator.VolatileModule: evaluate
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, PassivePacketSource,
    ActivePacketSource, ActivePacketSink,
    can_push_some_packet, can_push_packet, can_pull_some_packet, can_pull_packet,
    pull_packet!, push_or_schedule!,
    handle_can_push_packet_changed!, handle_can_pull_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!

export PacketMultiplexerModule, PacketDemultiplexerModule,
       PacketDelayerParameters, PacketDelayerStatistics, PacketDelayerModule,
       packets_in_flight

# ── Multiplexer: several push chains into one ──────────────────────────────

"""
    PacketMultiplexerModule(name, inputs)

Merges `inputs` push chains into one output. Every producer pushes into its own
input and the packets come out in the order they arrived.
"""
mutable struct PacketMultiplexerModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Vector{Gate}
    out::Gate
    num_packets::Int
    producers::Vector{ModuleRef}
    consumer::ModuleRef
end

function PacketMultiplexerModule(name::Symbol, inputs::Int)
    m = PacketMultiplexerModule(
        name, 0, Gate[],
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(ActivePacketSource)]),
        0, ModuleRef[], NO_MODULE_REF)
    m.out.owner = m
    m.in = gate_vector(m, :in, GateInput, inputs;
                       annotations = () -> Any[ForwardClaim(PassivePacketSink, :out)])
    m
end

function NetworkModule.initialize_module!(::Network, m::PacketMultiplexerModule)
    m.producers = [resolve_interface(gate, ActivePacketSource; mandatory = false)
                   for gate in m.in]
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.module_icon(::PacketMultiplexerModule) = "block/join"

NetworkModule.reset_module!(m::PacketMultiplexerModule) = (m.num_packets = 0; m)

PacketProtocolModule.can_push_some_packet(m::PacketMultiplexerModule, ::Gate) =
    can_push_some_packet(m.consumer)
PacketProtocolModule.can_push_packet(m::PacketMultiplexerModule, ::Gate, packet::Packet) =
    can_push_packet(m.consumer, packet)

function PacketProtocolModule.push_packet!(ctx, m::PacketMultiplexerModule, ::Gate,
                                           packet::Packet)
    m.num_packets += 1
    push_or_schedule!(ctx, m.consumer, packet)
    nothing
end

# One output, many producers, so room appearing downstream is news for all of
# them — whichever was blocked can go on.
function PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::PacketMultiplexerModule,
                                                              ::Gate)
    for producer in m.producers
        is_resolved(producer) && handle_can_push_packet_changed!(ctx, producer)
    end
    nothing
end

# ── Demultiplexer: one provider, several collectors ────────────────────────

"""
    PacketDemultiplexerModule(name, outputs)

Lets `outputs` collectors pull from one provider. Whichever pulls first gets
the packet.
"""
mutable struct PacketDemultiplexerModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Vector{Gate}
    num_packets::Int
    provider::ModuleRef
    collectors::Vector{ModuleRef}
end

function PacketDemultiplexerModule(name::Symbol, outputs::Int)
    m = PacketDemultiplexerModule(
        name, 0,
        input_gate(nothing, :in; annotations = Any[InterfaceClaim(ActivePacketSink)]),
        Gate[], 0, NO_MODULE_REF, ModuleRef[])
    m.in.owner = m
    m.out = gate_vector(m, :out, GateOutput, outputs;
                        annotations = () -> Any[InterfaceClaim(PassivePacketSource)])
    m
end

function NetworkModule.initialize_module!(::Network, m::PacketDemultiplexerModule)
    m.provider = resolve_interface(m.in, PassivePacketSource)
    m.collectors = [resolve_interface(gate, ActivePacketSink; mandatory = false)
                    for gate in m.out]
    m
end

NetworkModule.module_icon(::PacketDemultiplexerModule) = "block/fork"

NetworkModule.reset_module!(m::PacketDemultiplexerModule) = (m.num_packets = 0; m)

PacketProtocolModule.can_pull_some_packet(m::PacketDemultiplexerModule, ::Gate) =
    can_pull_some_packet(m.provider)
PacketProtocolModule.can_pull_packet(m::PacketDemultiplexerModule, ::Gate) =
    can_pull_packet(m.provider)

function PacketProtocolModule.pull_packet!(ctx, m::PacketDemultiplexerModule, ::Gate)
    m.num_packets += 1
    pull_packet!(ctx, m.provider)
end

function PacketProtocolModule.handle_can_pull_packet_changed!(ctx, m::PacketDemultiplexerModule,
                                                              ::Gate)
    for collector in m.collectors
        is_resolved(collector) && handle_can_pull_packet_changed!(ctx, collector)
    end
    nothing
end

# ── Delayer: holds each packet for a while ─────────────────────────────────

"""
    PacketDelayerParameters(; delay)

How long each packet is held, in seconds. [`Volatile`](@ref) delays are drawn
per packet, and then packets can overtake one another — which is the point, a
path whose delay varies reorders what crosses it.
"""
struct PacketDelayerParameters
    delay::Any
end

PacketDelayerParameters(; delay) = PacketDelayerParameters(delay)

mutable struct PacketDelayerStatistics
    recording::ModuleStatistics
    num_packets::Int
    in_flight::Int
end

PacketDelayerStatistics() = PacketDelayerStatistics(ModuleStatistics(), 0, 0)

const STATISTIC_NAMES = (:packetDelay,)

mutable struct PacketDelayerModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Gate
    parameters::PacketDelayerParameters
    statistics::PacketDelayerStatistics
    rng::MersenneTwister
    seed::Int
    consumer::ModuleRef
end

function PacketDelayerModule(name::Symbol, parameters::PacketDelayerParameters;
                             seed::Int = 0)
    m = PacketDelayerModule(
        name, 0,
        input_gate(nothing, :in;
                   annotations = Any[ForwardClaim(PassivePacketSink, :out)]),
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(ActivePacketSource)]),
        parameters, PacketDelayerStatistics(), MersenneTwister(seed), seed, NO_MODULE_REF)
    m.in.owner = m
    m.out.owner = m
    m
end

"""
    packets_in_flight(m) -> Int

How many packets the delayer is currently holding.
"""
packets_in_flight(m::PacketDelayerModule) = m.statistics.in_flight

function NetworkModule.initialize_module!(::Network, m::PacketDelayerModule)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketDelayerModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_icon(::PacketDelayerModule) = "block/delay"

NetworkModule.reset_module!(m::PacketDelayerModule) =
    (m.rng = MersenneTwister(m.seed); m.statistics.num_packets = 0;
     m.statistics.in_flight = 0; m)

NetworkModule.finalize_module!(m::PacketDelayerModule, ::Any) =
    (record_statistic!(m.statistics.recording, "packets:count", m.statistics.num_packets);
     nothing)

# A delayer holds packets rather than blocking, so what it can take depends
# only on what is behind it.
PacketProtocolModule.can_push_some_packet(m::PacketDelayerModule, ::Gate) =
    can_push_some_packet(m.consumer)
PacketProtocolModule.can_push_packet(m::PacketDelayerModule, ::Gate, packet::Packet) =
    can_push_packet(m.consumer, packet)

function PacketProtocolModule.push_packet!(ctx, m::PacketDelayerModule, ::Gate, packet::Packet)
    delay = to_simtime(evaluate(m.parameters.delay, m.rng))
    statistics = m.statistics
    statistics.num_packets += 1
    statistics.in_flight += 1
    emit_statistic!(statistics.recording, ctx, :packetDelay, seconds(delay))
    # Each packet gets its own event, so several are in flight at once and a
    # drawn delay can reorder them.
    schedule!(ctx, delay, m.module_id, function (c)
        statistics.in_flight -= 1
        push_or_schedule!(c, m.consumer, packet)
    end)
    nothing
end

end # module
