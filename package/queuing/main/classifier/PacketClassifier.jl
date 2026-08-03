"""
    PacketClassifierElement

**The fork**: packets are pushed in at one gate and leave by one of several,
chosen per packet.

Where they go is a Julia function of the packet, returning which output to use.
INET spells that choice as a registered C++ class named by a parameter, or as a
list of match expressions in a small filter language; here it is an ordinary
function, so a classifier by priority, by content, by anything the model knows,
is one element with a different function in it. The two most useful ones are
built: [`priority_classifier`](@ref) sends each packet to the first output that
will take it, and [`content_based_classifier`](@ref) to the first output whose
predicate the packet satisfies.

The choice is asked of the *same* function that decides whether a packet can be
pushed at all, so a classifier never accepts a packet it would then have
nowhere to put.
"""
module PacketClassifierElement

using OmnetppSimulator: NetworkModule
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, GateOutput, Network,
    input_gate, gate_vector, module_id
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, ActivePacketSource,
    can_push_some_packet, can_push_packet, push_or_schedule!,
    handle_can_push_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!

export PacketClassifierParameters, PacketClassifierStatistics, PacketClassifierModule,
       priority_classifier, content_based_classifier, classifier_outputs

"""
    PacketClassifierParameters(; classifier)

`classifier` is `(m, packet) -> Int`: which output the packet leaves by, counting
from one, or `0` for "none of them". It is given the module so a choice can
depend on what the outputs will currently accept.
"""
struct PacketClassifierParameters
    classifier::Any
end

PacketClassifierParameters(; classifier) = PacketClassifierParameters(classifier)

mutable struct PacketClassifierStatistics
    recording::ModuleStatistics
    num_packets::Int
    per_output::Vector{Int}
end

PacketClassifierStatistics(outputs::Int) =
    PacketClassifierStatistics(ModuleStatistics(), 0, zeros(Int, outputs))

reset_statistics!(statistics::PacketClassifierStatistics) =
    (statistics.num_packets = 0; fill!(statistics.per_output, 0); statistics)

const STATISTIC_NAMES = (:packetLengths,)

mutable struct PacketClassifierModule <: AbstractModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Vector{Gate}
    parameters::PacketClassifierParameters
    statistics::PacketClassifierStatistics
    producer::ModuleRef
    consumers::Vector{ModuleRef}
end

function PacketClassifierModule(name::Symbol, outputs::Int,
                                parameters::PacketClassifierParameters)
    m = PacketClassifierModule(
        name, 0,
        # Every output has to lead somewhere that accepts a push: a classifier
        # that cannot place a packet on one of its outputs is miswired.
        input_gate(nothing, :in;
                   annotations = Any[ForwardClaim(PassivePacketSink, :out)]),
        Gate[], parameters, PacketClassifierStatistics(outputs),
        NO_MODULE_REF, ModuleRef[])
    m.in.owner = m
    m.out = gate_vector(m, :out, GateOutput, outputs;
                        annotations = () -> Any[InterfaceClaim(ActivePacketSource)])
    m
end

"""
    classifier_outputs(m) -> Int

How many outputs the classifier has.
"""
classifier_outputs(m::PacketClassifierModule) = length(m.out)

"""
    priority_classifier(name, outputs) -> PacketClassifierModule

A classifier that sends each packet to the first output that will take it, so
the outputs are tried in order of priority and a full one is passed over.
"""
priority_classifier(name::Symbol, outputs::Int) =
    PacketClassifierModule(name, outputs, PacketClassifierParameters(
        classifier = function (m, packet)
            for index in 1:length(m.consumers)
                can_push_packet(m.consumers[index], packet) && return index
            end
            0
        end))

"""
    content_based_classifier(name, predicates; default_output = 0) -> PacketClassifierModule

A classifier that sends each packet to the first output whose predicate it
satisfies, and to `default_output` when none of them does — zero meaning the
packet cannot be placed at all. There is one predicate, `packet -> Bool`, per
output.
"""
function content_based_classifier(name::Symbol, predicates::AbstractVector;
                                  default_output::Int = 0)
    PacketClassifierModule(name, length(predicates), PacketClassifierParameters(
        classifier = function (_, packet)
            for index in 1:length(predicates)
                predicates[index](packet) && return index
            end
            default_output
        end))
end

function NetworkModule.initialize_module!(::Network, m::PacketClassifierModule)
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m.consumers = [resolve_interface(gate, PassivePacketSink) for gate in m.out]
    m
end

NetworkModule.register_module_statistics!(m::PacketClassifierModule, path::AbstractString, recorder) =
    register_statistics!(m.statistics.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.reset_module!(m::PacketClassifierModule) =
    (reset_statistics!(m.statistics); m)

function NetworkModule.finalize_module!(m::PacketClassifierModule, ::Any)
    recording = m.statistics.recording
    record_statistic!(recording, "packets:count", m.statistics.num_packets)
    for index in 1:length(m.statistics.per_output)
        record_statistic!(recording, "packets[$index]:count", m.statistics.per_output[index])
    end
    nothing
end

PacketProtocolModule.can_push_some_packet(m::PacketClassifierModule, ::Gate) =
    any(consumer -> can_push_some_packet(consumer), m.consumers)

# Asking the same function that will place the packet, so a classifier never
# accepts one it would then have nowhere to put.
function PacketProtocolModule.can_push_packet(m::PacketClassifierModule, ::Gate, packet::Packet)
    index = m.parameters.classifier(m, packet)
    index == 0 && return false
    can_push_packet(m.consumers[index], packet)
end

function PacketProtocolModule.push_packet!(ctx, m::PacketClassifierModule, ::Gate, packet::Packet)
    index = m.parameters.classifier(m, packet)
    (1 <= index <= length(m.consumers)) ||
        error("push_packet!: $(m.name) has no output for this packet (chose $index of " *
              "$(length(m.consumers))) — the producer pushed without asking whether it could")
    statistics = m.statistics
    statistics.num_packets += 1
    statistics.per_output[index] += 1
    emit_statistic!(statistics.recording, ctx, :packetLengths, bits(data_length(packet)))
    push_or_schedule!(ctx, m.consumers[index], packet)
    nothing
end

# One output having room again can change the answer for the whole classifier,
# so the news is passed on to whoever pushes into it.
function PacketProtocolModule.handle_can_push_packet_changed!(ctx, m::PacketClassifierModule,
                                                              ::Gate)
    is_resolved(m.producer) && handle_can_push_packet_changed!(ctx, m.producer)
    nothing
end

end # module
