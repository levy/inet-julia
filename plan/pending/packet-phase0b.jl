# Phase 0, part two — a whole simulated run, and the count that decides open
# question 0: how many envelope field accesses does one simulated event make?
#
#     julia -t 4 --project=. plan/pending/packet-phase0b.jl
#
# The count is measured, not estimated: `Packet` is temporarily given a
# `getproperty`/`setproperty!` pair that tallies. That pair exists only here, in
# this script, and is never committed to the package.

using Printf
using OmnetppSimulator
using InetPacket, InetPacket.PacketModule
using InetLinkLayer, InetLinkLayer.T1sModule

# ── the counting hook ────────────────────────────────────────────────────────
# `Packet` is a plain mutable struct, so a field access is a `getfield`. These
# two methods intercept the dotted form, which is what every call site writes.
const READS = Ref(0)
const WRITES = Ref(0)

Base.getproperty(pk::Packet, n::Symbol) = (READS[] += 1; getfield(pk, n))
Base.setproperty!(pk::Packet, n::Symbol, v) = (WRITES[] += 1; setfield!(pk, n, v))

run_t1s(scenario, limit) =
    let t = SimulationType(T1sModel),
        a = ParameterAssignment(Dict{Symbol,Any}(
                :n_nodes => 5, :time_limit => limit, :scenario => scenario)),
        r = expand_simulation(configure_simulation(t, a))[1],
        ex = make_execution(r; engine = SequentialEngineSpec())
        run_execution!(ex)
        finish_execution!(ex)
    end

for scenario in (:notraffic, :bestcase)
    READS[] = 0; WRITES[] = 0
    res = run_t1s(scenario, 200e-6)
    a = @allocated run_t1s(scenario, 200e-6)
    reads, writes = READS[] ÷ 2, WRITES[] ÷ 2      # two runs were counted
    total = reads + writes
    @printf("%-11s  %10d bytes   envelope reads=%-8d writes=%-8d total=%d\n",
            scenario, a, reads, writes, total)
    @printf("             a reactive envelope would add %d bytes (16 per access), %.1f%% of the run\n",
            16 * total, 100 * 16 * total / max(a, 1))
end
