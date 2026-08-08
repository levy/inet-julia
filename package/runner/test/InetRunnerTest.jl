"""
    InetRunnerTest

Test package for `InetRunner`. Exposes `test_runner()` so the suite is callable
from a REPL and from the repository-wide aggregator, alongside the
`runtests.jl` script that `Pkg.test` conventions expect.

`test_runner_closure()` is separable, and worth running alone: it is a static
walk of `[deps]` and `[sources]`, it needs nothing instantiated, and it is the
one thing that keeps the editor out of the executable.
"""
module InetRunnerTest

using Test

"""
    test_runner()

Run the whole `InetRunner` suite: the closure guard, the command line, the run.
"""
function test_runner()
    @testset "InetRunner" begin
        include(joinpath(@__DIR__, "runtests.jl"))
    end
end

"""
    test_runner_closure()

Run the dependency-closure guard alone.
"""
function test_runner_closure()
    @testset "InetRunner closure" begin
        include(joinpath(@__DIR__, "closure.jl"))
    end
end

const test_all = test_runner

export test_runner, test_runner_closure, test_all

end # module InetRunnerTest
