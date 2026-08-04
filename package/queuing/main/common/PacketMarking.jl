"""
    PacketMarkingModule

**The elements that change a packet, or how many there are.**

Everything up to here decided *where* a packet goes: a classifier forks, a
filter thins, a scheduler orders. None of them touched the packet itself, and
none of them changed how many there were. These two do, which is why they are
elements rather than predicates:

- [`PacketLabelerModule`](@ref) writes a value on each packet as it passes.
  Downstream that value is what a content-based classifier or a
  [`data_predicate`](@ref) reads — so a labeler is how a stream *acquires* the
  property later steps sort it by, when its source did not supply one.
- [`PacketClonerModule`](@ref) sends a copy of every packet out of each of its
  outputs, and [`PacketDuplicatorModule`](@ref) sends a chosen few twice down
  the one output it has.

Copies share their content — a `Chunk` is immutable, so `dup` costs a few words
rather than the payload — but get their own tags, which is what lets a labeler
downstream of a cloner mark each copy differently.
"""
module PacketMarkingModule

using OmnetppSimulator: NetworkModule, MersenneTwister
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, GateOutput, Network,
    input_gate, output_gate, gate_vector, module_id
using OmnetppSimulator.VolatileModule: evaluate
using InetPacket.PacketModule: Packet, dup, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, ActivePacketSource,
    can_push_some_packet, can_push_packet, push_or_schedule!,
    handle_can_push_packet_changed!
using ..PacketSourceModule: DataTag
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!

export PacketLabelerParameters, PacketLabelerStatistics, PacketLabelerModule,
       PacketClonerStatistics, PacketClonerModule, cloner_outputs,
       PacketDuplicatorParameters, PacketDuplicatorStatistics, PacketDuplicatorModule

# ── Labeler ─────────────────────────────────────────────────────────────────

"""
    PacketLabelerParameters(; label)

`label` is what to write on each packet: a constant, a
[`Volatile`](@ref) drawn per packet, or `packet -> value` when the label
depends on what is already there.

The value is written as the same tag a source writes, so everything that reads
a packet's data reads a label too — a labeler is not a separate vocabulary.
"""
struct PacketLabelerParameters
    label::Any
end

PacketLabelerParameters(; label) = PacketLabelerParameters(label)

mutable struct PacketLabelerStatistics
    recording::ModuleStatistics
    num_packets::Int
end

PacketLabelerStatistics() = PacketLabelerStatistics(ModuleStatistics(), 0)

reset_statistics!(statistics::PacketLabelerStatistics) =
    (statistics.num_packets = 0; statistics)

const LABELER_STATISTIC_NAMES = (:outgoingPacketLengths,)

"""
    PacketLabelerModule(name, parameters; seed = 0)

Writes a value on every packet that passes, and passes it on. Holds nothing and
refuses nothing: what the output will take, the labeler will take.
"""
mutable struct PacketLabelerModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Gate
    parameters::PacketLabelerParameters
    statistics::PacketLabelerStatistics
    rng::MersenneTwister
    seed::Int
    producer::ModuleRef
    consumer::ModuleRef
end

function PacketLabelerModule(name::Symbol, parameters::PacketLabelerParameters;
                             seed::Int = 0)
    m = PacketLabelerModule(
        name, 0,
        input_gate(nothing, :in;
                   annotations = Any[ForwardClaim(PassivePacketSink, :out)]),
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(ActivePacketSource)]),
        parameters, PacketLabelerStatistics(), MersenneTwister(seed), seed,
        NO_MODULE_REF, NO_MODULE_REF)
    m.in.owner = m
    m.out.owner = m
    m
end

# A function of the packet, a draw, or a constant — in that order, because a
# function is the only one that can look at what is already there.
_label_value(label, packet::Packet, rng::MersenneTwister) =
    label isa Function ? label(packet) : evaluate(label, rng)

function NetworkModule.initialize_module!(::Network, m::PacketLabelerModule)
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketLabelerModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, LABELER_STATISTIC_NAMES)

NetworkModule.module_icon(::PacketLabelerModule) = "block/process"

NetworkModule.reset_module!(m::PacketLabelerModule) =
    (reset_statistics!(m.statistics); m.rng = MersenneTwister(m.seed); m)

