# The demo catalog, walked end to end: the root file loads, the navigator is
# derived from the index's own prose, every page opens, every marker on it
# resolves, every page renders through the projection `run_demo` actually
# builds, and every simulation it embeds runs.
#
# This is the catalog's acceptance test. A page whose embedded fragment names a
# definition that was since renamed, or whose step file names a model that no
# longer exists, fails here rather than in front of an audience.

using Test
using Inet
using InetExample
using OmnetppSimulator
using OmnetppPresentation
using Projectured
using Projectured.CellModule: AbstractCell
using Projectured.CollectionModule: CellVector
using Projectured.FileProjectModule: ReferenceStub
using Projectured.GraphicsModule: GraphicsCanvas
using Projectured.IoMapModule: get_iomap_output
using Projectured.ProjectionApiModule: print_document
using Projectured.TrueTypeModule: truetype_measure_text
using Projectured.PrinterContextModule: PrinterContext
using Projectured.CellModule: Cell
using Projectured.EventModule: MousePress
using Projectured.IntentModule: Intent
using Projectured.ReferenceModule: EmptyReference
using Projectured.OperationModule: ToggleCollapseOperation
using Projectured.ProjectionApiModule: read_intent
using Projectured.SyntaxModule: SyntaxNode

# Every ReferenceStub under a document — the markers a page carries.
function _demo_stubs(node, acc = Any[], depth = 0)
    depth > 24 && return acc
    node isa AbstractCell && return _demo_stubs(node[], acc, depth)
    node isa ReferenceStub && (push!(acc, node); return acc)
    for f in (:elements, :items, :content)
        hasproperty(node, f) || continue
        v = getproperty(node, f)
        v isa AbstractString && continue
        v isa AbstractCell && (v = v[])
        (v isa AbstractVector || v isa CellVector) || continue
        for c in v
            _demo_stubs(c, acc, depth + 1)
        end
    end
    acc
end

# Every string a rendered tree actually draws. A diagram that fell back to a
# generic view still produces a canvas of the right type, so what it SAYS is the
# only assertion worth making about it.
function _drawn_strings(root)
    drawn, pending, seen = String[], Any[root], Set{UInt64}()
    while !isempty(pending)
        node = pop!(pending)
        while node isa AbstractCell
            node = node[]
        end
        node === nothing && continue
        id = objectid(node)
        id in seen && continue
        push!(seen, id)
        if node isa GraphicsCanvas
            for element in node.elements
                push!(pending, element)
            end
        elseif node isa Projectured.GraphicsModule.GraphicsViewport
            push!(pending, node.content)
        elseif hasproperty(node, :content) && !(getproperty(node, :content) isa AbstractString)
            push!(pending, getproperty(node, :content))
        elseif string(typeof(node).name.name) == "GraphicsText"
            push!(drawn, string(node.text))
        end
    end
    drawn
end

@testset "the root file builds a shell with a derived navigator" begin
    shell = demo_catalog()
    @test shell isa CatalogShell
    # The navigator comes from index.md's headings and links, so it is
    # non-empty and every page entry names a file that exists.
    pages = catalog_pages(shell)
    @test !isempty(pages)
    for entry in pages
        @test isfile(joinpath(demo_directory(), entry.path))
    end
    # A section with no pages under it is not a row: the index's "How to read
    # this" is prose only and must not appear.
    entries = collect(shell.entries)
    for (i, entry) in enumerate(entries)
        entry.section || continue
        rest = entries[(i + 1):end]
        next = findfirst(e -> e.section, rest)
        span = next === nothing ? rest : rest[1:(next - 1)]
        @test any(e -> !e.section, span)
    end
    @test any(e -> e.section && e.title == "The packet, taken apart", entries)
end

