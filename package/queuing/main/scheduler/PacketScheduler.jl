"""
    PacketSchedulerElement

**The join**: several sources of packets, one output, and a rule for whose turn
it is.

It is the mirror of the classifier and works on the pull side: whoever pulls
from its output gets a packet chosen from among its inputs. The choice is a
Julia function of the module, returning which input to take from — INET's
scheduler classes and their NED parameters become one element with a different
function in it. [`priority_scheduler`](@ref) takes from the first input that has
anything, which is what makes a set of queues a priority queue.

Because the choice is asked afresh for every question — is there anything to
pull, what would it be, hand it over — a scheduler holds nothing itself and
follows its inputs as they fill and empty.
"""
module PacketSchedulerElement

using OmnetppSimulator: NetworkModule, MersenneTwister
using OmnetppSimulator.NetworkModule: AbstractModule, Gate, Network, module_id,
    @simulation_module, decorate_module!
using InetPacket.PacketModule: Packet, bits, data_length
using InetCommon.LookupModule: ModuleRef, NO_MODULE_REF, InterfaceClaim, ForwardClaim,
    resolve_interface, is_resolved
using ..PacketProtocolModule: PacketProtocolModule, PassivePacketSource, ActivePacketSink,
    can_pull_some_packet, can_pull_packet, pull_packet!,
    handle_can_pull_packet_changed!
using ..StatisticsModule: ModuleStatistics, register_statistics!, emit_statistic!,
    record_statistic!

export PacketSchedulerModule,
       priority_scheduler, weighted_round_robin_scheduler, markov_scheduler,
       scheduler_inputs

"""
    PacketSchedulerModule(name; inputs, scheduler)

The module, declared by the kind of each of its fields.

`scheduler` is `(m) -> Int`: which input the next packet comes from, counting
from one, or `0` when none of them has anything. `inputs` is how many inputs
there are, and it sizes the gate vector and the per-input count.
"""
@simulation_module struct PacketSchedulerModule
    @parameters begin
        inputs::Int                                    # no default: a join of what?
        scheduler::Any
    end
    @gates begin
        in::Vector{InputGate} = inputs
        out::OutputGate
    end
    @variables begin
        providers::Vector{ModuleRef} = ModuleRef[]
        collector::ModuleRef = NO_MODULE_REF
    end
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_packets::Int = 0
        per_input::Vector{Int} = zeros(Int, inputs)
    end
end

# The claims a lookup reads off the gates, set before any lookup walks the
# wiring. A scheduler pulls from each input, but only if something pulls from it
# in turn — it stores nothing, so it is a collector only by proxy.
function NetworkModule.decorate_module!(m::PacketSchedulerModule)
    for gate in m.in
        push!(gate.annotations, ForwardClaim(ActivePacketSink, :out))
    end
    push!(m.out.annotations, InterfaceClaim(PassivePacketSource))
    m
end

const STATISTIC_NAMES = (:packetLengths,)

"""
    scheduler_inputs(m) -> Int

How many inputs the scheduler has.
"""
scheduler_inputs(m::PacketSchedulerModule) = length(m.in)

"""
    priority_scheduler(name, inputs) -> PacketSchedulerModule

A scheduler that takes from the first input that has anything, so earlier
inputs are served completely before later ones get a turn. A classifier feeding
a queue per priority, drained by one of these, is a priority queue.
"""
priority_scheduler(name::Symbol, inputs::Int) =
    PacketSchedulerModule(name; inputs = inputs,
        scheduler = function (m)
            for index in 1:length(m.providers)
                can_pull_some_packet(m.providers[index]) && return index
            end
            0
        end)

"""
    weighted_round_robin_scheduler(name, weights) -> PacketSchedulerModule

A scheduler that takes a run of `weights[i]` packets from input `i` before
moving on, cycling forever, and skips an input with nothing to give rather than
stalling on it.

That last part is the difference from the classifier: a scheduler is asked
whether it *can* pull at all, so an input that is empty must not be able to
block the ones behind it. An empty input therefore forfeits the rest of its
run.
"""
function weighted_round_robin_scheduler(name::Symbol, weights::AbstractVector{<:Integer})
    all(w -> w >= 0, weights) ||
        error("weighted_round_robin_scheduler: weights must not be negative, got $weights")
    any(w -> w > 0, weights) ||
        error("weighted_round_robin_scheduler: at least one weight must be positive")
    input = Ref(0)
    remaining = Ref(0)
    PacketSchedulerModule(name; inputs = length(weights),
        scheduler = function (m)
            providers = m.providers
            # The input whose turn it is, when it has something.
            if remaining[] > 0 && can_pull_some_packet(providers[input[]])
                remaining[] -= 1
                return input[]
            end
            # Otherwise walk the cycle looking for one that has. A full turn
            # with nothing anywhere means there is nothing to pull.
            for _ in 1:length(weights)
                input[] = input[] % length(weights) + 1
                weights[input[]] == 0 && continue
                if can_pull_some_packet(providers[input[]])
                    remaining[] = weights[input[]] - 1
                    return input[]
                end
            end
            remaining[] = 0
            0
        end)