function NetworkModule.finalize_module!(m::PacketLabelerModule, ::Any)
    record_statistic!(m.statistics.recording, "packets:count", m.statistics.num_packets)
    nothing
end

PacketProtocolModule.can_push_some_packet(m::PacketLabelerModule, ::Gate) =
    can_push_some_packet(m.consumer)

PacketProtocolModule.can_push_packet(m::PacketLabelerModule, ::Gate, packet::Packet) =
    can_push_packet(m.consumer, packet)

function PacketProtocolModule.push_packet!(ctx, m::PacketLabelerModule, ::Gate, packet::Packet)
    packet.packet_tags[DataTag] = DataTag(_label_value(m.parameters.label, packet, m.rng))
    m.statistics.num_packets += 1
    emit_statistic!(m.statistics.recording, ctx, :outgoingPacketLengths,
                    bits(data_length(packet)))
    push_or_schedule!(ctx, m.consumer, packet)
    nothing
end

function PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::PacketLabelerModule, ::Gate)
    is_resolved(m.producer) && handle_can_push_packet_changed!(ctx, m.producer)
    nothing
end

# ── Cloner ──────────────────────────────────────────────────────────────────

mutable struct PacketClonerStatistics
    recording::ModuleStatistics
    num_packets::Int
    num_copies::Int
end

PacketClonerStatistics() = PacketClonerStatistics(ModuleStatistics(), 0, 0)

reset_statistics!(statistics::PacketClonerStatistics) =
    (statistics.num_packets = 0; statistics.num_copies = 0; statistics)

const CLONER_STATISTIC_NAMES = (:outgoingPacketLengths,)

"""
    PacketClonerModule(name, outputs)

Sends a copy of every packet out of each of its outputs.

Every output must be able to take the packet before any of them gets one:
handing out three copies and then discovering the fourth output is full would
leave the stream half-cloned, which is not something a downstream element could
make sense of. So a cloner refuses until they all agree.
"""
mutable struct PacketClonerModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Vector{Gate}
    statistics::PacketClonerStatistics
    producer::ModuleRef
    consumers::Vector{ModuleRef}
end

function PacketClonerModule(name::Symbol, outputs::Int)
    outputs >= 1 || error("PacketClonerModule: a cloner needs at least one output")
    m = PacketClonerModule(
        name, 0,
        input_gate(nothing, :in;
                   annotations = Any[ForwardClaim(PassivePacketSink, :out)]),
        Gate[], PacketClonerStatistics(), NO_MODULE_REF, ModuleRef[])
    m.in.owner = m
    m.out = gate_vector(m, :out, GateOutput, outputs;
                        annotations = () -> Any[InterfaceClaim(ActivePacketSource)])
    m
end

"""
    cloner_outputs(m) -> Int

How many copies of each packet this cloner makes.
"""
cloner_outputs(m::PacketClonerModule) = length(m.out)

function NetworkModule.initialize_module!(::Network, m::PacketClonerModule)
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m.consumers = [resolve_interface(gate, PassivePacketSink) for gate in m.out]
    m
end

NetworkModule.register_module_statistics!(m::PacketClonerModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, CLONER_STATISTIC_NAMES)

NetworkModule.module_icon(::PacketClonerModule) = "block/broadcast"

NetworkModule.reset_module!(m::PacketClonerModule) = (reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::PacketClonerModule, ::Any)
    record_statistic!(m.statistics.recording, "packets:count", m.statistics.num_packets)
    record_statistic!(m.statistics.recording, "clonedPackets:count", m.statistics.num_copies)
    nothing
end

PacketProtocolModule.can_push_some_packet(m::PacketClonerModule, ::Gate) =
    all(consumer -> can_push_some_packet(consumer), m.consumers)

PacketProtocolModule.can_push_packet(m::PacketClonerModule, ::Gate, packet::Packet) =
    all(consumer -> can_push_packet(consumer, packet), m.consumers)

function PacketProtocolModule.push_packet!(ctx, m::PacketClonerModule, ::Gate, packet::Packet)
    statistics = m.statistics
    statistics.num_packets += 1
    emit_statistic!(statistics.recording, ctx, :outgoingPacketLengths,
                    bits(data_length(packet)))
    for (index, consumer) in enumerate(m.consumers)
        # The last output gets the packet itself; the others get copies. One
        # fewer copy, and the original is not left holding a tag some copy
        # wrote.
        copy = index == length(m.consumers) ? packet : dup(packet)
        index == length(m.consumers) || (statistics.num_copies += 1)
        push_or_schedule!(ctx, consumer, copy)
    end
    nothing
