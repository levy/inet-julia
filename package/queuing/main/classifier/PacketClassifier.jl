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

using OmnetppSimulator: NetworkModule, MersenneTwister
using OmnetppSimulator.NetworkModule: SimulationModule, Gate, Network, module_id,
    @simulation_module, decorate_module!
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSink, ActivePacketSource,
    can_push_some_packet, can_push_packet, push_or_schedule!,
    handle_can_push_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!

export PacketClassifierModule,
       priority_classifier, content_based_classifier, weighted_round_robin_classifier,
       markov_classifier, classifier_outputs

"""
    PacketClassifierModule(name; outputs, classifier)

The module, declared by the kind of each of its fields.

`classifier` is `(m, packet) -> Int`: which output the packet leaves by, counting
from one, or `0` for "none of them". It is given the module so a choice can
depend on what the outputs will currently accept. `outputs` is how many outputs
there are, and it sizes the gate vector and the per-output count.
"""
@simulation_module struct PacketClassifierModule
    @parameters begin
        outputs::Int                                   # no default: a fan-out of what?
        classifier::Any
    end
    @gates begin
        in::InputGate
        out::Vector{OutputGate} = outputs
    end
    @variables begin
        producer::ModuleRef = NO_MODULE_REF
        consumers::Vector{ModuleRef} = ModuleRef[]
    end
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_packets::Int = 0
        per_output::Vector{Int} = zeros(Int, outputs)
    end
end

# The claims a lookup reads off the gates, set before any lookup walks the
# wiring. Every output has to lead somewhere that accepts a push: a classifier
# that cannot place a packet on one of its outputs is miswired.
function NetworkModule.decorate_module!(m::PacketClassifierModule)
    push!(m.in.annotations, ForwardClaim(PassivePacketSink, :out))
    for gate in m.out
        push!(gate.annotations, InterfaceClaim(ActivePacketSource))
    end
    m
end

const STATISTIC_NAMES = (:packetLengths,)

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
    PacketClassifierModule(name; outputs = outputs,
        classifier = function (m, packet)
            for index in 1:length(m.consumers)
                can_push_packet(m.consumers[index], packet) && return index
            end
            0
        end)

"""
    content_based_classifier(name, predicates; default_output = 0) -> PacketClassifierModule

A classifier that sends each packet to the first output whose predicate it
satisfies, and to `default_output` when none of them does — zero meaning the
packet cannot be placed at all. There is one predicate, `packet -> Bool`, per
output.
"""
function content_based_classifier(name::Symbol, predicates::AbstractVector;
                                  default_output::Int = 0)
    PacketClassifierModule(name; outputs = length(predicates),
        classifier = function (_, packet)
            for index in 1:length(predicates)
                predicates[index](packet) && return index
            end
            default_output
        end)
end

"""
    weighted_round_robin_classifier(name, weights) -> PacketClassifierModule

A classifier that gives each output a run of `weights[i]` packets before moving
on to the next, cycling forever. With equal weights that is plain round robin;
with `[3, 1]` the first output gets three packets for every one the second
gets.

Unlike a priority classifier this one does not ask whether an output will take
the packet — the share each output receives is the point, and a full output
loses its turn rather than passing it on. Pair it with queues that refuse when
full if the shares must be exact even under overload.
"""
function weighted_round_robin_classifier(name::Symbol, weights::AbstractVector{<:Integer})
    all(w -> w >= 0, weights) ||
        error("weighted_round_robin_classifier: weights must not be negative, got $weights")
    any(w -> w > 0, weights) ||
        error("weighted_round_robin_classifier: at least one weight must be positive")
    # Where the cycle currently is: which output, and how many of its run are
    # left. Held in the closure, so the state travels with the classifier.
    output = Ref(0)
    remaining = Ref(0)
    PacketClassifierModule(name; outputs = length(weights),
        classifier = function (_, _packet)
            while remaining[] <= 0
                output[] = output[] % length(weights) + 1
                remaining[] = weights[output[]]
            end
            remaining[] -= 1
            output[]
        end)
end

"""
    markov_classifier(name, transitions; initial = 1) -> PacketClassifierModule

A classifier whose choice is a random walk: it is in one of `n` states, sends
each packet out of the output its state names, and then moves on according to
`transitions[state]` — a vector of probabilities over the next state.

Where a weighted round robin gives exact shares in a fixed order, this gives
the same long-run shares in a *bursty* order: a state that mostly returns to
itself sends runs of packets one way before switching, which is what makes
traffic clumped rather than evenly interleaved.
"""
function markov_classifier(name::Symbol, transitions::AbstractVector;
                           initial::Int = 1, seed::Int = 0)
    states = length(transitions)
    all(row -> length(row) == states, transitions) ||
        error("markov_classifier: each of the $states rows must give $states probabilities")
    (1 <= initial <= states) ||
        error("markov_classifier: initial state $initial is not one of the $states states")
    state = Ref(initial)
    rng = MersenneTwister(seed)
    PacketClassifierModule(name; outputs = states,
        classifier = function (_, _packet)
            current = state[]
            # Move first or last? Last: the packet leaves by the state the
            # classifier was IN, so the initial state is the first one used.
            state[] = _markov_step(transitions[current], rng)
            current
        end)
end

# One draw from a row of probabilities, by cumulative sum. A row that does not
# quite add up to one lands on the last state, which is the forgiving reading.
function _markov_step(row, rng::MersenneTwister)
    draw = rand(rng)
    total = 0.0
    for index in 1:length(row)
        total += row[index]
        draw <= total && return index
    end
    length(row)
end

function NetworkModule.initialize_module!(::Network, m::PacketClassifierModule)
    m.producer = resolve_interface(m.in, ActivePacketSource; mandatory = false)
    m.consumers = [resolve_interface(gate, PassivePacketSink) for gate in m.out]
    m
end

NetworkModule.register_module_statistics!(m::PacketClassifierModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_icon(::PacketClassifierModule) = "block/classifier"

function NetworkModule.finish_module!(m::PacketClassifierModule, ::Any)
    record_statistic!(m.recording, "packets:count", m.num_packets)
    for index in 1:length(m.per_output)
        record_statistic!(m.recording, "packets[$index]:count", m.per_output[index])
    end
    nothing
end

PacketProtocolModule.can_push_some_packet(m::PacketClassifierModule, ::Gate) =
    any(consumer -> can_push_some_packet(consumer), m.consumers)

# Asking the same function that will place the packet, so a classifier never
# accepts one it would then have nowhere to put.
function PacketProtocolModule.can_push_packet(m::PacketClassifierModule, ::Gate, packet::Packet)
    index = m.classifier(m, packet)
    index == 0 && return false
    can_push_packet(m.consumers[index], packet)
end

function PacketProtocolModule.push_packet!(ctx, m::PacketClassifierModule, ::Gate, packet::Packet)
    index = m.classifier(m, packet)
    (1 <= index <= length(m.consumers)) ||
        error("push_packet!: $(m.name) has no output for this packet (chose $index of " *
              "$(length(m.consumers))) — the producer pushed without asking whether it could")
    m.num_packets += 1
    m.per_output[index] += 1
    emit_statistic!(m.recording, ctx, :packetLengths, bits(data_length(packet)))
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
