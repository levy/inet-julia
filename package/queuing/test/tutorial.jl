# The tutorial's own check, at the level a reader experiences it: a page loads,
# its embeds resolve to the documents they name, the page renders with the live
# card among its prose, and the step's simulation runs to its limit.
#
# Headless throughout — `embed_finish!` runs a simulation synchronously, and the
# renderer measures text with a function rather than a font, so no backend is
# needed.

using Test
using OmnetppPresentation: SimulationEmbed, simulation_embed_entry, embed_finish!,
    embed_status, CatalogShellToWidget, catalog_pages, open_page!
import OmnetppPresentation
using OmnetppSimulator: workbench_result, workbench_assignment, model_topology,
    build_model, model_parameter_space, resolve_parameters, ParameterAssignment
# The renderer, the cell and graphics types, and `content`/`filename` are
# reached as `Projectured.…` throughout this file, so the module itself has to
# be in scope and not only the four names below.
using Projectured
using Projectured.ChainingProjectionModule: ChainingProjection
using Projectured.ProjectionApiModule: read_intent
using Projectured.OperationModule: ReplaceSelectionOperation
using Projectured.ReferenceModule: ConcreteReference, FieldReferenceStep,
    ElementReferenceStep, EmptyReference
using InetQueuing: QueuingModel
# The content under test. The pages and the step models belong to the example
# package; only the assertions about them belong here, which is what keeps
# `Test` out of an example package's dependencies.
using InetQueuingExample: tutorial_directory, load_tutorial, load_tutorial_page,
    ActiveSourcePassiveSinkModel, NamedPolicyModel

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
_shell_renderer() = ChainingProjection(CatalogShellToWidget(), _tutorial_renderer())

# Which navigator row a page is. The shell's entries are the index's sections
# AND its links, so a step's row is not its step number — asking by path is the
# only form that survives someone adding a section to `index.md`.
function _step_row(shell, path::AbstractString)
    i = findfirst(e -> !e.section && e.path == path, collect(shell.entries))
    i === nothing && error("no navigator entry for ", repr(path))
    i
