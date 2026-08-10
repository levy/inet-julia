# ============================================================================
# The command line — what each option does, and what a wrong one says.
#
# An option outside the set is an error and not a silence: an ignored
# --sim-time-limit produces a run that is wrong in a way no output shows
# (plan/done/native-simulation-binary.md §4.4).
# ============================================================================
using Test
using InetRunner
using InetRunner.CommandLineModule: Options, CommandLineError, parse_command_line,
    ned_directories, help_text, version_text, build_info_text, check_interface,
    interface_symbol, interface_name, PROGRAM_NAME, PROGRAM_VERSION

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

    @testset "the user interface" begin
        # `-u` reads a name. Which names a build holds is the entry package's
        # business, and it is asked after the whole command line is read.
        @test parse_command_line(["-u", "Cmdenv"]).config == "General"
        @test parse_command_line(String[]).user_interface === :cmdenv
        @test parse_command_line(["-u", "Editor"]).user_interface === :editor
        @test parse_command_line(String[];
                                 default_interface = :editor).user_interface === :editor

        # Qtenv is a C++ program built on Qt. This is neither, so it does not
        # answer to that name.
        @test_throws CommandLineError parse_command_line(["-u", "Qtenv"])
        @test_throws CommandLineError parse_command_line(["-u", "Tkenv"])

        # The command-line build holds one interface and refuses the other, and
        # it says which build draws.
        @test check_interface(:cmdenv, InetRunner.INTERFACES) === nothing
        @test_throws CommandLineError check_interface(:editor, InetRunner.INTERFACES)
        @test occursin("inet-julia-editor",
                       try; check_interface(:editor, InetRunner.INTERFACES); ""
                       catch exception; exception.message; end)

        # The help offers what the build holds, and nothing else.
        @test occursin("Cmdenv", help_text((:cmdenv,)))
        @test !occursin("Editor", help_text((:cmdenv,)))
        @test occursin("Editor", help_text((:cmdenv, :editor)))
        @test occursin("--backend", help_text((:cmdenv,); extra = "\n  --backend <name>"))
    end

    @testset "what the build was made with" begin
        @test parse_command_line(["--build-info"]) === :build_info
        text = build_info_text(InetRunner.INTERFACES)
        @test occursin("name", text)
        @test occursin(PROGRAM_NAME, text)
        @test occursin("workload", text)
        @test occursin("sdl", build_info_text((:cmdenv, :editor);
                                              extra = ["backends" => "sdl"]))
        # `--version` keeps its shape: two words, because a run prints it as
        # its banner and the reference test compares run output line for line.
        @test version_text() == "$PROGRAM_NAME $PROGRAM_VERSION"
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
