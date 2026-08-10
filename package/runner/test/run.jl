# ============================================================================
# The run — the exit codes, and the file a finished run leaves behind.
#
# A runner is driven by scripts, so its exit code is its report: 0 the run
# finished, 1 the command line is wrong, 2 the run failed
# (plan/done/native-simulation-binary.md §4.4).
#
# Every run here reads the unmodified `inet-cpp/tutorials/queueing` files where
# they sit. Nothing is copied: an edit there shows up here rather than drifting
# apart in silence. When that checkout is absent the runs are skipped and the
# command-line half still runs.
# ============================================================================
using Test
using InetRunner

# Run `arguments` with stdout captured, and answer (code, output).
function _run(arguments)
    buffer = IOBuffer()
    code = InetRunner.main(arguments; io = buffer)
    (code, String(take!(buffer)))
end

# The `inet-cpp` checkout, or nothing when it is absent.
function _inet_root()
    path = normpath(joinpath(@__DIR__, "..", "..", "..", "..", "inet-cpp"))
    isdir(path) ? path : nothing
end

_tutorial() = joinpath(_inet_root(), "tutorials", "queueing")

@testset "the run" begin

    @testset "a text exits 0" begin
        code, output = _run(["-h"])
        @test code == 0
        @test occursin("Usage:", output)
        code, output = _run(["--version"])
        @test code == 0
        @test occursin("inet-julia", output)
    end

    @testset "a wrong command line exits 1" begin
        # `--sim-time-limit` is honoured now, so the wrong command line here is
        # an option that still does not exist.
        @test first(_run(["--fast-forward=3"])) == 1
        @test first(_run(["--workers=4"])) == 1          # without --engine=parallel
        @test first(_run(["-u", "Qtenv"])) == 1
        @test first(_run(["-r", "-2"])) == 1
    end

    @testset "a run that cannot be made exits 2" begin
        # No INI file where the command line says one is.
        @test first(_run(["-f", "/nonexistent/nope.ini", "-c", "General"])) == 2
        # A run number a single configuration does not have.
        @test first(_run(["-r", "1"])) == 2
    end

    if _inet_root() === nothing
        @test_skip "inet-cpp is not beside this repository"
    else
        ini = joinpath(_tutorial(), "omnetpp.ini")

        @testset "a finished run exits 0 and leaves both result files" begin
            mktempdir() do directory
                code, output = _run(["-f", ini, "-c", "ActiveSourcePassiveSink",
                                     "-r", "0", "--result-dir=$directory"])
                @test code == 0
                @test occursin("Network ProducerConsumerTutorialStep", output)
                @test occursin("QueueingTutorial.ned", output)
                @test occursin("Finished:", output)

                scalar_path = joinpath(directory, "ActiveSourcePassiveSink-#0.sca")
                @test isfile(scalar_path)
                @test isfile(joinpath(directory, "ActiveSourcePassiveSink-#0.vec"))

                # The module and the statistic are in the two columns OMNeT++
                # writes them in, not both in the second one.
                lines = readlines(scalar_path)
                @test any(l -> occursin("\"ProducerConsumerTutorialStep.producer\"", l) &&
                               occursin("\"packets:count\"", l), lines)
            end
        end

        @testset "a configuration that is not there exits 2 and names it" begin
            code, _ = _run(["-f", ini, "-c", "NoSuchConfiguration"])
            @test code == 2
        end

        @testset "a NED path with no such network exits 2 and says where it looked" begin
            mktempdir() do empty_directory
                code, _ = _run(["-f", ini, "-c", "ActiveSourcePassiveSink",
                                "-n", empty_directory])
                @test code == 2
            end
        end

        @testset "the result directory is created" begin
            mktempdir() do directory
                nested = joinpath(directory, "deep", "results")
                @test first(_run(["-f", ini, "-c", "ActiveSourcePassiveSink",
                                  "--result-dir=$nested"])) == 0
                @test isdir(nested)
            end
        end
    end
end
