module Inet

# ============================================================================
# `Inet` — the model library that sits on top of `Omnetpp`.
#
# The split mirrors the C++ world: `Omnetpp` is the discrete-event kernel (the
# engine, the lifecycle, result recording) and `Inet` is the network-model
# library (packet representation, protocol models). The dependency runs one
# way only — `Inet` uses `Omnetpp`, never the reverse.
# ============================================================================

# Packet & chunk API (plan/done/packet-chunk-api.md). Standalone: depends on
# neither `Omnetpp` nor the rest of this package, so it comes first.
include("packet/Packet.jl")
using .PacketModule

export PacketModule

end # module Inet
