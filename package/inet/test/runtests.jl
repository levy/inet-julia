# What only holds once the components are assembled.
#
#     julia --project=package/inet/test -e 'using InetTest; test_inet()'

using Test

@testset "umbrella" begin
    include("catalog.jl")
end
