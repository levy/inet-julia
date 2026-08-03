"""
    InetQueuingTest

Test package for `InetQueuing`. Exposes `test_queuing()` so the suite is
callable from a REPL and from the repository-wide aggregator, alongside the
`runtests.jl` script that `Pkg.test` conventions expect.

The suite body lives in `runtests.jl`: `support.jl` first (the stub modules and
the harness that runs them inside a real `SequentialSimulator`), then one file
per wave of `plan/pending/queuing-model-migration.md`. Phase 0 tests
`InetCommon`'s lookup — it is written against the packet-protocol interfaces,
so it belongs on this side of the dependency edge rather than in a test package
below.
"""
module InetQueuingTest

using Test

"""
    test_queuing()

Run the whole `InetQueuing` suite, module lookup included.
"""
function test_queuing()
    @testset "InetQueuing" begin
        include(joinpath(@__DIR__, "runtests.jl"))
    end
end

const test_all = test_queuing

export test_queuing, test_all

end # module InetQueuingTest
