# ============================================================================
# The build's parameter surface.
#
# A build takes minutes, so nothing here compiles anything. `BuildSpec` is a
# value and `build_preferences` writes a TOML file, and both are testable in
# milliseconds. What this asserts is the part a compile would not check anyway:
# that a spec which describes no program is refused, and that the parameters
# reach the file the entry package reads them from.
# ============================================================================

using Test
using TOML

include(joinpath(@__DIR__, "..", "..", "..", "tool", "Build.jl"))
using .InetBuild

@testset "build spec" begin
    @testset "the defaults" begin
        runner = runner_binary()
        @test runner.name == "inet-julia"
        @test runner.interfaces == [:cmdenv]
        @test runner.default_interface === :cmdenv
        @test isempty(runner.backends)
        # `:full` is what the build did before it took a parameter, so a
        # build with no flag must not ship less than it shipped yesterday.
        @test runner.workload === :full
        @test runner.cpu_target == ""

        editor = editor_binary()
        @test editor.name == "inet-julia-editor"
        @test editor.interfaces == [:cmdenv, :editor]
        # A person who starts the program that draws asked for a window.
        @test editor.default_interface === :editor
        @test editor.backends == [:sdl]
        @test editor.default_backend === :sdl
        @test editor.entry === :catalog

        # The two never write into each other's directory. This is the
        # whole of "tell the outputs apart" at the file level.
        @test runner.name != editor.name
    end

    @testset "a spec that describes no program is refused" begin
        @test_throws ErrorException BuildSpec(; interfaces = Symbol[])
        @test_throws ErrorException BuildSpec(; interfaces = [:nosuch])
        @test_throws ErrorException BuildSpec(; workload = :lots)
        @test_throws ErrorException BuildSpec(; entry = :nowhere)
        @test_throws ErrorException BuildSpec(; name = "")
        # A backend with nothing to draw, and a draw with no backend.
        @test_throws ErrorException BuildSpec(; backends = [:sdl])
        @test_throws ErrorException BuildSpec(; interfaces = [:cmdenv, :editor],
                                               backends = Symbol[])
        @test_throws ErrorException BuildSpec(; interfaces = [:cmdenv, :editor],
                                               default_backend = :web)
        @test_throws ErrorException BuildSpec(; interfaces = [:cmdenv],
                                               default_interface = :editor)
        @test_throws ErrorException BuildSpec(; catalog = "/nonexistent/nowhere")
    end

    @testset "the entry package follows the interfaces" begin
        @test basename(entry_project(runner_binary())) == "main"
        @test basename(entry_project(editor_binary())) == "editor"
    end

    @testset "the parameters reach the file the program reads" begin
        mktempdir() do directory
            # `build_preferences` writes beside a project, so a temporary
            # directory stands in for one. Nothing here reads it back
            # through Julia's own preference machinery: that would need the
            # package loaded, and this is a test of the writing.
            spec = editor_binary(; name = "omnetpp-demo", workload = :minimal,
                                 cpu_target = "native", entry = :none)
            path = build_preferences(spec; project = directory)
            written = TOML.parsefile(path)

            @test written["InetRunner"]["name"] == "omnetpp-demo"
            @test written["InetRunner"]["workload"] == "minimal"
            @test written["InetRunner"]["cpu_target"] == "native"
            @test written["InetRunnerEditor"]["backends"] == ["sdl"]
            @test written["InetRunnerEditor"]["default_backend"] == "sdl"
            @test written["InetRunnerEditor"]["expose_backend"] == false
            @test written["InetRunnerEditor"]["entry"] == "none"

            # Every build writes every key. A second build under other
            # parameters must leave nothing of the first behind, or the
            # first build's answer is compiled into the second binary.
            again = runner_binary(; workload = :demo)
            build_preferences(again; project = directory)
            rewritten = TOML.parsefile(path)
            @test rewritten["InetRunner"]["name"] == "inet-julia"
            @test rewritten["InetRunner"]["workload"] == "demo"
            @test rewritten["InetRunner"]["cpu_target"] == ""
        end
    end
end
