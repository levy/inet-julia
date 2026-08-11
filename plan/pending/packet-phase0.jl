# Phase 0 of `packet-is-a-document.md` — the baseline every later phase is
# compared against.
#
#     julia -t 4 --project=. plan/pending/packet-phase0.jl
#
# Allocations are the measure. They count exactly, where a wall-clock ratio
# flakes under load. Times are printed for orientation only.
#
# Beware a folded loop: a microbenchmark whose result is unused optimises away
# and reports zero. Every result here is kept in `SINK`, and every subject is
# reached through a global the compiler cannot see through.

using Printf
using InetPacket
using InetPacket.PacketModule
using ProjecturedKernel.DocumentModule: Document, document_schema_name
using InetLinkLayer
using InetLinkLayer.T1sModule: build_ethernet_frame

const SINK = Ref{Any}(nothing)
const HELD = Any[]

hold(x) = (push!(HELD, x); length(HELD))

"Allocations and time for `n` repetitions of `f()`, with the result kept."
function measure(label, f, n)
    SINK[] = f()                                   # warm
    a = @allocated (for _ in 1:n; SINK[] = f(); end)
    t = @elapsed  (for _ in 1:n; SINK[] = f(); end)
    @printf("  %-34s %12d bytes  %10d /rep  %8.4f s\n", label, a, a ÷ n, t)
    (label = label, total = a, per = a ÷ n, time = t)
end

println("── isbits, every chunk type as it is today ──")
# A document's own type name is its cell layout with every cell spelled out, so
# the schema name is what a reader wants here.
name(T) = T <: Document ? string(document_schema_name(T)) : string(T)
for T in (Filler, Raw, Sequence, Packet)
    @printf("  %-34s isbits=%-6s sizeof=%s\n", name(T), isbitstype(T),
            isbitstype(T) ? string(sizeof(T)) : "—")
end
# The two parametric ones need a concrete parameter before the question means
# anything, which is the whole point of §5.1.
let f = Filler(BitLength(64))
    @printf("  %-34s isbits=%-6s sizeof=%s\n", "Slice{Filler}",
            isbitstype(Slice{Filler}), sizeof(Slice{Filler}))
    SINK[] = f
end

println("\n── the hot paths ──")
const N = 100_000
payload = Raw(rand(UInt8, 46))
hold(payload)

results = Any[
    measure("build_ethernet_frame",
            () -> build_ethernet_frame(0x001122334455, 0x00AABBCCDDEE, 0x0800, HELD[1]),
            N),
]

frame = build_ethernet_frame(0x001122334455, 0x00AABBCCDDEE, 0x0800, payload)
hold(frame)
push!(results, measure("dup(frame)", () -> dup(HELD[2]), N))

println("\n── written into the plan by hand from this output ──")
