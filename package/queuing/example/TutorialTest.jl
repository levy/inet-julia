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
using Projectured.ChainingProjectionModule: ChainingProjection
using Projectured.RecursiveProjectionModule: RecursiveProjection
using Projectured.ProjectionApiModule: read_intent
using Projectured.OperationModule: ReplaceSelectionOperation
using Projectured.ReferenceModule: ConcreteReference, FieldReferenceStep,
    ElementReferenceStep, EmptyReference
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

# The shell renders as a widget stage followed by the page renderer — the
# workbench's own shape, and what keeps a page's embeds live inside it.
_shell_renderer() = ChainingProjection(RecursiveProjection(TutorialShellToWidget()),
                                       _tutorial_renderer())

_tutorial_drawn(page) = _drawn_from(Projectured.print_document(
    _tutorial_renderer(), Projectured.content(page)).output)

_shell_drawn(shell) = _drawn_from(Projectured.print_document(_shell_renderer(), shell).output)

# Every string a rendered tree draws.
function _drawn_from(root)
    drawn, pending, seen = String[], Any[root], Set{UInt64}()
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
        elseif node isa Projectured.GraphicsModule.GraphicsViewport
            # A pane's content lives behind its viewport, which is where every
            # scrolled page and navigator row is.
            push!(pending, node.content)
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

        @testset "the shell lists the steps and opens one" begin
            shell = load_tutorial()
            # The navigator is the index's own links — the navigation is not
            # declared twice.
            @test [s.title for s in shell.steps] == ["A single queue"]
            @test [s.path for s in shell.steps] == ["queues/Queue.md"]
            @test Projectured.filename(shell.page) == "index.md"

            drawn = _shell_drawn(shell)
            @test "Contents" in drawn
            @test any(t -> occursin("A single queue", t), drawn)
            @test any(t -> occursin("queueing network", t), drawn)

            open_step!(shell, 1)
            @test Projectured.filename(shell.page) == "queues/Queue.md"
            drawn = _shell_drawn(shell)
            # The page arrives with its embeds live: prose, the model's source,
            # and the card's own button …
            @test any(t -> occursin("M/M/1/K", t), drawn)
            @test any(t -> occursin("connect!", t), drawn)
            @test "Run" in drawn
            # … and the navigator is still beside it.
            @test "Contents" in drawn

            # Back to the index, and the step reopened is the SAME document —
            # the session interns it, so a simulation keeps its state.
            page = shell.page
            open_step!(shell, 0)
            @test Projectured.filename(shell.page) == "index.md"
            open_step!(shell, 1)
            @test shell.page === page
        end

        @testset "clicking a navigator row opens that step" begin
            shell = load_tutorial()
            iomap = Projectured.print_document(TutorialShellToWidget(), shell)
            # A click lands on the navigator list's k-th item.
            path = foldr((s, t) -> ConcreteReference(s, t),
                         Any[FieldReferenceStep("children"), ElementReferenceStep(1),
                             FieldReferenceStep("content"), FieldReferenceStep("items"),
                             ElementReferenceStep(2)];
                         init = EmptyReference())
            operation = read_intent(iomap.projection, iomap, ReplaceSelectionOperation(path))
            # The reader RETURNS the action rather than performing it.
            @test Projectured.filename(shell.page) == "index.md"
            operation.action.callback(nothing)
            @test Projectured.filename(shell.page) == "queues/Queue.md"
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
