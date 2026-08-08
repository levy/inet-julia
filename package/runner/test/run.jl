# ============================================================================
# The run — the exit codes, and the file a finished run leaves behind.
#
# A runner is driven by scripts, so its exit code is its report: 0 the run
# finished, 1 the command line is wrong, 2 the run failed
# (plan/pending/native-simulation-binary.md §4.4).
# ============================================================================
using Test
using InetRunner

# Run `arguments` with stdout captured, and answer (code, output).
function _run(arguments)
    buffer = IOBuffer()
    code = InetRunner.main(arguments; io = buffer)
    (code, String(take!(buffer)))
end

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
        @test first(_run(["--sim-time-limit=100s"])) == 1
        @test first(_run(["-u", "Qtenv"])) == 1
        @test first(_run(["-r", "-2"])) == 1
    end

    @testset "a run that cannot be made exits 2" begin
        @test first(_run(["-c", "NoSuchConfiguration"])) == 2
        # The configuration exists and fans out into one run, so #1 does not.
        @test first(_run(["-c", "Queuing", "-r", "1"])) == 2
    end

    @testset "a finished run exits 0 and leaves a result file" begin
        mktempdir() do directory
            code, output = _run(["-c", "Queuing", "-r", "0",
                                 "--result-dir=$directory"])
            @test code == 0
            @test occursin("Finished:", output)
            scalar_path = joinpath(directory, "Queuing-#0.sca")
            @test isfile(scalar_path)
            content = read(scalar_path, String)
            @test occursin("version", content)
            @test occursin("scalar", content)
        end
    end

    @testset "the result directory is created" begin
        mktempdir() do directory
            nested = joinpath(directory, "deep", "results")
            @test first(_run(["-c", "Queuing", "--result-dir=$nested"])) == 0
            @test isdir(nested)
        end
    end
end
