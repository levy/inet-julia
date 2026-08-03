using Test
using OmnetppSimulator
using Inet
using ProjecturedKernel.ReferenceModule: Reference, FieldReferenceStep, ElementReferenceStep

# The packet & chunk API suite lives in its own package now:
#   julia --project=package/packet/test -e 'using InetPacketTest; test_packet()'

# The 10BASE-T1S / PLCA suite lives in its own package now:
#   julia --project=package/linklayer/test -e 'using InetLinkLayerTest; test_linklayer()'

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
