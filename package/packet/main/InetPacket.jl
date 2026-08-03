module InetPacket

# ============================================================================
# `InetPacket` — the packet & chunk API (design: plan/done/packet-chunk-api.md).
#
# A representation-independent packet data model, derived from INET's
# `Chunk`/`Packet` API but redesigned around Julia's type system: a 1500-byte
# payload nobody inspects costs one integer, and asking for a header type
# yields one whether the packet currently holds a field struct, raw bytes, or
# just a length.
#
# The API itself lives in the `PacketModule` submodule, which is what users
# import (`using InetPacket.PacketModule`); this file is the package's entry
# point and re-exports it.
# ============================================================================

include("Packet.jl")
using .PacketModule

export PacketModule

end # module InetPacket
