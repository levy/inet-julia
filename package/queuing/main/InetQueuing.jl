module InetQueuing

# ============================================================================
# `InetQueuing` — the queuing model elements: sources and sinks, queues,
# servers, classifiers, schedulers, filters and the plumbing between them, plus
# the packet protocol they speak to each other. INET spells the directory
# `queueing`; here it is the standard spelling.
# Design: plan/pending/queuing-model-migration.md.
#
# Nothing from `OmnetppSimulator` is re-exported: a script that needs both says
# `using OmnetppSimulator, InetQueuing`, so it stays visible which layer a name
# comes from.
# ============================================================================

# What travels between the elements, and how one finds the next.
using InetPacket.PacketModule
using InetCommon.LookupModule

# --- what a model built from these elements needs from the kernel -----------
# Time, scheduling and the engine/model interface.
using OmnetppSimulator: SimTime, to_simtime, ZERO_DELAY, schedule_event!, schedule_root!, stop!,
    AbstractEngine, AbstractModel, LimitReached
# Parameterization: a model declares its degrees of freedom, the lifecycle
# resolves them and hands back a `ResolvedParameters`.
using OmnetppSimulator.ConfigurationModule: configure, deep, PerSite, owner
using OmnetppSimulator: Parameter, ParameterSpace, AResolvedParameters,
    StructuralDOF, StochasticDOF
# The model interface itself — `import`, not `using`, because `QueuingModel`
# adds methods to these.
import OmnetppSimulator: model_module_count, model_barrier_module, model_delay_edges,
    model_description, model_parameter_space, build_model, reset_model!,
    schedule_initial_events!, finalize_model!, model_topology
# Models are `@document`s so a running simulation can be viewed reactively: the
# sim runs on the native (mutable) variant at full speed and a reactive variant
# is refreshed for the UI. The macro's expansion needs `Reference` and the cell
# primitives in scope, which is why they are imported alongside it.
using ProjecturedKernel.DocumentModule: Document, sync_document!, @document,
                                        @document_preset

# A model the engine runs is the native one, so that is what its bare name means.
# `ACQueuingModel` is its cell twin, which is what an editor holds.
@document_preset native_document [M, C]
using ProjecturedKernel.ReferenceModule: Reference
using ProjecturedKernel.CellModule: ImmutableCell, set_cell_function!

# The contract comes first — the four roles a module plays at a gate and the
# methods each answers — then what elements share, then every element as its own
# submodule.
include("contract/PacketProtocol.jl")

include("base/Statistics.jl")           # what a module records about its run
include("base/PacketSource.jl")         # the packets a source hands out
include("base/PacketPredicates.jl")     # the questions elements ask about a packet

include("source/ActivePacketSource.jl")   # produces and pushes
include("source/PassivePacketSource.jl")  # has one ready to be pulled
include("sink/PassivePacketSink.jl")      # accepts what is pushed at it
include("sink/ActivePacketSink.jl")       # pulls, on its own schedule
include("queue/PacketQueue.jl")           # holds packets between the two
include("server/PacketServer.jl")         # serves one at a time, taking time
include("server/InstantServer.jl")        # moves them on, taking none
include("classifier/PacketClassifier.jl") # one way in, several ways out
include("scheduler/PacketScheduler.jl")   # several ways in, one way out
include("filter/PacketFilter.jl")         # passes some on, drops the rest

# Composition — the elements that join other elements, and the compound that is
# built out of them.
include("composition/PacketPlumbing.jl")  # merging, splitting, delaying
include("composition/PacketMarking.jl")   # labelling, cloning, duplicating
include("composition/PriorityQueue.jl")   # a queue made of queues

# What the elements add up to: a network the lifecycle can run and sweep.
using .PacketProtocolModule
using .StatisticsModule
using .PacketSourceModule
using .ActivePacketSourceElement
using .PassivePacketSourceElement
using .PassivePacketSinkElement
using .ActivePacketSinkElement
using .PacketQueueElement
using .PacketServerElement
using .InstantServerElement
using .PacketPredicateModule
using .PacketClassifierElement
using .PacketSchedulerElement
using .PacketFilterElement
using .PacketPlumbingElement
using .PacketMarkingModule
using .PriorityQueueElement

include("QueuingModel.jl")              # the canonical chain as a model
# The library's observation seams: every resolved ModuleRef becomes an
# observation point; packets crossing push/pull are recorded by a
# forwarding proxy (omnetpp-julia plan/pending/observable-communication.md P3).
include("QueuingCapture.jl")


# ── The seed of every rng, as a rule ────────────────────────────────────────
#
# Each element declares a `seed::Int` parameter and used to seed its own rng
# from it: `@stream rng::MersenneTwister = MersenneTwister(seed)`. The module
# macro refuses that, and says why — "a module that fixed its own seed would
# draw the same values in every replicate of a run" — so an rng's seed is a
# parameter at `rng.seed` that a configuration answers.
#
# So a network says which of its elements starts where, BY NAME:
#
#     Network(:Push; rules = queuing_rng_rules(source = 5, server = 6))
#
# An element nobody names starts at 0, which is what its `seed::Int = 0` default
# gave it. The parameter itself is gone: a seed is not a property of a module, it
# is what a configuration says about that module's generator, and saying it in
# two places is what this plan removes.
#
# `omnetpp-julia plan/pending/random-number-generators.md` phase 7.
# A name computed in a loop — `source1`, `source2`, … — cannot be a keyword, so
# pairs are taken positionally beside them:
#
#     queuing_rng_rules((Symbol(:source, i) => m.seed + i for i in 1:n)...)
function queuing_rng_rules(pairs::Pair...; seeds...)
    configure(net -> begin
        # The old default first; a named element overwrites it, because a log
        # resolves in program order and the last write wins.
        deep(net).rng.seed = 0
        for (name, seed) in Iterators.flatten((pairs, seeds))
            getproperty(net, Symbol(name)).rng.seed = seed
        end
    end)
end

export
    queuing_rng_rules,
    # the four roles a module plays at a gate, and how packets move between them
    PacketProtocolModule,
    # what queuing elements share: recording, and the packets a source makes
    StatisticsModule, PacketSourceModule,
    # the queuing elements, each its own submodule
    ActivePacketSourceElement, PassivePacketSourceElement,
    PassivePacketSinkElement, ActivePacketSinkElement,
    PacketQueueElement, PacketServerElement, InstantServerElement,
    PacketPredicateModule,
    PacketClassifierElement, PacketSchedulerElement, PacketFilterElement,
    PacketPlumbingElement, PacketMarkingModule, PriorityQueueElement,
    # the model interface implementation the lifecycle drives
    QueuingModel, AQueuingModel, QueuingModel

end # module InetQueuing