end

"""
    markov_scheduler(name, transitions; initial = 1, seed = 0) -> PacketSchedulerModule

A scheduler whose choice is a random walk over its inputs: it takes from the
input its state names and then moves on according to `transitions[state]`.

Like the Markov classifier it produces bursts rather than an even interleaving.
Unlike it, a state whose input is empty cannot simply be honoured — the
scheduler is asked whether it can pull at all — so the walk advances and the
next state that has something is used. The state machine therefore drifts
towards the inputs that actually have traffic, which is the honest reading of
"take from this one next".
"""
function markov_scheduler(name::Symbol, transitions::AbstractVector;
                          initial::Int = 1, seed::Int = 0)
    states = length(transitions)
    all(row -> length(row) == states, transitions) ||
        error("markov_scheduler: each of the $states rows must give $states probabilities")
    (1 <= initial <= states) ||
        error("markov_scheduler: initial state $initial is not one of the $states states")
    state = Ref(initial)
    rng = MersenneTwister(seed)
    PacketSchedulerModule(name; inputs = states,
        scheduler = function (m)
            providers = m.providers
            for _ in 1:states
                current = state[]
                state[] = _markov_scheduler_step(transitions[current], rng)
                can_pull_some_packet(providers[current]) && return current
            end
            0
        end)
end

# One draw from a row of probabilities, by cumulative sum; a row that does not
# quite add up to one lands on the last state.
function _markov_scheduler_step(row, rng::MersenneTwister)
    draw = rand(rng)
    total = 0.0
    for index in 1:length(row)
        total += row[index]
        draw <= total && return index
    end
    length(row)
end

function NetworkModule.initialize_module!(::Network, m::PacketSchedulerModule)
    m.providers = [resolve_interface(gate, PassivePacketSource) for gate in m.in]
    m.collector = resolve_interface(m.out, ActivePacketSink)
    m
end

NetworkModule.register_module_statistics!(m::PacketSchedulerModule, path::AbstractString, recorder) =
    register_statistics!(m.recording, recorder, path, STATISTIC_NAMES)

NetworkModule.module_icon(::PacketSchedulerModule) = "block/join"

function NetworkModule.finalize_module!(m::PacketSchedulerModule, ::Any)
    record_statistic!(m.recording, "packets:count", m.num_packets)
    for index in 1:length(m.per_input)
        record_statistic!(m.recording, "packets[$index]:count", m.per_input[index])
    end
    nothing
end

PacketProtocolModule.can_pull_some_packet(m::PacketSchedulerModule, ::Gate) =
    m.scheduler(m) != 0

function PacketProtocolModule.can_pull_packet(m::PacketSchedulerModule, ::Gate)
    index = m.scheduler(m)
    index == 0 ? nothing : can_pull_packet(m.providers[index])
end

function PacketProtocolModule.pull_packet!(ctx, m::PacketSchedulerModule, ::Gate)
    index = m.scheduler(m)
    index == 0 &&
        error("pull_packet!: none of $(m.name)'s inputs has a packet — the collector " *
              "pulled without asking whether it could")
    packet = pull_packet!(ctx, m.providers[index])
    m.num_packets += 1
    m.per_input[index] += 1
    emit_statistic!(m.recording, ctx, :packetLengths, bits(data_length(packet)))
    packet
end

# Any input filling up may change the answer for the whole scheduler, so the
# news is passed on to whoever pulls from it.
function PacketProtocolModule.handle_can_pull_packet_changed!(ctx, m::PacketSchedulerModule,
                                                              ::Gate)
    is_resolved(m.collector) && handle_can_pull_packet_changed!(ctx, m.collector)
    nothing
end

end # module
