"""
    PriorityQueueElement

**A queue made of queues**: one queue per priority, filled by a classifier and
drained highest-first by a scheduler, presented as a single queue.

This is the first compound module — one built by composition rather than by
behaviour. It owns submodules and the connections between them and does nothing
itself: its own gates are boundary gates, wired inward, and everything that
crosses them passes straight through to the classifier and the scheduler.

That is what makes it interesting as a shape. A lookup for something to push
into walks through the boundary and is answered by the classifier inside; a
lookup for something to pull from is answered by the scheduler. Nothing outside
knows the difference between this and a plain queue, and nothing inside knows
it is wrapped. The one thing the compound does provide is the view of the whole:
its length is its parts' lengths added up.
"""
module PriorityQueueElement

using OmnetppSimulator: NetworkModule
using OmnetppSimulator.NetworkModule: AbstractCompoundModule, Gate, Network,
    input_gate, output_gate, connect!, add_module!, module_path
using ..PacketQueueElement: PacketQueueModule, queue_length, queue_bit_length
using ..PacketClassifierElement: PacketClassifierModule, priority_classifier,
    content_based_classifier
using ..PacketSchedulerElement: PacketSchedulerModule, priority_scheduler

export PriorityQueueModule, priority_queue, priority_queue_length,
       priority_queue_bit_length, priority_queue_dropped

"""
    PriorityQueueModule

A classifier, one queue per priority and a scheduler, behind a pair of boundary
gates. Build one with [`priority_queue`](@ref).
"""
mutable struct PriorityQueueModule <: AbstractCompoundModule
    name::Symbol
    module_id::Int
    in::Gate
    out::Gate
    classifier::PacketClassifierModule
    queues::Vector{PacketQueueModule}
    scheduler::PacketSchedulerModule
end

"""
    priority_queue(network, name, priorities; classifier = nothing, queue_parameters = ...)
        -> PriorityQueueModule

Build a priority queue of `priorities` levels in `network` and register it and
its submodules.

By default packets go to the first level that will take them, so a full level
overflows into the next; pass `classifier` — built with
[`content_based_classifier`](@ref), say — to decide by what is in the packet
instead. `queue_parameters` is the keywords a level's queue is built with, as a
named tuple — either one set for every level or one per level.
"""
function priority_queue(network::Network, name::Symbol, priorities::Int;
                        classifier::Union{Nothing,PacketClassifierModule} = nothing,
                        queue_parameters = (;))
    fork = classifier === nothing ? priority_classifier(:classifier, priorities) : classifier
    parameters = queue_parameters isa AbstractVector ? queue_parameters :
                 fill(queue_parameters, priorities)
    length(parameters) == priorities ||
        error("priority_queue: $(length(parameters)) sets of queue parameters for " *
              "$priorities levels")

    compound = PriorityQueueModule(
        name, 0,
        input_gate(nothing, :in), output_gate(nothing, :out),
        fork, PacketQueueModule[], priority_scheduler(:scheduler, priorities))
    compound.in.owner = compound
    compound.out.owner = compound
    add_module!(network, compound)

    add_module!(network, fork; parent = compound)
    for level in 1:priorities
        queue = PacketQueueModule(Symbol(:queue, level); parameters[level]...)
        push!(compound.queues, queue)
        add_module!(network, queue; parent = compound)
    end
    add_module!(network, compound.scheduler; parent = compound)

    # The boundary gates are wired inward, so a chain reaches the classifier and
    # the scheduler by walking through the compound rather than around it.
    connect!(compound.in, fork.in)
    for level in 1:priorities
        connect!(fork.out[level], compound.queues[level].in)
        connect!(compound.queues[level].out, compound.scheduler.in[level])
    end
    connect!(compound.scheduler.out, compound.out)
    compound
end

NetworkModule.submodules(m::PriorityQueueModule) =
    Any[m.classifier, m.queues..., m.scheduler]

"""
    priority_queue_length(m) -> Int

How many packets the whole priority queue holds, over all its levels. The
compound has nothing of its own to report, so it asks its parts — which is all
a compound's view of itself ever is.
"""
priority_queue_length(m::PriorityQueueModule) = sum(queue_length, m.queues)

"""
    priority_queue_bit_length(m) -> Int

How much data the whole priority queue holds, in bits.
"""
priority_queue_bit_length(m::PriorityQueueModule) = sum(queue_bit_length, m.queues)

"""
    priority_queue_dropped(m) -> Int

How many packets the levels dropped between them.
"""
priority_queue_dropped(m::PriorityQueueModule) =
    sum(queue -> queue.num_dropped, m.queues)

end # module
