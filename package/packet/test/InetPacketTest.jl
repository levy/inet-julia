"""
    InetPacketTest

Test package for `InetPacket`. Exposes `test_packet()` so the suite is callable
from a REPL and from the repository-wide aggregator, alongside the
`runtests.jl` script that `Pkg.test` conventions expect.

The suite body lives in `runtests.jl` as one `@testset` per phase of
`plan/done/packet-chunk-api.md`; `test_packet()` includes it inside one
enclosing testset.
"""
module InetPacketTest

using Test

"""
    test_packet()

Run the whole `InetPacket` conformance suite.
"""
function test_packet()
    @testset "InetPacket" begin
        include(joinpath(@__DIR__, "runtests.jl"))
    end
end

const test_all = test_packet

export test_packet, test_all

end # module InetPacketTest
