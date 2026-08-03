# Queuing model elements and the framework they rest on
# (plan/pending/queuing-model-migration.md).
#
#     julia --project=package/queuing/test -e 'using InetQueuingTest; test_queuing()'

using Test

@testset "queuing" begin
    include("support.jl")
    include("phase0_lookup.jl")
    include("phase1_sources_sinks.jl")
    include("phase2_queue_server.jl")
    include("phase3_classify_schedule_filter.jl")
    include("phase4_plumbing_compound.jl")
end