end

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
            # The introduction says how to read a step, which is what INET's
            # "getting started" page is for.
            @test any(t -> occursin("How to read a step", t), drawn)
        end

        @testset "every page loads and every embed resolves" begin
            # The whole tutorial, not just the steps a testset names: a marker
            # that stopped evaluating (a renamed definition, a moved file) fails
            # here rather than the first time a reader opens that page.
            shell = load_tutorial()
            for step in catalog_pages(shell)
                page = load_tutorial_page(step.path)
                embeds = _tutorial_embeds(page)
                @test length(embeds) == 2
                @test string(typeof(embeds[1]).name.name) == "JuliaFunction"
                @test embeds[2] isa SimulationEmbed
            end
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
            @test any(t -> occursin("connect_gates!", t), drawn)
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
            scalars = Dict(workbench_result(embed.workbench).scalars)
            # Real numbers, not an empty result: 100 s of arrivals at 5/s is
            # about 500 packets, and a queue served at 10/s passes nearly all
            # of them on.
            served = scalars[Symbol("Queuing.sink.packets:count")]
            @test 400 <= served <= 600
            @test scalars[Symbol("Queuing.queue.droppedPacketsQueueOverflow:count")] < 50
        end

        @testset "the first step's arrivals are the ones it claims" begin
            page = load_tutorial_page("sources/ActiveSourcePassiveSink.md")
            embed = only(e for e in _tutorial_embeds(page) if e isa SimulationEmbed)
            @test embed.model === ActiveSourcePassiveSinkModel
            embed_finish!(embed)
            scalars = Dict(workbench_result(embed.workbench).scalars)
            # Clockwork: 10 s at one packet every 0.1 s, and the sink counts
            # every one of them. This is the step's whole point, so it is
            # asserted exactly rather than in a range.
            @test scalars[Symbol("SourceSink.source.packets:count")] == 100
            @test scalars[Symbol("SourceSink.sink.packets:count")] == 100
        end

        @testset "the shell lists the steps and opens one" begin
            shell = load_tutorial()
            # The navigator is the index's own sections and links — the
            # navigation is not declared twice.
            # Every step the index links to is a page that exists, in the order
            # the index lists them.
            steps = catalog_pages(shell)
            @test length(steps) >= 14
            @test first([s.path for s in steps]) == "sources/ActiveSourcePassiveSink.md"
            @test first([s.title for s in steps]) == "An active source and a passive sink"
            for step in steps
                @test isfile(joinpath(tutorial_directory(), step.path))
            end
            # The index's own `##` headings are rows too, and they group the
            # steps under them rather than naming a page.
            @test any(e -> e.section && e.title == "Queues", collect(shell.entries))
            @test Projectured.filename(shell.page) == "index.md"

            drawn = _shell_drawn(shell)
            @test "Contents" in drawn
            @test any(t -> occursin("A single queue", t), drawn)
            @test any(t -> occursin("queueing network", t), drawn)

            queue_row = _step_row(shell, "queues/Queue.md")
            open_page!(shell, queue_row)
            @test Projectured.filename(shell.page) == "queues/Queue.md"
            drawn = _shell_drawn(shell)
            # The page arrives with its embeds live: prose, the model's source,
            # and the card's own button …
            @test any(t -> occursin("M/M/1/K", t), drawn)
            @test any(t -> occursin("connect_gates!", t), drawn)
            @test "Run" in drawn
            # … and the navigator is still beside it.
            @test "Contents" in drawn

            # Back to the index, and the step reopened is the SAME document —
            # the session interns it, so a simulation keeps its state.
            page = shell.page
            open_page!(shell, 0)
            @test Projectured.filename(shell.page) == "index.md"
            open_page!(shell, queue_row)
            @test shell.page === page
        end

        @testset "clicking a navigator row opens that step" begin
            shell = load_tutorial()
            iomap = Projectured.print_document(CatalogShellToWidget(), shell)
            # A click lands on the navigator list's k-th item. The two panes sit
            # in a `WidgetSplitPane`, whose children field is `elements` — name
            # it wrong and every path simply stops matching, so the tutorial
            # renders perfectly and goes dead to clicks.
            row = _step_row(shell, "sources/ActiveSourcePassiveSink.md")
            path = foldr((s, t) -> ConcreteReference(s, t),
                         Any[FieldReferenceStep("elements"), ElementReferenceStep(1),
                             FieldReferenceStep("content"), FieldReferenceStep("items"),
                             ElementReferenceStep(row + 1)];
                         init = EmptyReference())
            operation = read_intent(iomap.projection, iomap, ReplaceSelectionOperation(path))
            # The reader RETURNS the action rather than performing it.
            @test Projectured.filename(shell.page) == "index.md"
            operation.action.callback(nothing)
            @test Projectured.filename(shell.page) == "sources/ActiveSourcePassiveSink.md"
        end

        @testset "a section row goes nowhere" begin
            # A heading is a label, not a destination: clicking one must leave
            # the reader where they were rather than opening whatever page
            # happens to follow it.
            shell = load_tutorial()
            i = findfirst(e -> e.section, collect(shell.entries))
            @test i !== nothing
            open_page!(shell, i)
            @test shell.page === shell.index
        end

        @testset "every step's simulation makes the claim its page makes" begin
            # One page, one claim, checked as a number. A result that merely
            # exists proves nothing — it is what an unrun execution also
            # produces.
            for (page, key, check) in (
                    # The consumer sets the rate here, not the producer: 10 s at
                    # one collection every 0.2 s.
                    ("sources/PassiveSourceActiveSink.md",
                     "PullSourceSink.sink.packets:count", n -> n == 50),
                    # Arrivals faster than service, and a queue with room for 5:
                    # it fills, and from then on what arrives is dropped.
                    ("queues/DropTailQueue.md",
                     "Queuing.queue.droppedPacketsQueueOverflow:count", n -> n > 100))
                embed = only(e for e in _tutorial_embeds(load_tutorial_page(page))
                             if e isa SimulationEmbed)
                embed_finish!(embed)
                @test embed_status(embed) === :Finished
                @test check(Dict(workbench_result(embed.workbench).scalars)[Symbol(key)])
            end
        end

        @testset "classifying, scheduling and filtering do what their pages say" begin
            # A classifier that reads the value on each packet splits the
            # traffic between its outputs — two classes, so about half each.
            classifier = only(e for e in _tutorial_embeds(
                                  load_tutorial_page("classifying/ContentBasedClassifier.md"))
                              if e isa SimulationEmbed)
            embed_finish!(classifier)
            scalars = Dict(workbench_result(classifier.workbench).scalars)
            produced = scalars[Symbol("ContentClassifier.source.packets:count")]
            first_class = scalars[Symbol("ContentClassifier.sink1.packets:count")]
            second_class = scalars[Symbol("ContentClassifier.sink2.packets:count")]
            @test first_class + second_class == produced
            @test 0.4 <= first_class / produced <= 0.6

            # The classifier prefers the small queue and the scheduler empties
            # it first, which is the whole of "priority" here: both queues are
            # used, and everything the scheduler took was served.
            priority = only(e for e in _tutorial_embeds(
                                load_tutorial_page("scheduling/PriorityScheduler.md"))
                            if e isa SimulationEmbed)
            embed_finish!(priority)
            scalars = Dict(workbench_result(priority.workbench).scalars)
            @test scalars[Symbol("Priority.first.packets:count")] > 0
            @test scalars[Symbol("Priority.second.packets:count")] > 0
            @test scalars[Symbol("Priority.sink.packets:count")] ==
                  scalars[Symbol("Priority.server.packets:count")]

            # One value in four gets through the filter, and what gets through
            # is exactly what reaches the sink.
            filter = only(e for e in _tutorial_embeds(load_tutorial_page("filtering/Filter.md"))
                          if e isa SimulationEmbed)
            embed_finish!(filter)
            scalars = Dict(workbench_result(filter.workbench).scalars)
            produced = scalars[Symbol("Filter.source.packets:count")]
            kept = scalars[Symbol("Filter.sink.packets:count")]
            @test kept < produced
            @test 0.15 <= kept / produced <= 0.35
        end

        @testset "the plumbing steps move packets and change nothing else" begin
            # A delayer holds packets: everything produced arrives, apart from
            # the few still in flight when the run ends.
            delayer = only(e for e in _tutorial_embeds(load_tutorial_page("generic/Delayer.md"))
                           if e isa SimulationEmbed)
            embed_finish!(delayer)
            scalars = Dict(workbench_result(delayer.workbench).scalars)
            produced = scalars[Symbol("Delayer.source.packets:count")]
            arrived = scalars[Symbol("Delayer.sink.packets:count")]
            @test produced > 0
            @test arrived <= produced
            @test produced - arrived <= 20        # a 0.5 s delay at 10/s

            # A multiplexer joins: the sink sees exactly the sum of its inputs.
            multiplexer = only(e for e in _tutorial_embeds(
                                   load_tutorial_page("generic/Multiplexer.md"))
                               if e isa SimulationEmbed)
            embed_finish!(multiplexer)
            scalars = Dict(workbench_result(multiplexer.workbench).scalars)
            sent = sum(scalars[Symbol("Multiplexer.source$(index).packets:count")]
                       for index in 1:3)
            @test scalars[Symbol("Multiplexer.sink.packets:count")] == sent

            # A demultiplexer splits: what the collectors took is what the one
            # provider produced, and neither collector was starved.
            demultiplexer = only(e for e in _tutorial_embeds(
                                     load_tutorial_page("generic/Demultiplexer.md"))
                                 if e isa SimulationEmbed)
            embed_finish!(demultiplexer)
            scalars = Dict(workbench_result(demultiplexer.workbench).scalars)
            collected = scalars[Symbol("Demultiplexer.sink1.packets:count")] +
                        scalars[Symbol("Demultiplexer.sink2.packets:count")]
            @test collected == scalars[Symbol("Demultiplexer.source.packets:count")]
            @test scalars[Symbol("Demultiplexer.sink1.packets:count")] > 0
            @test scalars[Symbol("Demultiplexer.sink2.packets:count")] > 0
        end

        @testset "refusing is not losing" begin
            # The back-pressure step's whole claim: with the filter refusing,
            # the server never starts, nothing is dropped, and everything the
            # source made is still in the queue.
            embed = only(e for e in _tutorial_embeds(
                             load_tutorial_page("filtering/BackpressureFilter.md"))
                         if e isa SimulationEmbed)
            embed_finish!(embed)
            scalars = Dict(workbench_result(embed.workbench).scalars)
            @test scalars[Symbol("Backpressure.source.packets:count")] > 0
            @test scalars[Symbol("Backpressure.server.packets:count")] == 0
            @test scalars[Symbol("Backpressure.sink.packets:count")] == 0
        end

        @testset "a compound queue keeps its submodules visible" begin
            # A compound module is a name for a piece of network, not a black
            # box: its submodules are real modules, and the derived diagram
            # shows them under the compound's own name.
            embed = only(e for e in _tutorial_embeds(load_tutorial_page("queues/PriorityQueue.md"))
                         if e isa SimulationEmbed)
            embed_finish!(embed)
            labels, edges = model_topology(
                OmnetppSimulator.simulation_model(
                    OmnetppSimulator.workbench_execution(embed.workbench)))
            @test "PriorityQueue.queue.classifier" in labels
            @test "PriorityQueue.queue.queues[1]" in labels
            @test "PriorityQueue.queue.scheduler" in labels
            @test !isempty(edges)
            # And it served packets like any other queue — with the second
            # level taking what the first refused, which is the page's claim
            # and only true because the levels refuse rather than drop.
            scalars = Dict(workbench_result(embed.workbench).scalars)
            @test scalars[Symbol("PriorityQueue.sink.packets:count")] > 0
            @test scalars[Symbol("PriorityQueue.queue.queues[1].packets:count")] > 0
            @test scalars[Symbol("PriorityQueue.queue.queues[2].packets:count")] > 0
        end

        @testset "a share policy gives the share it was asked for" begin
            # Weights 3 and 1: three quarters of the packets take the first
            # path, exactly — the classifier is told which output to use, so
            # the share is not an average, it is the policy.
            wrr = only(e for e in _tutorial_embeds(
                           load_tutorial_page("scheduling/WeightedRoundRobin.md"))
                       if e isa SimulationEmbed)
            embed_finish!(wrr)
            scalars = Dict(workbench_result(wrr.workbench).scalars)
            first_path = scalars[Symbol("Shared.first.packets:count")]
            second_path = scalars[Symbol("Shared.second.packets:count")]
            # Exact to within the cycle the run ended in the middle of: the
            # last few packets are part of a run of three that never finished.
            @test 0 <= first_path - 3 * second_path < 3

            # The Markov policy is symmetric here, so the same two paths get
            # about half each — the shares match, and what differs is that they
            # arrive in bursts (asserted on the classifier itself in the
            # queuing suite, where the order is visible).
            markov = only(e for e in _tutorial_embeds(
                              load_tutorial_page("scheduling/MarkovScheduler.md"))
                          if e isa SimulationEmbed)
            embed_finish!(markov)
            scalars = Dict(workbench_result(markov.workbench).scalars)
            first_path = scalars[Symbol("Shared.first.packets:count")]
            second_path = scalars[Symbol("Shared.second.packets:count")]
            @test 0.45 <= first_path / (first_path + second_path) <= 0.55
        end

        @testset "a policy named in the step file is the policy that runs" begin
            # The step names :data_equals with 1, over four equally likely
            # labels — so about a quarter of the traffic survives, and the name
            # in the JSON is what decided that.
            embed = only(e for e in _tutorial_embeds(load_tutorial_page("filtering/NamedPolicy.md"))
                         if e isa SimulationEmbed)
            @test embed.model === NamedPolicyModel
            embed_finish!(embed)
            scalars = Dict(workbench_result(embed.workbench).scalars)
            produced = scalars[Symbol("NamedPolicy.source.packets:count")]
            kept = scalars[Symbol("NamedPolicy.sink.packets:count")]
            @test 0.15 <= kept / produced <= 0.35
        end

        @testset "a labeler puts there what the classifier sorts by" begin
            # The source says nothing; the labeler writes; the classifier
            # sorts. Two labels, so the sinks split about evenly — and every
            # packet reached one of them, which is the part that proves the
            # classifier read what the labeler wrote.
            embed = only(e for e in _tutorial_embeds(load_tutorial_page("marking/Labeler.md"))
                         if e isa SimulationEmbed)
            embed_finish!(embed)
            scalars = Dict(workbench_result(embed.workbench).scalars)
            produced = scalars[Symbol("Labeling.source.packets:count")]
            first_label = scalars[Symbol("Labeling.sink1.packets:count")]
            second_label = scalars[Symbol("Labeling.sink2.packets:count")]
            @test first_label + second_label == produced
            @test 0.4 <= first_label / produced <= 0.6
        end

        @testset "a cloner copies and a duplicator thickens" begin
            embed = only(e for e in _tutorial_embeds(load_tutorial_page("marking/Cloner.md"))
                         if e isa SimulationEmbed)
            embed_finish!(embed)
            scalars = Dict(workbench_result(embed.workbench).scalars)
            produced = scalars[Symbol("Cloning.source.packets:count")]
            # The plain branch gets one copy of everything …
            @test scalars[Symbol("Cloning.sink2.packets:count")] == produced
            # … and the thickened one gets that plus every second packet again.
            thickened = scalars[Symbol("Cloning.sink1.packets:count")]
            @test thickened == produced + produced ÷ 2
        end

        @testset "the complex network is the elements composed" begin
            embed = only(e for e in _tutorial_embeds(load_tutorial_page("complex/Network.md"))
                         if e isa SimulationEmbed)
            embed_finish!(embed)
            scalars = Dict(workbench_result(embed.workbench).scalars)
            # Two sources joined into one stream …
            produced = scalars[Symbol("Complex.source1.packets:count")] +
                       scalars[Symbol("Complex.source2.packets:count")]
            @test produced > 0
            # … through a compound queue whose levels are both used …
            @test scalars[Symbol("Complex.queue.queues[1].packets:count")] > 0
            @test scalars[Symbol("Complex.queue.queues[2].packets:count")] > 0
            # … a server that took what the scheduler handed it …
            @test scalars[Symbol("Complex.server.packets:count")] <=
                  scalars[Symbol("Complex.queue.scheduler.packets:count")]
            # … and a filter that let about three quarters of it through.
            served = scalars[Symbol("Complex.server.packets:count")]
            arrived = scalars[Symbol("Complex.sink.packets:count")]
            @test 0.6 <= arrived / served <= 0.9
        end

        @testset "the drop-tail step drops what the plain queue does not" begin
            # The two queue steps run the same model and differ only in their
            # configuration, which is the point the pages make.
            plain = only(e for e in _tutorial_embeds(load_tutorial_page("queues/Queue.md"))
                         if e isa SimulationEmbed)
            dropping = only(e for e in _tutorial_embeds(
                                load_tutorial_page("queues/DropTailQueue.md"))
                            if e isa SimulationEmbed)
            @test plain.model === dropping.model
            embed_finish!(plain)
            embed_finish!(dropping)
            key = Symbol("Queuing.queue.droppedPacketsQueueOverflow:count")
            @test Dict(workbench_result(plain.workbench).scalars)[key] == 0
            @test Dict(workbench_result(dropping.workbench).scalars)[key] > 100
        end

        @testset "the diagram in the card is live while the run advances" begin
            embed = only(e for e in _tutorial_embeds(load_tutorial_page("queues/Queue.md"))
                         if e isa SimulationEmbed)
            iomap = Projectured.print_document(
                OmnetppPresentation.SimulationEmbedToWidget(), embed)
            pane = collect(iomap.output.children)[5]
            # Nothing to draw before the run …
            @test length(pane.content.vertices) == 0
            @test length(pane.children) == 0
            embed_finish!(embed)

            # … and afterwards, one node per module, wired the way the engine
            # read it: the diagram comes from the same `model_topology`.
            graph = pane.content
            @test length(graph.vertices) == 4
            @test length(graph.edges) == 3

            # A node is drawn the way OMNeT++ draws a module: its icon, with its
            # own name (not its whole path) underneath.
            rows(i) = collect(graph.vertices[i].content.children)
            @test [last(rows(i)).content for i in 1:4] ==
                  ["source", "queue", "server", "sink"]
            # Every queuing element names an icon and all four resolve to an
            # image that ships, so each node has an image row above its name.
            @test all(length(rows(i)) == 2 for i in 1:4)
            @test all(first(rows(i)).content isa Projectured.ImageModule.ImageFile
                      for i in 1:4)

            # Each module's status is anchored *at that module*, one annotation
            # per node, so a reader can tell which is which.
            @test length(pane.children) == 4
            notes = [entry.child.content for entry in pane.children]
            @test any(note -> occursin("waiting", note), notes)   # the queue's
            @test any(note -> occursin("received", note), notes)  # the sink's
            @test all(entry.reference !== nothing for entry in pane.children)
        end

        @testset "an annotation does not move the module it annotates" begin
            # The property the live diagram rests on: a run rewrites what is
            # beside a node every refresh, and the node must not move — which is
            # why the annotations are anchored over the diagram rather than laid
            # out inside it.
            embed = only(e for e in _tutorial_embeds(load_tutorial_page("queues/Queue.md"))
                         if e isa SimulationEmbed)
            iomap = Projectured.print_document(
                OmnetppPresentation.SimulationEmbedToWidget(), embed)
            pane = collect(iomap.output.children)[5]
            embed_finish!(embed)

            output = Projectured.print_document(_tutorial_renderer(), pane).output
            # The diagram is drawn first and the four annotations over it.
            elements = collect(output.elements)
            diagram = first(elements)
            @test length(elements) == 5
            # The node boxes — what a reader sees as a module, and what an
            # annotation is anchored to.
            boxes() = [(Int(e.x), Int(e.y), Int(e.w), Int(e.h))
                       for e in diagram.elements
                       if e isa Projectured.GraphicsModule.GraphicsRect]
            before = boxes()
            @test length(before) == 4

            # Anchored *at its node*, which is the part a `reference` that
            # failed to resolve would silently lose: an unresolved anchor goes
            # to the origin, so four distinct positions centred under four
            # distinct nodes is the assertion that the anchor really resolved.
            # An anchored child is wrapped in a positioning canvas, so its own
            # width is the wrapped label's, one level in.
            note_w(e) = (c = first(e.elements); c isa
                         Projectured.GraphicsModule.GraphicsCanvas ? Int(c.w[]) : 0)
            notes() = [(Int(e.x[]), Int(e.y[]), note_w(e)) for e in elements[2:end]]
            @test length(unique(notes())) == 4
            for (i, (nx, ny, nw)) in enumerate(notes())
                x, y, w, h = before[i]
                @test ny >= y + h                            # below it, as asked
                @test abs((nx + nw ÷ 2) - (x + w ÷ 2)) <= 1  # and centred on it
            end

            # A much longer annotation than the one that was there.
            for entry in pane.children
                Projectured.CellModule.set_cell_function!(
                    entry.child, () -> "a considerably longer annotation")
            end
            @test boxes() == before
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
