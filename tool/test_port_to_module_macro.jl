#!/usr/bin/env julia
#
# What `port_to_module_macro.jl` must get right, on sources small enough to
# read. The hazard the tool exists for is in "one name, two types": the same
# characters are rewritten in one test set and left alone in the next.
#
#     julia tool/test_port_to_module_macro.jl

include(joinpath(@__DIR__, "port_to_module_macro.jl"))

using Test
const P = PortToModuleMacro
const JS = P.JS

# The declaration of a ported element, its unported neighbour, and the two
# builders the tests use. Every case below is rewritten against this world.
const PRELUDE = """
@simulation_module struct ActiveSourceModule
    @parameters begin
        production_interval::Any
        seed::Int = 0
    end
    @gate out::OutputGate
    @variable timer::TimerHandle = TimerHandle()
    @statistics begin
        recording::ModuleStatistics = ModuleStatistics()
        num_packets::Int = 0
    end
end

mutable struct PassiveSinkModule <: AbstractModule
    name::Symbol
    statistics::PassiveSinkStatistics
end

struct PassiveSinkStatistics
    num_packets::Int
end
"""

# Rewrite `body` in the world that `PRELUDE` describes, and answer the text
# after the prelude together with what the tool refused.
function port(body::AbstractString; width::Int = 92)
    src = PRELUDE * body
    tree = JS.parseall(JS.SyntaxNode, src; filename = "case.jl")
    elements, structs = Dict{Symbol,P.Element}(), Set{Symbol}()
    struct_fields = Dict{Symbol,Dict{Symbol,Any}}()
    P.collect_elements!(elements, structs, struct_fields, "case.jl", tree)
    world = P.World(elements, P.collect_retired(elements, structs), structs, struct_fields,
                    Dict{Symbol,Any}())
    for _ in 1:2
        harvest = P.FileScan("case.jl", src, world, width, [Dict{Symbol,Any}()],
                             P.Edit[], P.Note[], true)
        P.walk!(harvest, tree)
    end
    sc = P.rewrite_file(world, "case.jl", src, tree, width)
    out = P.apply_edits(src, sc.edits)
    JS.parseall(JS.SyntaxNode, out; filename = "out.jl")        # it must still parse
    (text = out[(ncodeunits(PRELUDE) + 1):end],
     refused = [n.message for n in sc.notes if n.severity == :refuse],
     assumed = [n.message for n in sc.notes if n.severity == :assume])
end

@testset "port_to_module_macro" begin

@testset "it reads the declaration" begin
    tree = JS.parseall(JS.SyntaxNode, PRELUDE; filename = "p.jl")
    elements, structs = Dict{Symbol,P.Element}(), Set{Symbol}()
    P.collect_elements!(elements, structs, Dict{Symbol,Dict{Symbol,Any}}(), "p.jl", tree)
    active = elements[:ActiveSourceModule]
    @test active.ported
    @test active.fields[:production_interval] === :parameter
    @test active.fields[:out] === :gate
    @test active.fields[:timer] === :variable
    @test active.fields[:num_packets] === :statistic
    @test !elements[:PassiveSinkModule].ported

    retired = P.collect_retired(elements, structs)
    @test retired[Symbol("ActiveSourceParameters")] === :ActiveSourceModule
    # A struct that is still defined is not retired, whatever its name says.
    @test !haskey(retired, :PassiveSinkStatistics)
end

@testset "a parameter struct becomes keywords" begin
    r = port("m = ActiveSourceModule(:s, ActiveSourceParameters(production_interval = 0.1))\n")
    @test strip(r.text) == "m = ActiveSourceModule(:s; production_interval = 0.1)"
    @test isempty(r.refused)

    # Keywords of the call itself come after those of the struct.
    r = port("m = ActiveSourceModule(:s, ActiveSourceParameters(production_interval = 0.1); seed = 2)\n")
    @test strip(r.text) == "m = ActiveSourceModule(:s; production_interval = 0.1, seed = 2)"

    # An empty parameter struct leaves a call with a name and nothing else.
    r = port("m = ActiveSourceModule(:s, ActiveSourceParameters())\n")
    @test strip(r.text) == "m = ActiveSourceModule(:s)"

    # A call already in the new shape is not touched.
    r = port("m = ActiveSourceModule(:s; production_interval = 0.1)\n")
    @test strip(r.text) == "m = ActiveSourceModule(:s; production_interval = 0.1)"
