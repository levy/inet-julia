# The acceptance test of the NED and INI path: two configurations of INET's
# queueing tutorial, built and run from the original files, checked against the
# C++ results captured in `inet-reference/queueing/`.
#
# Nothing is copied. The two files are read where they are, in the `inet-cpp`
# checkout beside this repository, so an edit there shows up here rather than
# drifting apart in silence.

using OmnetppDescription
using InetRunner: register_queuing_ned_types!

# The `inet-cpp` checkout, or nothing when it is absent.
function _inet_root()
    path = normpath(joinpath(@__DIR__, "..", "..", "..", "..", "inet-cpp"))
    isdir(path) ? path : nothing
end

_reference_dir() = joinpath(@__DIR__, "inet-reference", "queueing")

"""
    reference_scalars(config) -> Dict{Tuple{String,String},Float64}

Every scalar of a captured C++ run, keyed by module path and statistic name.

The `.sca` format writes one `scalar <module> <name> <value>` per line, and
that is all this needs — reading it here rather than restating the numbers
means the test checks the file, not a transcription of it.
"""
function reference_scalars(config::AbstractString)
    path = joinpath(_reference_dir(), "$config-#0.sca")
    out = Dict{Tuple{String,String},Float64}()
    for line in eachline(path)
        m = match(r"^scalar\s+(\S+)\s+(\S+)\s+(\S+)\s*$", line)
        m === nothing && continue
        value = tryparse(Float64, m.captures[3])
        value === nothing && continue
        out[(m.captures[1], m.captures[2])] = value
    end
    out
end

"""
    run_configuration(config; seed) -> (network, recorder, configuration)

Build and run one configuration of the tutorial, from the two original files.
"""
function run_configuration(config::AbstractString; seed::Int = 0)
    root = _inet_root()
    ini = joinpath(root, "tutorials", "queueing", "omnetpp.ini")
    ned = joinpath(root, "tutorials", "queueing", "QueueingTutorial.ned")

    configuration = read_ini_configuration(ini, config)
    resolution = ParameterResolution(configuration)
    network = build_ned_network(ned, configuration.network, resolution)

    recorder = Recorder(capture_vectors = false)
    run_network!(network; until = configuration.sim_time_limit, recorder = recorder)
    (network, recorder, configuration, resolution)
end

function test_ned_ini()
@testset "from the original NED and INI" begin

register_queuing_ned_types!()
root = _inet_root()

if root === nothing
    @test_skip "inet-cpp is not beside this repository"
else

@testset "ActiveSourcePassiveSink, exactly" begin
    # Every parameter of this configuration is a constant, so the run draws
    # nothing and the numbers are not a matter of tolerance. Eleven packets of
    # one byte, at t = 0, 1, … 10 s.
    network, recorder, configuration, resolution = run_configuration("ActiveSourcePassiveSink")
    net = configuration.network

    @test net == "ProducerConsumerTutorialStep"
    @test configuration.sim_time_limit == 10.0
    @test sort([String(module_name(m)) for m in network.modules]) == ["consumer", "producer"]
    @test isempty(unused_rules(resolution))

    reference = reference_scalars("ActiveSourcePassiveSink")
    for (module_, name) in [("producer", "packets:count"),
                            ("producer", "packetLengths:sum"),
                            ("consumer", "packets:count"),
                            ("consumer", "packetLengths:sum")]
        expected = reference[("$net.$module_", name)]
        actual = statistic_scalar(recorder, "$net.$module_", name)
        @test actual == expected
    end

    # And the numbers themselves, so a reference file that changed is visible
    # rather than merely self-consistent.
    @test statistic_scalar(recorder, "$net.producer", "packets:count") == 11
    @test statistic_scalar(recorder, "$net.producer", "packetLengths:sum") == 88
end

@testset "PacketQueue, by range" begin
    # This configuration draws `uniform(0s, 1s)` and `uniform(0s, 2s)`. The
    # stream is not OMNeT++'s — every module here has its own, and OMNeT++ maps
    # them all onto generator 0 — so the counts follow a different sequence and
    # only their distribution is comparable.
    network, recorder, configuration, resolution = run_configuration("PacketQueue")
    net = configuration.network

    @test net == "PacketQueueTutorialStep"
    @test sort([String(module_name(m)) for m in network.modules]) ==
          ["collector", "producer", "queue"]
    @test isempty(unused_rules(resolution))

    queue = only(m for m in network.modules if module_name(m) === :queue)
    @test queue.parameters.packet_capacity === nothing   # the INI sets none here

    produced = statistic_scalar(recorder, "$net.producer", "packets:count")
    collected = statistic_scalar(recorder, "$net.collector", "packets:count")
    reference = reference_scalars("PacketQueue")

    # A mean interval of 0.5 s over 10 s is about 20 productions, and a mean
    # collection interval of 1 s is about 10 collections. The C++ run gives 18
    # and 9. Both sides must land in the same neighbourhood.
    @test 12 <= produced <= 28
    @test 6 <= collected <= 14
    @test collected <= produced
    @test 12 <= reference[("$net.producer", "packets:count")] <= 28
    @test 6 <= reference[("$net.collector", "packets:count")] <= 14

    # Conservation: what the source made is what the sink took, plus what the
    # queue still holds. This holds exactly, whatever the stream.
    @test produced == collected + length(queue.states.packets)
end

end # inet-cpp present
end # @testset
end # test_ned_ini