@testset "every page opens and every marker on it resolves" begin
    # A page that opens with an unresolved embed does NOT throw — the shell
    # deliberately survives that, so an audience gets prose instead of a stack
    # trace. Which is exactly why it has to be asserted here: without this the
    # failure mode is a page that quietly lost its embed to a renamed
    # definition and still looks fine.
    shell = demo_catalog()
    for (i, entry) in enumerate(shell.entries)
        entry.section && continue
        open_page!(shell, i)
        @test Projectured.filename(shell.page) == entry.path
        stubs = _demo_stubs(Projectured.content(shell.page))
        @test !isempty(stubs)          # every page here demonstrates something
        for stub in stubs
            @test stub.resolved !== nothing
        end
    end
end

@testset "every page renders through the chain run_demo uses" begin
    # Loading a page and rendering it are different things, and so are
    # rendering it and FORCING that render: the canvas a projection returns is
    # a tree of unevaluated cells, so asserting it is a GraphicsCanvas proves
    # almost nothing. `_canvas_content_bounds` walks and forces every element,
    # which is what the backend does when it paints.
    shell = demo_catalog()
    projection = demo_projection(measure = truetype_measure_text)
    for (i, entry) in enumerate(shell.entries)
        entry.section && continue
        open_page!(shell, i)
        out = get_iomap_output(print_document(projection, shell))
        @test out isa GraphicsCanvas
        @test length(Projectured.GraphicsModule._canvas_content_bounds(
                         out, truetype_measure_text)) == 4
    end
end

@testset "a section row goes nowhere" begin
    shell = demo_catalog()
    i = findfirst(e -> e.section, collect(shell.entries))
    @test i !== nothing
    open_page!(shell, i)
    @test shell.page === shell.index
end

@testset "every embedded simulation runs" begin
    shell = demo_catalog()
    ran = 0
    for (i, entry) in enumerate(shell.entries)
        entry.section && continue
        open_page!(shell, i)
        for stub in _demo_stubs(Projectured.content(shell.page))
            embed = stub.resolved
            embed isa SimulationEmbed || continue
            @test embed.workbench !== nothing
            embed_finish!(embed)
            @test embed_status(embed) === :Finished
            execution = workbench_execution(embed.workbench)
            @test execution !== nothing
            @test total_event_count(simulation_engine(execution)) > 0
            ran += 1
        end
    end
    @test ran >= 4                      # the cards, not zero of them
end

@testset "the PLCA page's cycle length is the one the prose derives" begin
    # The page's whole claim: a cycle is a 2 µs beacon, 1 ns of syncing and one
    # 3.2 µs transmit opportunity per node, so it is predictable to the
    # nanosecond and grows by exactly 3.2 µs per node. Asserted from the page's
    # own step file with one parameter changed, not from a copy of it.
    cycles(n) = begin
        embed = Projectured.evaluate_marker("realize(file(\"pages/Plca.json\"))",
                                            Projectured.LoaderContext(demo_directory()))
        for binding in workbench_assignment(embed.workbench).values
            binding.name === :n_nodes && (binding.value.value = n)
        end
        embed_finish!(embed)
        vectors = workbench_result_vectors(embed.workbench)
        i = findfirst(v -> v.name == "cycleLength:vector", vectors)
        @test i !== nothing
        unique(sample[2] for sample in vectors[i].samples)
    end
    predicted(n) = 2e-6 + 1e-9 + n * 3.2e-6
    for n in (3, 5)
        measured = cycles(n)
        @test length(measured) == 1                  # every cycle the same
        @test only(measured) ≈ predicted(n) rtol = 1e-9
    end
    # And the model's `:scenario` really is a Symbol by the time it is resolved
    # — the round trip through the form that used to break this card.
    embed = Projectured.evaluate_marker("realize(file(\"pages/Plca.json\"))",
                                        Projectured.LoaderContext(demo_directory()))
    resolved = resolve_parameters(model_parameter_space(T1sModel),
                                  workbench_assignment(embed.workbench))
    @test resolved[:scenario] === :notraffic
end

