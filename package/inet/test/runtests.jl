# What only holds once the components are assembled.
#
#     julia --project=package/inet/test -e 'using InetTest; test_inet()'

using Test

@testset "umbrella" begin
    # The package shape the whole repository rests on, asserted where the
    # components are already assembled. See documentation/packages.md.
    include("packagegraph.jl")
    include("catalog.jl")
    # The demo catalog spans packet, queuing and link layer, so it is only
    # walkable once the components are assembled — which makes it the
    # umbrella's job too.
    include("demo.jl")
    # The packet diagram: a packet drawn as the figure the RFCs use. It needs a
    # packet and the editor stack at once, which only the umbrella has.
    include("packetdiagram.jl")
end
