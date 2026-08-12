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
using InetQueuing
using ProjecturedKernelTest: check_layering

# The layers of `InetQueuing`, in the order `InetQueuing.jl` includes them. A
# file under one of these folders may import a module from its own layer or a
# lower one, never a higher one. The model files sit at the package root, in no
# layer folder, and the guard exempts them — they are what the layers add up to
# and they read from all of them.
const LAYERS = ["contract", "base",
                "source", "sink", "queue", "server", "classifier", "scheduler",
                "filter",
                "composition"]

"""
    test_queuing_layering()

Static layered-architecture guard for `InetQueuing`. It reads the sources
without loading them: every file is included exactly once, each module is
defined by one file, the include order is a valid topological sort over the
imports, and no layer imports from a higher one.
"""
function test_queuing_layering()
    main = normpath(dirname(pathof(InetQueuing)))
    check_layering(main, joinpath(main, "InetQueuing.jl");
                   name = "queuing", layers = LAYERS,
                   # `QueuingModel.jl` and `QueuingCapture.jl` are fragments in
                   # the package root's own namespace, and they name the
                   # package's submodules. That is the same shape `T1sModel.jl`
                   # and `T1sCapture.jl` have, and decision D3 of
                   # plan/done/folder-layout-alignment.md keeps it: a model
                   # wrapper is the slice's face to the lifecycle and a capture
                   # file its face to the observation machinery, so both sit
                   # outside the slice's inner module.
                   allow_root_fragments = true)
end

"""
    test_queuing()

Run the whole `InetQueuing` suite: the layering guard, then the elements and
the module lookup.
"""
function test_queuing()
    @testset "InetQueuing" begin
        test_queuing_layering()
        include(joinpath(@__DIR__, "runtests.jl"))
    end
end

const test_all = test_queuing

export test_queuing, test_queuing_layering, test_all

end # module InetQueuingTest
