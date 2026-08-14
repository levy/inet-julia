module InetLinkLayer

# ============================================================================
# `InetLinkLayer` — the link-layer protocol models.
#
# Today that is 10BASE-T1S with PLCA (IEEE 802.3cg-2019): four FSMs (MAC, PLCA
# control, PLCA data, PHY) over a first-class wire junction, plus the
# `AbstractModel` wrapper that plugs the whole network into the
# `OmnetppSimulator` lifecycle. Design: plan/done/ten-base-t1s-plca.md and
# plan/done/ten-base-t1s-statistics.md.
#
# Nothing from `OmnetppSimulator` is re-exported: a script that needs both says
# `using OmnetppSimulator, InetLinkLayer`, so it stays visible which layer a
# name comes from.
# ============================================================================

# What the packets on the wire are made of.
using InetPacket.PacketModule

# --- what the protocol models need from the kernel --------------------------
# Time, scheduling and the engine/model interface.
using OmnetppSimulator: SimTime, to_simtime, EventContext, schedule_event!,
    schedule_root!, stop!, AbstractEngine, AParallelEngine, AbstractModel,
    LimitReached
# Parameterization: a model declares its degrees of freedom, the lifecycle
# resolves them and hands back a `ResolvedParameters`.
using OmnetppSimulator: Parameter, ParameterSpace, AResolvedParameters,
    StructuralDOF, StochasticDOF, IterationDOF
# Result recording.
using OmnetppSimulator: Recorder, attach_sink!, OmnetppTextSink,
    register_indexed_vector!, emit_indexed_vector!
# The model interface itself — `import`, not `using`, because the models here
# add methods to these.
import OmnetppSimulator: model_module_count, model_barrier_module, model_delay_edges,
    model_description, model_parameter_space, build_model, reset_model!,
    schedule_initial_events!, make_recorder
# Models are `@document`s so a running simulation can be viewed reactively: the
# sim runs on the native (mutable) variant at full speed and a reactive variant
# is refreshed for the UI. The macro's expansion needs `Reference` and the cell
# primitives in scope, which is why they are imported alongside it.
using ProjecturedKernel.DocumentModule: Document, sync_document!, @document,
                                        @document_preset

# The model the engine runs is the native one; `ACT1sModel` is its cell twin.
@document_preset native_document [M, C]
using ProjecturedKernel.ReferenceModule: Reference
using ProjecturedKernel.CellModule: ImmutableCell, set_cell_function!

# 10BASE-T1S / PLCA: the building blocks, then the model that wires them into a
# multidrop network and drives it from the lifecycle.
include("t1s/T1s.jl")
include("t1s/T1sModel.jl")
# The stack's observation seams: attach_capture_seams! re-wraps the layer
# boundary slots wired above, so a capture observes T1S with no protocol
# code involved (omnetpp-julia plan/pending/observable-communication.md P2).
include("t1s/T1sCapture.jl")

export
    # 10BASE-T1S / PLCA building blocks (FSMs, PHY, wire, MAC, app)
    T1sModule,
    # the model interface implementation the lifecycle drives
    T1sModel, AT1sModel, T1sModel

end # module InetLinkLayer