end

function PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::PacketClonerModule, ::Gate)
    is_resolved(m.producer) && handle_can_push_packet_changed!(ctx, m.producer)
    nothing
end

# ── Duplicator ──────────────────────────────────────────────────────────────

"""
    PacketDuplicatorParameters(; predicate)

`predicate` is `packet -> Bool`: whether this packet goes down the output
twice. An [`ordinal_predicate`](@ref) makes that "every k-th", which is what
INET's ordinal-based duplicator is.
"""
struct PacketDuplicatorParameters
    predicate::Any
end

PacketDuplicatorParameters(; predicate) = PacketDuplicatorParameters(predicate)

mutable struct PacketDuplicatorStatistics
    recording::ModuleStatistics
    num_packets::Int
    num_duplicates::Int
end

PacketDuplicatorStatistics() = PacketDuplicatorStatistics(ModuleStatistics(), 0, 0)

reset_statistics!(statistics::PacketDuplicatorStatistics) =
    (statistics.num_packets = 0; statistics.num_duplicates = 0; statistics)

const DUPLICATOR_STATISTIC_NAMES = (:outgoingPacketLengths,)

"""
    PacketDuplicatorModule(name, parameters)

Passes every packet on, and sends a second copy of the ones its predicate
picks — one output, some packets twice.

Where a cloner fans one stream into several, this thickens one stream in
place, which is how a model produces the retransmissions and echoes a receiver
has to cope with.
"""
mutable struct PacketDuplicatorModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Gate
    parameters::PacketDuplicatorParameters
    statistics::PacketDuplicatorStatistics
    producer::ModuleRef
    consumer::ModuleRef
end

function PacketDuplicatorModule(name::Symbol, parameters::PacketDuplicatorParameters)
    m = PacketDuplicatorModule(
        name, 0,
        input_gate(nothing, :in;
                   annotations = Any[ForwardClaim(PassivePacketSink, :out)]),
        output_gate(nothing, :out; annotations = Any[InterfaceClaim(ActivePacketSource)]),
        parameters, PacketDuplicatorStatistics(), NO_MODULE_REF, NO_MODULE_REF)
    m.in.owner = m
    m.out.owner = m
    m
end

function NetworkModule.initialize_module!(::Network, m::PacketDuplicatorModule)
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m.consumer = resolve_interface(m.out, PassivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketDuplicatorModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, DUPLICATOR_STATISTIC_NAMES)

NetworkModule.module_icon(::PacketDuplicatorModule) = "block/fork"

NetworkModule.reset_module!(m::PacketDuplicatorModule) = (reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::PacketDuplicatorModule, ::Any)
    record_statistic!(m.statistics.recording, "packets:count", m.statistics.num_packets)
    record_statistic!(m.statistics.recording, "duplicatePackets:count",
                      m.statistics.num_duplicates)
    nothing
end

PacketProtocolModule.can_push_some_packet(m::PacketDuplicatorModule, ::Gate) =
    can_push_some_packet(m.consumer)

# A packet that will be sent twice needs room for both, and the protocol asks
# about one packet at a time — so the honest answer is the one the second copy
# would get. The predicate is NOT consulted here: it counts, and a question is
# not a packet.
PacketProtocolModule.can_push_packet(m::PacketDuplicatorModule, ::Gate, packet::Packet) =
    can_push_packet(m.consumer, packet)

function PacketProtocolModule.push_packet!(ctx, m::PacketDuplicatorModule, ::Gate, packet::Packet)
    statistics = m.statistics
    statistics.num_packets += 1
    emit_statistic!(statistics.recording, ctx, :outgoingPacketLengths,
                    bits(data_length(packet)))
    duplicate = m.parameters.predicate(packet)
    push_or_schedule!(ctx, m.consumer, packet)
    if duplicate
        statistics.num_duplicates += 1
        push_or_schedule!(ctx, m.consumer, dup(packet))
    end
    nothing
end

function PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::PacketDuplicatorModule, ::Gate)
    is_resolved(m.producer) && handle_can_push_packet_changed!(ctx, m.producer)
    nothing
end

end # module PacketMarkingModule