end

@testset "a call too long for a line is broken at the keywords" begin
    r = port("""
    m = add_module!(network, ActiveSourceModule(:s,
        ActiveSourceParameters(production_interval = something_with_a_long_name(1, 2, 3),
                               seed = 4)))
    """)
    @test r.text == """
    m = add_module!(network, ActiveSourceModule(:s;
        production_interval = something_with_a_long_name(1, 2, 3),
        seed = 4))
    """
end

@testset "the containers go" begin
    r = port("""
    function f(m::ActiveSourceModule)
        m.statistics.num_packets + m.parameters.production_interval + m.states.timer
    end
    """)
    @test occursin("m.num_packets + m.production_interval + m.timer", r.text)
    @test isempty(r.refused)

    # A container on an element that has not been ported stays.
    r = port("""
    function f(m::PassiveSinkModule)
        m.statistics.num_packets
    end
    """)
    @test occursin("m.statistics.num_packets", r.text)
    @test isempty(r.refused)
end

@testset "one name, two types" begin
    # The hazard: `source` is an active source in the first block and a sink in
    # the second, and only one of the two reads may be rewritten.
    r = port("""
    @testset "one" begin
        source = ActiveSourceModule(:s; production_interval = 0.1)
        @test source.statistics.num_packets == 1
    end
    @testset "two" begin
        source = PassiveSinkModule(:s)
        @test source.statistics.num_packets == 2
    end
    """)
    @test occursin("@test source.num_packets == 1", r.text)
    @test occursin("@test source.statistics.num_packets == 2", r.text)
    @test isempty(r.refused)
end

@testset "a builder that answers with a named tuple" begin
    r = port("""
    function chain_of()
        source = add_module!(network, ActiveSourceModule(:s; production_interval = 0.1))
        sink = add_module!(network, PassiveSinkModule(:sink))
        (; network, source, sink)
    end
    @testset "use" begin
        chain = chain_of()
        @test chain.source.statistics.num_packets == chain.sink.statistics.num_packets
    end
    """)
    @test occursin("chain.source.num_packets == chain.sink.statistics.num_packets", r.text)
    @test isempty(r.refused)
end

@testset "a collection of modules" begin
    r = port("""
    @testset "many" begin
        sources = [add_module!(network, ActiveSourceModule(Symbol(:s, i); production_interval = 0.1))
                   for i in 1:3]
        @test sources[1].statistics.num_packets == 1
        for source in sources
            @test source.statistics.num_packets > 0
        end
        @test all(source -> source.statistics.num_packets > 0, sources)
    end
    """)
    @test occursin("sources[1].num_packets == 1", r.text)
    @test occursin("@test source.num_packets > 0", r.text)
    @test occursin("all(source -> source.num_packets > 0, sources)", r.text)
    @test isempty(r.refused)
end

@testset "a struct says what its fields hold" begin
    # A compound keeps its submodules in a typed field, and that declaration is
    # the only thing that says what a lambda over them receives.
    r = port("""
    mutable struct CompoundModule <: AbstractModule
        name::Symbol
        sources::Vector{ActiveSourceModule}
        sink::PassiveSinkModule
    end
    total(m::CompoundModule) = sum(s -> s.statistics.num_packets, m.sources)
    first_of(m::CompoundModule) = m.sources[1].statistics.num_packets
    at_the_end(m::CompoundModule) = m.sink.statistics.num_packets
    """)
    @test occursin("sum(s -> s.num_packets, m.sources)", r.text)
    @test occursin("m.sources[1].num_packets", r.text)
    # The sink is not ported, so its container stays.
    @test occursin("m.sink.statistics.num_packets", r.text)
    @test isempty(r.refused)
