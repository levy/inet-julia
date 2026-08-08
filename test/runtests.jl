# Repository-wide test entry point. Runs every component's suite in one process
# from the root environment:
#
#     julia --project=. test/runtests.jl
#
# To run one component instead, activate its own environment (each resolves
# standalone — the packet suite, for one, needs no simulator at all):
#
#     julia --project=package/packet/test    -e 'using InetPacketTest;    test_packet()'
#     julia --project=package/queuing/test   -e 'using InetQueuingTest;   test_queuing()'
#     julia --project=package/linklayer/test -e 'using InetLinkLayerTest; test_linklayer()'
#     julia --project=package/inet/test      -e 'using InetTest;          test_inet()'
#     julia --project=package/runner/test    -e 'using InetRunnerTest;    test_runner()'

using Test

using InetPacketTest
using InetQueuingTest
using InetLinkLayerTest
using InetTest
using InetRunnerTest

@testset "inet-julia" begin
    InetPacketTest.test_packet()
    InetQueuingTest.test_queuing()
    InetLinkLayerTest.test_linklayer()
    InetTest.test_inet()
    InetRunnerTest.test_runner()
end
