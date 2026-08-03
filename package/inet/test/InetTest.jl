"""
    InetTest

Test package for the `Inet` umbrella. Exposes `test_inet()` so the suite is
callable from a REPL and from the repository-wide aggregator, alongside the
`runtests.jl` script that `Pkg.test` conventions expect.

It covers only what needs the components assembled — the model catalog, and the
promise that `using Inet.PacketModule` still reaches a component's module
through the umbrella. Everything else is tested by the component that owns it.
"""
module InetTest

using Test

"""
    test_inet()

Run the umbrella's own suite: the model catalog and the re-export surface.
"""
function test_inet()
    @testset "Inet" begin
        include(joinpath(@__DIR__, "runtests.jl"))
    end
end

const test_all = test_inet

export test_inet, test_all

end # module InetTest
