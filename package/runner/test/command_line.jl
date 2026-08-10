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
        options = parse_command_line(["-f", "a.ini",
                                      "-c", "TestNetwork", "-r", "3",
                                      "-n", "ned:more/ned", "-u", "Cmdenv",
                                      "--result-dir=out",
                                      "--sim-time-limit=100s",
                                      "--cpu-time-limit=20s",
                                      "--cmdenv-express-mode=true"])
        @test options.ini_files == ["a.ini"]
        @test options.config == "TestNetwork"
        @test options.run == 4                  # the command line said 3
        @test options.ned_path == ["ned", "more/ned"]
        @test options.result_dir == "out"
        @test options.sim_time_limit == 100.0
        @test options.cpu_time_limit == 20.0
        @test options.express_mode
        @test options.result_recording
    end

    @testset "a second INI file is refused, not dropped" begin
        # `opp_run` layers several. This runner reads one, and a rule from a
        # file that was accepted and never read is the failure the option set
        # exists to prevent. `omnetpp-julia` refuses it the same way.
        @test_throws CommandLineError parse_command_line(["-f", "a.ini", "-f", "b.ini"])
    end

    @testset "the limits and the recording switches" begin
        # The spellings an INI file uses, so one option and one file cannot
        # mean two different things.
        @test parse_command_line(["--sim-time-limit=1000ms"]).sim_time_limit == 1.0
        @test parse_command_line(["--sim-time-limit=250000s"]).sim_time_limit == 250000.0
        @test parse_command_line(["--sim-time-limit=5"]).sim_time_limit == 5.0
        @test_throws CommandLineError parse_command_line(["--sim-time-limit=soon"])
        @test_throws CommandLineError parse_command_line(["--sim-time-limit"])

        @test !parse_command_line(["--result-recording=false"]).result_recording
        @test parse_command_line(["--result-recording=true"]).result_recording
        @test_throws CommandLineError parse_command_line(["--result-recording=maybe"])

        @test !parse_command_line(["--cmdenv-express-mode=false"]).express_mode

        # There is no event log to turn off, so the only answer this runner can
        # honour is the one that asks for none.
        @test parse_command_line(["--record-eventlog=false"]) isa Options
        @test_throws CommandLineError parse_command_line(["--record-eventlog=true"])
    end

    @testset "the engine" begin
        # An execution degree of freedom: it decides how the answer is computed
        # and never what the answer is.
        @test parse_command_line(String[]).engine === :sequential
        @test parse_command_line(String[]).workers === nothing
        @test parse_command_line(["--engine=parallel"]).engine === :parallel
        @test parse_command_line(["--engine=parallel", "--workers=3"]).workers == 3

        @test_throws CommandLineError parse_command_line(["--engine=nosuch"])
        @test_throws CommandLineError parse_command_line(["--engine=parsim"])
        @test_throws CommandLineError parse_command_line(["--engine=parallel", "--workers=0"])
        # A worker count the sequential engine cannot use is refused.
        @test_throws CommandLineError parse_command_line(["--workers=4"])

        # The parallel engine needs one thread per worker plus one, and a
        # process with fewer is told before the run rather than during it.
        too_many = parse_command_line(["--engine=parallel",
                                       "--workers=$(Threads.nthreads() + 4)"])
        @test_throws CommandLineError InetRunner.RunnerModule.check_engine(too_many)
        @test occursin("JULIA_NUM_THREADS",
                       try; InetRunner.RunnerModule.check_engine(too_many); ""
                       catch exception; exception.message; end)
        @test InetRunner.RunnerModule.check_engine(parse_command_line(String[])) === nothing
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
        # be quietly dropped. `--sim-time-limit` used to be one of these and is
        # honoured now, so the example is an option that is still not.
        @test_throws CommandLineError parse_command_line(["--fast-forward=3"])
        @test_throws CommandLineError parse_command_line(["--parsim-communications-class=x"])
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
