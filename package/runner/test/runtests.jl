# The command-line runner and the executable built from it
# (plan/pending/native-simulation-binary.md).
#
#     julia --project=package/runner/test -e 'using InetRunnerTest; test_runner()'

using Test

@testset "runner" begin
    # The guard runs first. It is the cheapest test here and the one whose
    # failure makes every other result beside the point.
    include("closure.jl")
    include("command_line.jl")
    include("run.jl")
    include("result_files.jl")
end
