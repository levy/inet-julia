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
    # Communication capture over the ModuleRef seams
    # (omnetpp-julia plan/pending/observable-communication.md, Phase 3).
    include("phase5_capture.jl")
    # The NED and INI path: two tutorial configurations run from the original
    # files (omnetpp-julia plan/pending/first-run-from-ned-ini.md, Phase 6).
    # The glue that says which Julia type each NED type name means now lives in
    # `InetRunner`, because the shipped executable needs it and a test is not
    # shipped (plan/done/native-simulation-binary.md §4.8).
    include("nedini.jl")
    test_ned_ini()
    # The tutorial as a reader meets it: every page loads, every embed resolves,
    # and every step's simulation runs to its limit
    # (plan/done/queuing-tutorial-migration.md). It moved here from the example
    # package, which must not depend on `Test`.
    include("tutorial.jl")
    test_tutorial()
end
