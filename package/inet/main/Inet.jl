module Inet

# ============================================================================
# `Inet` — the umbrella over the network-model library.
#
# The split mirrors the C++ world: `OmnetppSimulator` is the discrete-event
# kernel (the engine, the lifecycle, result recording) and `Inet` is what you
# model networks *with*. The dependency runs one way only — `Inet` uses
# `OmnetppSimulator`, never the reverse.
#
# The library itself is four packages, each usable on its own:
#
#   InetPacket     the packet & chunk API — depends on nothing
#   InetCommon     module lookup, the infrastructure the models share
#   InetQueuing    the queuing elements and the packet protocol they speak
#   InetLinkLayer  10BASE-T1S / PLCA and the model that runs it
#
# This package re-exports their modules and owns the one thing none of them
# can: `inet_simulation_catalog`, which has to know every model there is.
#
# Nothing from `OmnetppSimulator` is re-exported. A script that needs both says
# `using OmnetppSimulator, Inet`, so it stays visible which layer a name comes from.
# ============================================================================

using InetPacket
using InetCommon
using InetQueuing
using InetLinkLayer

# The workbench's model catalog, which `inet_simulation_catalog` extends.
using OmnetppSimulator: SimulationType, default_simulation_catalog

include("Catalog.jl")            # inet_simulation_catalog — the kernel's, extended
# A packet as the ASCII art figure the RFCs draw. It lives here because it needs
# a packet and the editor stack at once, and no component below has both.
include("packetdiagram/PacketDiagram.jl")
using .PacketDiagramModule

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
    # the model interface implementations the lifecycle drives
    QueuingModel, AQueuingModel, QueuingModel,
    T1sModel, AT1sModel, T1sModel,
    # every model there is, offered to a workbench
    inet_simulation_catalog,
    # a packet as the ASCII art figure the RFCs draw — a submodule, so
    # `using Inet.PacketDiagramModule` to get its names
    PacketDiagramModule

end # module Inet
