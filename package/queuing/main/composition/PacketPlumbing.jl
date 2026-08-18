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

using OmnetppSimulator: SimTime, seconds, to_simtime, MersenneTwister, NetworkModule, schedule_event!
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network, module_id,
    @simulation_module, decorate_module!
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

export PacketMultiplexerModule, PacketDemultiplexerModule, PacketDelayerModule,
       packets_in_flight

# ── Multiplexer: several push chains into one ──────────────────────────────

"""
    PacketMultiplexerModule(name; inputs)

Merges `inputs` push chains into one output. Every producer pushes into its own
input and the packets come out in the order they arrived.
"""
@simulation_module struct PacketMultiplexerModule
    @parameter inputs::Int                             # no default: a merge of what?
    @gates begin
        in::Vector{InputGate} = inputs
        out::OutputGate
    end
    @variables begin
        producers::Vector{ModuleRef} = ModuleRef[]
        consumer::ModuleRef = NO_MODULE_REF
    end
    @statistic num_packets::Int = 0
end

function NetworkModule.decorate_module!(m::PacketMultiplexerModule)
    for gate in m.in
        push!(gate.annotations, ForwardClaim(PassivePacketSink, :out))
    end
    push!(m.out.annotations, InterfaceClaim(ActivePacketSource))
    m
end

function NetworkModule.initialize_module!(::Network, m::PacketMultiplexerModule)
    m.producers = [resolve_interface(gate, ActivePacketSource; mandatory = false)
                   for gate in m.in]
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.module_icon(::PacketMultiplexerModule) = "block/join"

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
    PacketDemultiplexerModule(name; outputs)

Lets `outputs` collectors pull from one provider. Whichever pulls first gets
the packet.
"""
@simulation_module struct PacketDemultiplexerModule
    @parameter outputs::Int                            # no default: a split into what?
    @gates begin
        in::InputGate
        out::Vector{OutputGate} = outputs
    end
    @variables begin
        provider::ModuleRef = NO_MODULE_REF
        collectors::Vector{ModuleRef} = ModuleRef[]
    end
    @statistic num_packets::Int = 0
end

function NetworkModule.decorate_module!(m::PacketDemultiplexerModule)
    push!(m.in.annotations, InterfaceClaim(ActivePacketSink))
    for gate in m.out
        push!(gate.annotations, InterfaceClaim(PassivePacketSource))
    end
    m
end

function NetworkModule.initialize_module!(::Network, m::PacketDemultiplexerModule)
    m.provider = resolve_interface(m.in, PassivePacketSource)
    m.collectors = [resolve_interface(gate, ActivePacketSink; mandatory = false)
                    for gate in m.out]
    m
end

NetworkModule.module_icon(::PacketDemultiplexerModule) = "block/fork"

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
    PacketDelayerModule(name; delay, seed = 0)

How long each packet is held, in seconds. [`Volatile`](@ref) delays are drawn
per packet, and then packets can overtake one another — which is the point, a
path whose delay varies reorders what crosses it.
"""
@simulation_module struct PacketDelayerModule
    @parameters begin
        delay::Any                                     # no default: held for how long?
        seed::Int = 0
    end
    @gates begin
        in::InputGate
        out::OutputGate
    end
    @rng rng::MersenneTwister
    @variable consumer::ModuleRef = NO_MODULE_REF
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_packets::Int = 0
        in_flight::Int = 0
    end
end

function NetworkModule.decorate_module!(m::PacketDelayerModule)
    push!(m.in.annotations, ForwardClaim(PassivePacketSink, :out))
    push!(m.out.annotations, InterfaceClaim(ActivePacketSource))
    m
end

const STATISTIC_NAMES = (:packetDelay,)

"""
    packets_in_flight(m) -> Int

How many packets the delayer is currently holding.
"""
packets_in_flight(m::PacketDelayerModule) = m.in_flight

function NetworkModule.initialize_module!(::Network, m::PacketDelayerModule)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketDelayerModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_icon(::PacketDelayerModule) = "block/delay"

NetworkModule.finish_module!(m::PacketDelayerModule, ::Any) =
    (record_statistic!(m.recording, "packets:count", m.num_packets); nothing)

# A delayer holds packets rather than blocking, so what it can take depends
# only on what is behind it.
PacketProtocolModule.can_push_some_packet(m::PacketDelayerModule, ::Gate) =
    can_push_some_packet(m.consumer)
PacketProtocolModule.can_push_packet(m::PacketDelayerModule, ::Gate, packet::Packet) =
    can_push_packet(m.consumer, packet)

function PacketProtocolModule.push_packet!(ctx, m::PacketDelayerModule, ::Gate, packet::Packet)
    delay = to_simtime(evaluate(m.delay, m.rng))
    m.num_packets += 1
    m.in_flight += 1
    emit_statistic!(m.recording, ctx, :packetDelay, seconds(delay))
    # Each packet gets its own event, so several are in flight at once and a
    # drawn delay can reorder them.
    schedule_event!(ctx, delay, m.module_id, function (c)
        m.in_flight -= 1
        push_or_schedule!(c, m.consumer, packet)
    end)
    nothing
end

end # module
