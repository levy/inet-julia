"""
    InetLinkLayerTest

Test package for `InetLinkLayer`. Exposes `test_linklayer()` so the suite is
callable from a REPL and from the repository-wide aggregator, alongside the
`runtests.jl` script that `Pkg.test` conventions expect.

The suite body lives in `runtests.jl` as one file per phase of
`plan/done/ten-base-t1s-plca.md` and `plan/done/ten-base-t1s-statistics.md`;
`test_linklayer()` includes it inside one enclosing testset.
"""
module InetLinkLayerTest

using Test

"""
    test_linklayer()

Run the whole `InetLinkLayer` suite: the 10BASE-T1S / PLCA conformance phases,
the statistics phases, and the golden-hash model tests.
"""
function test_linklayer()
    @testset "InetLinkLayer" begin
        include(joinpath(@__DIR__, "runtests.jl"))
    end
end

const test_all = test_linklayer

export test_linklayer, test_all

end # module InetLinkLayerTest
