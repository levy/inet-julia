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
    add_module!, module_path, @simulation_module
using ..PacketQueueElement: PacketQueueModule, queue_length, queue_bit_length
using ..PacketClassifierElement: PacketClassifierModule, priority_classifier,
    content_based_classifier
using ..PacketSchedulerElement: PacketSchedulerModule, priority_scheduler

export PriorityQueueModule, priority_queue, priority_queue_length,
       priority_queue_bit_length, priority_queue_dropped

"""
    PriorityQueueModule(name; priorities, given_classifier = nothing, queue_parameters = (;))

A classifier, one queue per priority and a scheduler, behind a pair of boundary
gates — declared as what it holds and how its parts are joined.

By default packets go to the first level that will take them, so a full level
overflows into the next. `given_classifier` replaces that with one built some
other way, by [`content_based_classifier`](@ref), say. `queue_parameters` is
the keywords a level's queue is built with, as a named tuple — either one set
for every level or one per level.

[`priority_queue`](@ref) builds one and places it in a network in a single
call, which is how the rest of this package uses it.
"""
@simulation_module struct PriorityQueueModule <: AbstractCompoundModule
    @parameters begin
        priorities::Int                                # no default: how many levels?
        given_classifier::Any = nothing
        queue_parameters::Any = (;)
    end
    @gates begin
        in::InputGate
        out::OutputGate
    end
    @submodules begin
        classifier::PacketClassifierModule =
            given_classifier === nothing ? priority_classifier(:classifier, priorities) :
                                           given_classifier
        queues::Vector{PacketQueueModule} =
            [PacketQueueModule(:queue; _level_parameters(queue_parameters, priorities, level)...)
             for level in 1:priorities]
        scheduler::PacketSchedulerModule = priority_scheduler(:scheduler, priorities)
    end
    @connections begin
        # The boundary gates are wired inward, so a chain reaches the classifier
        # and the scheduler by walking through the compound rather than around
        # it.
        in => classifier.in
        for level in 1:priorities
            classifier.out[level] => queues[level].in
            queues[level].out => scheduler.in[level]
        end
        scheduler.out => out
    end
end

# One set of keywords for every level, or one per level.
function _level_parameters(given, priorities::Int, level::Int)
    given isa AbstractVector || return given
    length(given) == priorities ||
        error("PriorityQueueModule: $(length(given)) sets of queue parameters for " *
              "$priorities levels")
    given[level]
end

"""
    priority_queue(network, name, priorities; classifier = nothing, queue_parameters = ...)
        -> PriorityQueueModule

Build a priority queue of `priorities` levels and place it in `network`.

The compound builds and wires its own parts, and placing it places them too, so
this is one call over [`PriorityQueueModule`](@ref) and nothing more.
"""
priority_queue(network::Network, name::Symbol, priorities::Int;
               classifier::Union{Nothing,PacketClassifierModule} = nothing,
               queue_parameters = (;)) =
    add_module!(network, PriorityQueueModule(name; priorities = priorities,
                                             given_classifier = classifier,
                                             queue_parameters = queue_parameters))

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
