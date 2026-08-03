module Inet

# ============================================================================
# `Inet` — the model library that sits on top of `OmnetppSimulator`.
#
# The split mirrors the C++ world: `OmnetppSimulator` is the discrete-event kernel (the
# engine, the lifecycle, result recording) and `Inet` is the network-model
# library (packet representation, protocol models). The dependency runs one
# way only — `Inet` uses `OmnetppSimulator`, never the reverse.
#
# Nothing from `OmnetppSimulator` is re-exported. A script that needs both says
# `using OmnetppSimulator, Inet`, so it stays visible which layer a name comes from.
# ============================================================================

# Packet & chunk API (plan/done/packet-chunk-api.md). Its own package, because
# it depends on neither `OmnetppSimulator` nor the rest of this library.
using InetPacket.PacketModule

# --- what the protocol models need from the kernel --------------------------
# Time, scheduling and the engine/model interface.
using OmnetppSimulator: SimTime, TIME_UNIT, to_simtime, MersenneTwister,
    ScheduleContext, schedule!, schedule_root!, stop!,
    AbstractEngine, AbstractParallelEngine, AbstractModel, SimTimeLimit
# Parameterization: a model declares its degrees of freedom, the lifecycle
# resolves them and hands back a `ResolvedParameters`.
using OmnetppSimulator: Parameter, ParameterSpace, AbstractResolvedParameters,
    StructuralDOF, StochasticDOF, IterationDOF
# Result recording.
using OmnetppSimulator: Recorder, VectorFileWriter, begin_recording!,
    register_indexed_vector!, emit_indexed_vector!, record_scalar!
# The workbench's model catalog, which `inet_simulation_catalog` extends.
using OmnetppSimulator: SimulationType, default_simulation_catalog
# The model interface itself — `import`, not `using`, because `Inet`'s models
# add methods to these.
import OmnetppSimulator: model_module_count, model_barrier_module, model_delay_edges,
    model_description, model_parameter_space, build_model, reset_model!,
    schedule_initial_events!, make_recorder, finalize_model!
# Models are `@document`s so a running simulation can be viewed reactively: the
# sim runs on the native (mutable) variant at full speed and a reactive variant
# is refreshed for the UI. The macro's expansion needs `Reference` and the cell
# primitives in scope, which is why they are imported alongside it.
using ProjecturedKernel.DocumentModule: Document, sync_document!, @document
using ProjecturedKernel.ReferenceModule: Reference
using ProjecturedKernel.CellModule: ImmutableCell, set_cell_function!

# Module lookup: how a module gets hold of another that offers an interface,
# by walking the connections or by evaluating a reference. Independent of what
# is being looked for, so it comes before the models that look things up.
include("lookup/Lookup.jl")
using .LookupModule

# Queuing model elements, and the packet protocol they speak
# (plan/pending/queuing-model-migration.md).
include("queuing/QueuingLayer.jl")
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
using .PacketClassifierElement
using .PacketSchedulerElement
using .PacketFilterElement
using .PacketPlumbingElement
using .PriorityQueueElement

# 10BASE-T1S / PLCA multidrop model — its own package (InetLinkLayer).
using InetLinkLayer

include("model/QueuingModel.jl")       # QueuingModel — the canonical chain as a model
include("model/Catalog.jl")            # inet_simulation_catalog — the kernel's, extended

export
    # packet & chunk API — a submodule, so `using Inet.PacketModule` to get its names
    PacketModule,
    # finding a module that offers an interface, by connection or by reference
    LookupModule,
    # the four roles a module plays at a gate, and how packets move between them
    PacketProtocolModule,
    # what queuing elements share: recording, and the packets a source makes
    StatisticsModule, PacketSourceModule,
    # the queuing elements, each its own submodule
    ActivePacketSourceElement, PassivePacketSourceElement,
    PassivePacketSinkElement, ActivePacketSinkElement,
    PacketQueueElement, PacketServerElement, InstantServerElement,
    PacketClassifierElement, PacketSchedulerElement, PacketFilterElement,
    PacketPlumbingElement, PriorityQueueElement,
    # 10BASE-T1S / PLCA building blocks (FSMs, PHY, wire, MAC, app)
    T1sModule,
    # the model interface implementation the lifecycle drives
    QueuingModel, AbstractQueuingModel, QueuingModelMut,
    T1sModel, AbstractT1sModel, T1sModelMut,
    inet_simulation_catalog

end # module Inet