@testset "a chart pane names a series the run actually has" begin
    # `series` is an index into the run's result vectors, and an index is the
    # one thing that goes wrong silently: out of range falls back to the first
    # vector, so a page meaning to chart the queue would chart packet lengths
    # and look perfectly fine doing it.
    # What each charting page means to draw. Naming it is the point: "some
    # vector exists at that index" is true of the wrong index too.
    CHARTED = Dict("pages/Mm1kChain.md"   => "queueLength:vector",
                   "pages/Backpressure.md" => "queueLength:vector",
                   "pages/Plca.md"         => "cycleLength:vector")
    shell = demo_catalog()
    charted = String[]
    for (i, entry) in enumerate(shell.entries)
        entry.section && continue
        open_page!(shell, i)
        for stub in _demo_stubs(Projectured.content(shell.page))
            embed = stub.resolved
            embed isa SimulationEmbed || continue
            embed.panes === nothing && continue
            :chart in embed.panes || continue
            embed_finish!(embed)
            vectors = workbench_result_vectors(embed.workbench)
            @test embed.series isa Integer
            @test 1 <= embed.series <= length(vectors)
            @test haskey(CHARTED, entry.path)
            @test vectors[embed.series].name == get(CHARTED, entry.path, nothing)
            push!(charted, entry.path)
        end
    end
    @test Set(charted) == Set(keys(CHARTED))
end

@testset "the MAC machine draws as a state diagram" begin
    # A machine renders through five projections, and any one of them falling
    # back to a generic view still yields a canvas of the right type. So the
    # assertion is what a reader would see: the state names, and the trigger
    # labels on the edges between them.
    shell = demo_catalog()
    i = findfirst(e -> !e.section && e.path == "pages/Fsm.md", collect(shell.entries))
    @test i !== nothing
    open_page!(shell, i)
    out = get_iomap_output(print_document(demo_projection(measure = truetype_measure_text),
                                          shell))
    texts = _drawn_strings(out)
    for state in ("IDLE", "WAIT_IFG", "TRANSMITTING", "JAMMING", "BACKOFF", "RECEIVING")
        @test any(t -> occursin(state, t), texts)
    end
    # The edges say what fires them: an event by name, a timer as a timeout.
    @test any(t -> occursin("UPPER_PACKET", t), texts)
    @test any(t -> occursin("timeout(backoff_timer)", t), texts)
    # The marker itself never shows: what is on the page is the machine.
    @test !any(t -> occursin("<<fsm", t), texts)
end

@testset "the packet page shows the packet, foldable" begin
    # The page used to paste `describe(pk)` output into a code block — a
    # quotation nothing re-checked. It now splices the packet itself, so what is
    # asserted is what a reader sees AND that they can open it.
    shell = demo_catalog()
    i = findfirst(e -> !e.section && e.path == "pages/PacketIsChunks.md",
                  collect(shell.entries))
    @test i !== nothing
    open_page!(shell, i)
    out = get_iomap_output(print_document(demo_projection(measure = truetype_measure_text),
                                          shell))
    texts = _drawn_strings(out)
    # The dissection, at every level: envelope, the sequence under it, the
    # header, one of the header's decoded fields, and the payload.
    for want in ("Packet(data=60B", "Sequence(2)", "Ipv4Header", "time_to_live = 64", "Filler(fill=0)")
        @test any(t -> occursin(want, t), texts)
    end
    # Chunk lengths travel with the chunks — that is the whole point of the view.
    @test any(t -> occursin("[20B]", t), texts)
    @test !any(t -> occursin("<<packet", t), texts)
end

@testset "the diagram page draws the packet as the RFC figure" begin
    # The page splices a `Packet`, and nothing converts it first: the renderer
    # reaches it by type dispatch. This is the check that the dispatch entry is
    # keyed on the packet itself — a figure drawn from a document that had to be
    # built at the marker would pass every other test in this file.
    shell = demo_catalog()
    i = findfirst(e -> !e.section && e.path == "pages/PacketDiagram.md",
                  collect(shell.entries))
    @test i !== nothing
    open_page!(shell, i)
    out = get_iomap_output(print_document(demo_projection(measure = truetype_measure_text),
                                          shell))
    texts = _drawn_strings(out)

    # The grid, a header title above the row it starts in, and a value in the
    # base its field declares.
    @test any(t -> occursin("+-+-+-+-+", t), texts)
    @test any(t -> occursin("Ipv4Header  20 B", t), texts)
    @test any(t -> occursin("0a:00:00:00:00:02", t), texts)
    @test any(t -> occursin("UDP (17)", t), texts)
    # A header boundary inside a row, which only a continuous grid can show.
    @test any(t -> occursin("#", t), texts)
    @test !any(t -> occursin("<<packet", t), texts)