end

@testset "a ternary with one known branch" begin
    # `given === nothing ? make_one() : given` is how a builder takes an
    # override, and the branch that is known says what the other one is.
    r = port("""
    make_one() = ActiveSourceModule(:s; production_interval = 0.1)
    function build(; given = nothing)
        m = add_module!(network, given === nothing ? make_one() : given)
        (; m)
    end
    @testset "use" begin
        built = build()
        @test built.m.statistics.num_packets == 1
    end
    """)
    @test occursin("@test built.m.num_packets == 1", r.text)
    @test isempty(r.refused)
end

@testset "what it refuses, it names" begin
    # An unknown receiver is left alone and reported.
    r = port("""
    @testset "opaque" begin
        @test whatever().statistics.num_packets == 1
    end
    """)
    @test occursin("whatever().statistics.num_packets", r.text)
    @test length(r.refused) == 1
    @test occursin("cannot tell the type", only(r.refused))

    # A comment between the arguments would be lost by re-rendering.
    r = port("""
    m = ActiveSourceModule(:s,
        ActiveSourceParameters(production_interval = 0.1))   # kept
    n = ActiveSourceModule(:s,
        # this comment sits between the arguments
        ActiveSourceParameters(production_interval = 0.1))
    """)
    @test occursin("m = ActiveSourceModule(:s; production_interval = 0.1)", r.text)
    @test occursin("n = ActiveSourceModule(:s,", r.text)
    @test any(m -> occursin("holds a comment", m), r.refused)

    # A positional argument the generated constructor cannot take. Without this
    # the call would be passed over in silence and break at run time.
    r = port("m = ActiveSourceModule(:s, 3)\n")
    @test occursin("ActiveSourceModule(:s, 3)", r.text)
    @test any(m -> occursin("positional argument", m), r.refused)

    # A field the declaration does not have is a rename, not a rewrite.
    r = port("""
    function f(m::ActiveSourceModule)
        m.statistics.gone_away
    end
    """)
    @test occursin("m.statistics.gone_away", r.text)
    @test any(m -> occursin("does not declare", m), r.refused)
end

@testset "a retired name leaves the lists it was in" begin
    r = port("""
    using InetQueuing: ActiveSourceModule, ActiveSourceParameters, PassiveSinkModule
    using InetQueuing: ActiveSourceParameters, PassiveSinkModule
    using InetQueuing: ActiveSourceStates
    export ActiveSourceModule, ActiveSourceParameters
    """)
    @test occursin("using InetQueuing: ActiveSourceModule, PassiveSinkModule\n", r.text)
    @test occursin("using InetQueuing: PassiveSinkModule\n", r.text)
    @test !occursin("ActiveSourceStates", r.text)
    @test occursin("export ActiveSourceModule\n", r.text)
    @test isempty(r.refused)

    # Two neighbours go in one cut: two cuts would overlap on the comma.
    r = port("""
    using InetQueuing: ActiveSourceModule, ActiveSourceParameters, ActiveSourceStates,
        PassiveSinkModule
    using InetQueuing: ActiveSourceParameters, ActiveSourceStates, ActiveSourceModule
    """)
    @test occursin("using InetQueuing: ActiveSourceModule,\n    PassiveSinkModule\n", r.text)
    @test occursin("using InetQueuing: ActiveSourceModule\n", r.text)
    @test isempty(r.refused)

    # Anywhere else, a retired name is a person's problem.
    r = port("p = ActiveSourceParameters\n")
    @test any(m -> occursin("still named here", m), r.refused)
end

@testset "rewrites inside a rewritten call" begin
    # The chain is folded into the argument text, not applied twice.
    r = port("""
    function f(other::ActiveSourceModule)
        ActiveSourceModule(:s, ActiveSourceParameters(seed = other.statistics.num_packets))
    end
    """)
    @test occursin("ActiveSourceModule(:s; seed = other.num_packets)", r.text)
    @test isempty(r.refused)
end

end # @testset "port_to_module_macro"
