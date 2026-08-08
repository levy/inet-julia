# ============================================================================
# The command line — what each option does, and what a wrong one says.
#
# An option outside the set is an error and not a silence: an ignored
# --sim-time-limit produces a run that is wrong in a way no output shows
# (plan/pending/native-simulation-binary.md §4.4).
# ============================================================================
using Test
using InetRunner
using InetRunner.CommandLineModule: Options, CommandLineError, parse_command_line,
    ned_directories, help_text, version_text

@testset "the command line" begin

    @testset "defaults" begin
        options = parse_command_line(String[])
        @test options.ini_files == ["omnetpp.ini"]
        @test options.config == "General"
        @test options.run == 1                  # the command line said 0
        @test options.ned_path == String[]
        @test options.result_dir == "results"
    end

    @testset "the options that take a value" begin
        options = parse_command_line(["-f", "a.ini", "-f", "b.ini",
                                      "-c", "TestNetwork", "-r", "3",
                                      "-n", "ned:more/ned", "-u", "Cmdenv",
                                      "--result-dir=out"])
        @test options.ini_files == ["a.ini", "b.ini"]
        @test options.config == "TestNetwork"
        @test options.run == 4                  # the command line said 3
        @test options.ned_path == ["ned", "more/ned"]
        @test options.result_dir == "out"
    end

    @testset "the run number counts from 0 outside and 1 inside" begin
        @test parse_command_line(["-r", "0"]).run == 1
        @test parse_command_line(["-r", "7"]).run == 8
        @test_throws CommandLineError parse_command_line(["-r", "-1"])
        @test_throws CommandLineError parse_command_line(["-r", "two"])
    end

    @testset "the NED path defaults to the directory of the INI file" begin
        options = parse_command_line(["-f", "/tmp/study/omnetpp.ini"])
        @test ned_directories(options) == ["/tmp/study"]
        options = parse_command_line(["-f", "/tmp/study/omnetpp.ini", "-n", "/elsewhere"])
        @test ned_directories(options) == ["/elsewhere"]
    end

    @testset "only Cmdenv" begin
        @test parse_command_line(["-u", "Cmdenv"]).config == "General"
        @test_throws CommandLineError parse_command_line(["-u", "Qtenv"])
    end

    @testset "a text is asked for, not a run" begin
        @test parse_command_line(["-h"]) === :help
        @test parse_command_line(["--help"]) === :help
        @test parse_command_line(["-v"]) === :version
        @test parse_command_line(["--version"]) === :version
        # A text wins wherever it appears, so `-c X -h` still explains itself.
        @test parse_command_line(["-c", "X", "-h"]) === :help
        @test occursin("--result-dir", help_text())
        @test occursin("inet-julia", version_text())
    end

    @testset "what is refused" begin
        # The one that matters: an option this build does not honour must not
        # be quietly dropped.
        @test_throws CommandLineError parse_command_line(["--sim-time-limit=100s"])
        @test_throws CommandLineError parse_command_line(["-x"])
        @test_throws CommandLineError parse_command_line(["omnetpp.ini"])
        @test_throws CommandLineError parse_command_line(["-f"])
        @test_throws CommandLineError parse_command_line(["-c"])
        @test_throws CommandLineError parse_command_line(["--result-dir="])
    end

    @testset "--result-dir needs its '='" begin
        error = try
            parse_command_line(["--result-dir", "out"])
        catch caught
            caught
        end
        @test error isa CommandLineError
        @test occursin("=", error.message)
    end
end
