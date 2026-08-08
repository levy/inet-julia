# ============================================================================
# The C++ comparison — the runner's own numbers against `opp_run`'s.
#
# The reference files are the ones the companion plan captured, under
# `package/queuing/test/inet-reference/queueing/`, with a `PROVENANCE.md` that
# records the `inet-cpp` commit and the exact command. Nothing is copied: this
# reads the `.sca` the runner wrote and the `.sca` the C++ run wrote, and
# compares the two.
#
# Level 1 is the structure — the modules the network has. Level 2 is the
# recorded statistics. The two levels are defined in
# plan/pending/queueing-tutorial-from-ned-ini.md §4.3.
# ============================================================================
using Test
using InetRunner

_inet_root() = let path = normpath(joinpath(@__DIR__, "..", "..", "..", "..", "inet-cpp"))
    isdir(path) ? path : nothing
end

_reference_dir() = normpath(joinpath(@__DIR__, "..", "..", "queuing", "test",
                                     "inet-reference", "queueing"))

"""
    scalars_of(path) -> Dict{Tuple{String,String},Float64}

Every scalar of a `.sca` file, keyed by module path and statistic name.

One reader for both sides. The C++ writer quotes a column only when it has to
and this one always quotes, so the quotes come off here rather than in a second
parser written for one of them.
"""
function scalars_of(path::AbstractString)
    found = Dict{Tuple{String,String},Float64}()
    for line in eachline(path)
        m = match(r"^scalar\s+(\"[^\"]*\"|\S+)\s+(\"[^\"]*\"|\S+)\s+(\S+)\s*$", line)
        m === nothing && continue
        value = tryparse(Float64, m.captures[3])
        value === nothing && continue
        found[(strip(m.captures[1], '"'), strip(m.captures[2], '"'))] = value
    end
    found
end

@testset "against the C++ result" begin
    if _inet_root() === nothing
        @test_skip "inet-cpp is not beside this repository"
    else
        ini = joinpath(_inet_root(), "tutorials", "queueing", "omnetpp.ini")

        @testset "ActiveSourcePassiveSink, exactly" begin
            # Every parameter of this configuration is a constant, so the run
            # draws nothing and the numbers are not a matter of tolerance.
            mktempdir() do directory
                code = InetRunner.main(["-f", ini, "-c", "ActiveSourcePassiveSink",
                                        "-r", "0", "--result-dir=$directory"];
                                       io = IOBuffer())
                @test code == 0

                ours = scalars_of(joinpath(directory, "ActiveSourcePassiveSink-#0.sca"))
                theirs = scalars_of(joinpath(_reference_dir(),
                                             "ActiveSourcePassiveSink-#0.sca"))
                net = "ProducerConsumerTutorialStep"

                # Level 1 — the network has the modules the NED declares, and
                # the result file is what says so.
                @test sort(unique(first.(keys(ours)))) == ["$net.consumer", "$net.producer"]

                # Level 2 — and the numbers are the C++ numbers.
                for key in [("$net.producer", "packets:count"),
                            ("$net.producer", "packetLengths:sum"),
                            ("$net.consumer", "packets:count"),
                            ("$net.consumer", "packetLengths:sum")]
                    @test haskey(theirs, key)
                    @test ours[key] == theirs[key]
                end

                # And the numbers themselves, so a reference file that changed
                # is visible rather than merely self-consistent.
                @test ours[("$net.producer", "packets:count")] == 11
                @test ours[("$net.producer", "packetLengths:sum")] == 88
            end
        end

        @testset "PacketQueue, by range" begin
            # This configuration draws `uniform(0s, 1s)` and `uniform(0s, 2s)`.
            # Every module here has a stream of its own and OMNeT++ maps them
            # all onto generator 0, so the counts follow a different sequence
            # and only their distribution is comparable.
            mktempdir() do directory
                code = InetRunner.main(["-f", ini, "-c", "PacketQueue", "-r", "0",
                                        "--result-dir=$directory"]; io = IOBuffer())
                @test code == 0

                ours = scalars_of(joinpath(directory, "PacketQueue-#0.sca"))
                theirs = scalars_of(joinpath(_reference_dir(), "PacketQueue-#0.sca"))
                net = "PacketQueueTutorialStep"

                @test sort(unique(first.(keys(ours)))) ==
                      ["$net.collector", "$net.producer", "$net.queue"]

                produced = ours[("$net.producer", "packets:count")]
                collected = ours[("$net.collector", "packets:count")]

                # A mean interval of 0.5 s over 10 s is about 20 productions,
                # and a mean collection interval of 1 s about 10. Both sides
                # must land in the same neighbourhood.
                @test 12 <= produced <= 28
                @test 6 <= collected <= 14
                @test collected <= produced
                @test 12 <= theirs[("$net.producer", "packets:count")] <= 28
                @test 6 <= theirs[("$net.collector", "packets:count")] <= 14
            end
        end
    end
end
