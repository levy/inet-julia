using Test
using OmnetppSimulator
using Inet
using ProjecturedKernel.ReferenceModule: Reference, FieldReferenceStep, ElementReferenceStep

# Packet & chunk API (plan/done/packet-chunk-api.md) — phased conformance
# suite; each phase adds a file.
@testset "packet & chunk API" begin
    include("packet/phase1_chunks.jl")
    include("packet/phase2_packet.jl")
    include("packet/phase3_headers.jl")
    include("packet/phase4_quality.jl")
    include("packet/phase5_tags.jl")
    include("packet/phase6_buffers.jl")
    include("packet/phase7_inspect.jl")
end

# 10BASE-T1S / PLCA multidrop model (plan/done/ten-base-t1s-plca.md).
@testset "10BASE-T1S / PLCA" begin
    include("t1s/phase1_frame.jl")
    include("t1s/phase2_phy.jl")
    include("t1s/phase3_junction.jl")
    include("t1s/phase4_plca_control.jl")
    include("t1s/phase5_plca_data.jl")
    include("t1s/phase6_mac.jl")
    include("t1s/phase7_plca_recovery.jl")
    include("t1s/phase8_app.jl")
    include("t1s/phase9_model.jl")
    # Statistics phases (plan/done/ten-base-t1s-statistics.md)
    include("t1s/phase2_stats_core.jl")
    include("t1s/phase3_stats_fsm.jl")
    include("t1s/phase4_stats_counts.jl")
    include("t1s/phase5_stats_mac.jl")
    include("t1s/phase6_stats_phy.jl")
    include("t1s/phase7_vec_reader.jl")
    include("t1s/phase8_compare_harness.jl")
end

# Queuing model elements and the framework they rest on
# (plan/pending/queuing-model-migration.md).
@testset "queuing" begin
    include("queuing/support.jl")
    include("queuing/phase0_lookup.jl")
    include("queuing/phase1_sources_sinks.jl")
    include("queuing/phase2_queue_server.jl")
    include("queuing/phase3_classify_schedule_filter.jl")
    include("queuing/phase4_plumbing_compound.jl")
end
