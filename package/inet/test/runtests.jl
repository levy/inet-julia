# What only holds once the components are assembled.
#
#     julia --project=package/inet/test -e 'using InetTest; test_inet()'

using Test

@testset "umbrella" begin
    include("catalog.jl")
    # The demo catalog spans packet, queuing and link layer, so it is only
    # walkable once the components are assembled — which makes it the
    # umbrella's job too.
    include("demo.jl")
end
