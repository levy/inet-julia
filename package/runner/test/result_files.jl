# ============================================================================
# The result files — the names, the run name, the attributes, read back.
#
# The header is checked against the shape of a C++ file, not against a string
# this test wrote: `opp_scavetool` and the readers of OmnetppLegacy key on it,
# and a Julia file and a C++ file of one configuration are meant to be compared
# with one tool (plan/pending/native-simulation-binary.md §4.6).
# ============================================================================
using Test
using Dates: DateTime
using InetRunner
using InetRunner.ResultFilesModule: scalar_file_path, vector_file_path,
    result_run_name, result_run_attributes, result_datetime

# The `attr` lines of a result file, as name => value.
function _attributes(path)
    pairs = Pair{String,String}[]
    for line in readlines(path)
        startswith(line, "attr ") || continue
        parts = split(line, ' '; limit = 3)
        length(parts) == 3 || continue
        push!(pairs, strip(parts[2], '"') => strip(parts[3], '"'))
    end
    Dict(pairs)
end

_run_line(path) = strip(split(first(filter(l -> startswith(l, "run "), readlines(path))),
                              ' '; limit = 2)[2], '"')

@testset "the result files" begin

    @testset "the names are the ones opp_run writes" begin
        @test scalar_file_path("results", "PacketQueue", 0) == "results/PacketQueue-#0.sca"
        @test vector_file_path("results", "PacketQueue", 3) == "results/PacketQueue-#3.vec"
    end

    @testset "the run name says which run, when, and by which process" begin
        moment = DateTime(2026, 8, 8, 11, 35, 28)
        @test result_datetime(moment) == "20260808-11:35:28"
        @test result_run_name("PacketQueue", 0, moment, 178086) ==
              "PacketQueue-0-20260808-11:35:28-178086"
    end

    @testset "the attributes are named and sorted" begin
        moment = DateTime(2026, 8, 8, 11, 35, 28)
        attributes = result_run_attributes(config = "PacketQueue", run_number = 0,
                                           network = "PacketQueueTutorialStep",
                                           moment = moment, process_id = 178086,
                                           ini_file = "omnetpp.ini")
        @test first.(attributes) == ["configname", "datetime", "inifile",
                                     "network", "processid", "runnumber"]
        values = Dict(attributes)
        @test values["configname"] == "PacketQueue"
        @test values["datetime"] == "20260808-11:35:28"
        @test values["inifile"] == "omnetpp.ini"
        @test values["network"] == "PacketQueueTutorialStep"
        @test values["processid"] == "178086"
        @test values["runnumber"] == "0"
    end

    @testset "a run writes both files, with the header it promised" begin
        mktempdir() do directory
            buffer = IOBuffer()
            code = InetRunner.main(["-c", "Queuing", "-r", "0", "-f", "queuing.ini",
                                    "--result-dir=$directory"]; io = buffer)
            @test code == 0

            scalar_path = joinpath(directory, "Queuing-#0.sca")
            vector_path = joinpath(directory, "Queuing-#0.vec")
            @test isfile(scalar_path)
            @test isfile(vector_path)

            # The run name identifies the run in both files, and it is the
            # same name in both — that is what joins them.
            name = _run_line(scalar_path)
            @test startswith(name, "Queuing-0-")
            @test _run_line(vector_path) == name

            attributes = _attributes(scalar_path)
            @test attributes["configname"] == "Queuing"
            @test attributes["runnumber"] == "0"
            @test attributes["network"] == "Queuing"
            @test attributes["inifile"] == "queuing.ini"
            @test attributes["processid"] == string(getpid())
            @test occursin(r"^\d{8}-\d\d:\d\d:\d\d$", attributes["datetime"])

            # The run name carries the datetime and the process id, so the
            # header cannot say one thing and the name another.
            @test occursin(attributes["datetime"], name)
            @test endswith(name, "-" * attributes["processid"])

            # The .vec file holds the time series the model declared, not just
            # a header — the queue records its length.
            vector_lines = readlines(vector_path)
            @test any(line -> occursin("queueLength:vector", line), vector_lines)
        end
    end
end
