# ── Queuing layer — a fragment of Inet ─────────────────────────────────────
#
# The queuing model elements: sources and sinks, queues, servers, classifiers,
# schedulers, filters and the plumbing between them. INET spells the directory
# `queueing`; here it is the standard spelling.
#
# The contract comes first — the four roles a module plays at a gate and the
# methods each answers — and every element is its own submodule below it.
include("contract/PacketProtocol.jl")
