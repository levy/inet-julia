# The tutorial's own check, at the level a reader experiences it: a page loads,
# its embeds resolve to the documents they name, the page renders with the live
# card among its prose, and the step's simulation runs to its limit.
#
# Headless throughout — `embed_finish!` runs a simulation synchronously, and the
# renderer measures text with a function rather than a font, so no backend is
# needed.

using Test
using OmnetppPresentation: SimulationEmbed, simulation_embed_entry, embed_finish!,
    embed_status
using OmnetppSimulator: workbench_result, workbench_assignment, model_topology,
    build_model, model_parameter_space, resolve_parameters, ParameterAssignment
using InetQueuing: QueuingModel

_tutorial_measure(text, _font) = (length(text) * 10, 20)

_tutorial_renderer() =
    Projectured.NaturalToGraphics(measure = _tutorial_measure,
                                  extra = Pair{Type,Any}[simulation_embed_entry()])

# Every embed a page holds, in order.
function _tutorial_embeds(page)
    document = Projectured.content(page)
    values = Any[]
    for element in Projectured.CellModule.unwrap_cell(getfield(document, :elements))
        node = element isa Projectured.CellModule.AbstractCell ? element[] : element
        node isa Projectured.FileProjectModule.ReferenceStub || continue
        push!(values, node.resolved)
    end
    values
end

# Every string the rendered page draws.
function _tutorial_drawn(page)
    drawn, pending, seen = String[], Any[Projectured.print_document(
        _tutorial_renderer(), Projectured.content(page)).output], Set{UInt64}()
    while !isempty(pending)
        node = pop!(pending)
        while node isa Projectured.CellModule.AbstractCell
            node = node[]
        end
        node === nothing && continue
        id = objectid(node)
        id in seen && continue
        push!(seen, id)
        if node isa Projectured.GraphicsModule.GraphicsCanvas
            for element in node.elements
                push!(pending, element)
            end
        elseif string(typeof(node).name.name) == "GraphicsText"
            push!(drawn, string(node.text))
        end
    end
    drawn
end

"""
    test_tutorial()

Load every page of the tutorial, force its embeds, render it, and run each
step's simulation to its limit.
"""
function test_tutorial()
    @testset "the queuing tutorial" begin

        @testset "the index lists the steps" begin
            page = load_tutorial_page("index.md")
            drawn = _tutorial_drawn(page)
            @test any(t -> occursin("The queuing tutorial", t), drawn)
            @test any(t -> occursin("A single queue", t), drawn)
        end

        @testset "a step page carries the model's source and the simulation" begin
            page = load_tutorial_page("queues/Queue.md")
            embeds = _tutorial_embeds(page)
            @test length(embeds) == 2
            # The model's own source, addressed by the name the definition
            # carries — so the reader sees what actually runs.
            @test string(typeof(embeds[1]).name.name) == "JuliaFunction"
            @test embeds[2] isa SimulationEmbed
            @test embeds[2].model === QueuingModel

            drawn = _tutorial_drawn(page)
            # The prose …
            @test any(t -> occursin("M/M/1/K", t), drawn)
            # … the model source, inline, in its own domain …
            @test any(t -> occursin("_build_queuing_network", t), drawn)
            @test any(t -> occursin("connect!", t), drawn)
            # … and the live card, as a real widget.
            @test "Run" in drawn
            @test any(t -> occursin("arrival_rate", t), drawn)
            # No marker text survives: what shows is the thing, not its name.
            @test !any(t -> occursin("<<", t), drawn)
        end

        @testset "the step's simulation runs to its limit" begin
            page = load_tutorial_page("queues/Queue.md")
            embed = only(e for e in _tutorial_embeds(page) if e isa SimulationEmbed)
            # The step's own values, not the model's defaults.
            @test only(b.value.value for b in
                       workbench_assignment(embed.workbench).values
                       if b.name === :packet_capacity) == 10
            embed_finish!(embed)
            @test embed_status(embed) === :Finished
            result = workbench_result(embed.workbench)
            @test result !== nothing
            @test length(result.scalars) > 0
        end

        @testset "the step's diagram is derived from its own wiring" begin
            model = build_model(QueuingModel,
                resolve_parameters(model_parameter_space(QueuingModel), ParameterAssignment()))
            labels, edges = model_topology(model)
            @test labels == ["Queuing.source", "Queuing.queue", "Queuing.server", "Queuing.sink"]
            @test edges == [(1, 2), (2, 3), (3, 4)]
        end

    end
end
