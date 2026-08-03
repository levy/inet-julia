# 10BASE-T1S / PLCA (plan/done/ten-base-t1s-plca.md) — phased conformance
# suite, followed by the statistics phases
# (plan/done/ten-base-t1s-statistics.md).
#
#     julia --project=package/linklayer/test -e 'using InetLinkLayerTest; test_linklayer()'

using Test

@testset "10BASE-T1S / PLCA" begin
    include("phase1_frame.jl")
    include("phase2_phy.jl")
    include("phase3_junction.jl")
    include("phase4_plca_control.jl")
    include("phase5_plca_data.jl")
    include("phase6_mac.jl")
    include("phase7_plca_recovery.jl")
    include("phase8_app.jl")
    include("phase9_model.jl")
    # Statistics phases
    include("phase2_stats_core.jl")
    include("phase3_stats_fsm.jl")
    include("phase4_stats_counts.jl")
    include("phase5_stats_mac.jl")
    include("phase6_stats_phy.jl")
    include("phase7_vec_reader.jl")
    include("phase8_compare_harness.jl")
end