end

@testset "clicking a fold marker folds that chunk" begin
    # A real mouse press through the projection `run_demo` builds. Without the
    # marker glyphs configured, `SyntaxToText` draws none — and a marker that is
    # not drawn cannot be clicked, so the tree would render identically and be
    # dead to the reader.
    shell = demo_catalog()
    i = findfirst(e -> !e.section && e.path == "pages/PacketIsChunks.md",
                  collect(shell.entries))
    open_page!(shell, i)
    projection = demo_projection(measure = truetype_measure_text)
    ctx = PrinterContext(EmptyReference(), Cell(1500), Cell(1200), Dict{Symbol,Any}())
    iomap = print_document(projection, nothing, shell, ctx)
    toggled = nothing
    # Scan the page rather than a pinned rectangle: what this asserts is that a
    # marker glyph is drawn and clickable, and where it lands moves whenever the
    # embed's own framing does.
    for y in 200:4:1200, x in 380:4:700
        intent = read_intent(projection, nothing, Intent(MousePress(:left, x, y)), iomap)
        op = intent isa Intent ? intent.operation : intent
        # A chunk of the tree, not the embed card's own chevron: the card folds
        # the whole embed and is a widget, and this is about the syntax markers.
        if op isa ToggleCollapseOperation && op.target isa SyntaxNode
            toggled = op
            break
        end
    end
    @test toggled !== nothing
    @test toggled.target isa SyntaxNode
end

@testset "a machine the catalog does not know is refused by name" begin
    err = try
        Projectured.evaluate_marker("fsm(\"no_such_machine\")",
                                    Projectured.LoaderContext(demo_directory()))
        nothing
    catch e
        sprint(showerror, e)
    end
    @test err !== nothing
    # The message lists what there is, so a typo is self-correcting.
    @test occursin("ethernet_csma_mac", err)
end

@testset "the tutorial's own step files still travel" begin
    # The hand-off page embeds a tutorial step file by path. It works because a
    # step file names a MODEL rather than a path — which is the distinction the
    # page itself explains, so it is worth holding still.
    shell = demo_catalog()
    i = findfirst(e -> !e.section && e.path == "pages/Tutorial.md", collect(shell.entries))
    @test i !== nothing
    open_page!(shell, i)
    embeds = [s.resolved for s in _demo_stubs(Projectured.content(shell.page))
              if s.resolved isa SimulationEmbed]
    @test length(embeds) == 1
    @test embeds[1].model === QueuingModel
end

@testset "the M/M/1/K page's claim holds" begin
    # The page tells the reader that raising arrival_rate towards service_rate
    # makes the queue grow. It is the page's one concrete instruction, so it is
    # measured rather than asserted in prose alone — from the page's own step
    # file, with one parameter changed, rather than from a copy of it.
    load() = Projectured.evaluate_marker("realize(file(\"pages/Mm1kChain.json\"))",
                                         Projectured.LoaderContext(demo_directory()))
    mean_queue(embed) = begin
        embed_finish!(embed)
        Dict(workbench_result(embed.workbench).scalars)[Symbol("Queuing.queue.queueLength:timeavg")]
    end
    # Editing the form field is what a reader does, so the test edits the same
    # binding the form edits rather than rebuilding the workbench around it.
    raise_arrivals!(embed, rate) = begin
        for binding in workbench_assignment(embed.workbench).values
            binding.name === :arrival_rate && (binding.value.value = rate)
        end
        embed
    end
    slow = mean_queue(load())
    busy = mean_queue(raise_arrivals!(load(), 9.0))
    @test busy > slow
end
