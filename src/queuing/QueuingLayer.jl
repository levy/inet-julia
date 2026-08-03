# ── Queuing layer — a fragment of Inet ─────────────────────────────────────
#
# The queuing model elements: sources and sinks, queues, servers, classifiers,
# schedulers, filters and the plumbing between them. INET spells the directory
# `queueing`; here it is the standard spelling.
#
# The contract comes first — the four roles a module plays at a gate and the
# methods each answers — then what elements share, then every element as its own
# submodule.
include("contract/PacketProtocol.jl")

include("base/Statistics.jl")           # what a module records about its run
include("base/PacketSource.jl")         # the packets a source hands out

include("source/ActivePacketSource.jl")   # produces and pushes
include("source/PassivePacketSource.jl")  # has one ready to be pulled
include("sink/PassivePacketSink.jl")      # accepts what is pushed at it
include("sink/ActivePacketSink.jl")       # pulls, on its own schedule
include("queue/PacketQueue.jl")           # holds packets between the two
include("server/PacketServer.jl")         # serves one at a time, taking time
include("server/InstantServer.jl")        # moves them on, taking none
