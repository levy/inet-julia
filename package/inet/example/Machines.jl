# ────────────────────────────────────────────────────────────────────────────
# The protocol's state machines, on a page.
#
# A machine here is a document: `tool/generate_mac_fsm.jl` declares it, the
# running `MacFsm.jl` is generated from it, and `watch/mac_fsm.jl` draws it as
# a diagram. One machine, three views, none of which can drift from the others.
#
# The catalog could not reach it, though. Every marker in the vocabulary names
# a FILE — `file` and `definition` read one, `realize` builds the document a
# step file describes — and this machine is not in a file. It is what a
# function returns.
#
# `fsm("name")` is the marker that reaches it, and the table below is what
# keeps the marker language restricted while it does: a marker still names
# data rather than calling arbitrary Julia. Adding a machine is one entry.
# ────────────────────────────────────────────────────────────────────────────

# The generators, each in a module of its own. Including one does not
# regenerate anything — both files write their output only when run as a
# script, and say so — but every generator defines `main` and `OUTPUT`, so a
# second one included into the same namespace would collide with the first.
#
# Reaching out to `tool/` is deliberate. The machine belongs to the ProjecturEd
# world (it is built out of `FsmState` and `FsmTransition`), and `InetLinkLayer`
# deliberately does not depend on Projectured — which is exactly why the
# generator is a tool and not part of that package. This example package is
# where Inet and Projectured already meet, so it is the one place that can hold
# both ends.
module MacFsmSource
    using Projectured
    include(joinpath(@__DIR__, "..", "..", "..", "tool", "generate_mac_fsm.jl"))
end

"""
    FSM_MACHINES :: Dict{String, Function}

Every machine a page may name, and the thunk that builds it. A component can
declare more than one machine — PLCA's control and data machines share a
component — so an entry names the machine, not the component it came from.
"""
const FSM_MACHINES = Dict{String, Function}(
    "ethernet_csma_mac" => () -> MacFsmSource.ethernet_csma_mac_component().machines[1],
)

"""
    fsm_machines() -> Vector{String}

The name of every machine a page may embed.
"""
fsm_machines() = sort!(collect(keys(FSM_MACHINES)))

# `<<fsm("ethernet_csma_mac")>>` — the marker's implementation. The value is
# interned by the load session like every other marker, so a machine embedded
# twice is one document.
function marker_fsm(_ctx, name::AbstractString)
    build = get(FSM_MACHINES, String(name), nothing)
    build === nothing &&
        error("fsm(", repr(String(name)), "): no such machine; available: ",
              join(fsm_machines(), ", "))
    build()
end

# ── A machine, sized so a page can lay it out ───────────────────────────────
#
# A graph left as a document child has no size while the block above it is
# being laid out — the render stage has not routed it yet — so a page that
# splices one in allocates no room and draws the next paragraph straight
# through the diagram. `SimulationTopologyToWidget` hit this first and its
# comment states the only arrangement that measures: a scroll pane with an
# EXPLICIT size, holding the graph document.
#
# So this is what an `FsmMachine` becomes on a page. The diagram inside stays a
# document, which is what lets the render stage route it through the labelled
# pipeline below rather than flattening it here.
"""
    FsmMachineToWidget(; width, max_height, measure)

A state machine as a pane holding its diagram, sized to the diagram. A machine
too big for `max_height` scrolls rather than pushing the prose after it down
the page.
"""
struct FsmMachineToWidget <: Projection
    width::Int
    max_height::Int
    measure::Any
end
FsmMachineToWidget(; width::Integer = 1000, max_height::Integer = 620,
                   measure = truetype_measure_text) =
    FsmMachineToWidget(Int(width), Int(max_height), measure)

# The pane's height is the diagram's own, which means laying the diagram out
# here to ask how tall it came out. That is a second layout pass — the render
# stage runs the real one when it routes the document below — and it earns its
# keep: a fixed height is either a band of empty page under a small machine or a
# scroll bar over a large one, and which you get depends on a constant somebody
# guessed.
function print_document(p::FsmMachineToWidget, recursion, machine, ctx)
    diagram = get_iomap_output(print_document(FsmToFsmDiagram(), machine))
    height, origin = _fsm_diagram_box(diagram, p)
    SimpleIoMap(nothing, machine,
                VerticalLayout(Any[WidgetScrollPane(diagram;
                                                    size = Point2D(p.width, height),
                                                    scroll_position = origin)];
                               gap = 0))
end

# How tall the laid-out diagram is, and where its content actually starts.
# `_canvas_content_bounds` is what the backend walks to size a canvas, so this
# measures what will be drawn rather than estimating from the node count.
#
# The origin matters as much as the height. A layout engine places nodes around
# whatever point it likes, so a diagram routinely extends LEFT of and ABOVE its
# own zero — and a pane shows content from zero, which quietly clips whatever
# landed there. Scrolling the pane to the content's own top-left is what brings
# it back: a negative offset is exactly the shift that says "start here".
function _fsm_diagram_box(diagram, p::FsmMachineToWidget)
    canvas = get_iomap_output(print_document(fsm_diagram_entry(measure = p.measure).second,
                                             diagram))
    x0, y0, _x1, y1 = Projectured.GraphicsModule._canvas_content_bounds(canvas, p.measure)
    height = clamp(y1 - y0 + 24, 140, p.max_height)
    # A small inset so the leftmost label is not flush against the border.
    (height, Point2D(min(x0 - 12, 0), min(y0 - 12, 0)))
end

map_reference_forward(::FsmMachineToWidget, iomap, reference)  = nothing
map_reference_backward(::FsmMachineToWidget, iomap, reference) = nothing
# Only operations travel up. Returning a raw gesture here would short-circuit
# the enclosing projection's own first say — the rule a pass-through reader
# follows everywhere in this stack.
read_intent(::FsmMachineToWidget, iomap, op) = op isa Operation ? op : nothing

"""
    fsm_machine_entry(; measure, width, max_height) -> Pair{Type,Any}

The dispatch entry that makes an `FsmMachine` on a page render as a state
diagram. Splice it into a renderer's `extra` table beside
`simulation_embed_entry()`.
"""
fsm_machine_entry(; measure = truetype_measure_text, width::Integer = 1000,
                  max_height::Integer = 620) =
    FsmMachine => ChainingProjection(
        FsmMachineToWidget(width = width, max_height = max_height, measure = measure),
        VerticalLayoutToGraphicsCanvas())

# What an edge says: the trigger that fires it, and nothing else. A timer reads
# as `timeout(name)`, matching the shared label's spelling; a transition with no
# trigger at all — PLCA's machines are entirely condition-driven — draws an
# unlabelled edge rather than an empty box.
_fsm_trigger_text(transition) = begin
    trigger = transition.trigger
    trigger === nothing ? "" :
        trigger isa FsmTimer ? "timeout($(trigger.name))" : trigger.name
end

"""
    FsmTriggerLabel()

An edge label that is just the trigger. The shared `FsmTransitionToSyntaxLabel`
adds the guard and the action, which a window has room for and a page does not.
"""
@projection struct FsmTriggerLabel
    trigger::ImmutableCell{DCStyleText} =
        StyleText(font_ubuntu_monospace_regular_20, color_solarized_violet)
end

@projection_template FsmTriggerLabel FsmTransition (p, doc) ->
    SyntaxLeaf(TextString(() -> _fsm_trigger_text(doc), p.trigger))

"""
    fsm_diagram_entry(; measure = truetype_measure_text) -> Pair{Type,Any}

The diagram inside that pane, rendered: states are nodes, transitions are
edges, and the layout is computed rather than drawn by hand.

The pipeline is `watch/mac_fsm.jl`'s, which is the point — that demo lights the
same diagram up while a simulation runs, so what a page shows and what the
watch view shows are one projection of one document.

Labels go through the syntax fabric rather than being stringified here: a
state's label is its own `FsmState` document projected to syntax.

Edges carry the **trigger only** — `FsmTriggerLabel` below rather than the
shared `FsmTransitionToSyntaxLabel`, which also renders the guard and the
action. Those are the right thing in the watch view, which owns a window; on a
page they are hundreds of pixels of Julia per edge, and fifteen of them overlap
into an unreadable mat. The guards are not lost: they are in the declaration
directly under the diagram, where there is room to read them.

`FsmDiagram` rather than `GraphGraph` is what this keys on. The graph type is
already spoken for — the topology card renders one, with `WidgetBadge` vertices
that know nothing of the syntax fabric — and two entries for one type would
have the last one written win over a diagram that has nothing to do with it.
"""
function fsm_diagram_entry(; measure = truetype_measure_text)
    label = ChainingProjection(
        RecursiveProjection(TypeDispatchingProjection(
            FsmState      => FsmStateToSyntaxLabel(),
            FsmTransition => FsmTriggerLabel(),
            Any           => FsmToSyntax())),
        RecursiveProjection(SyntaxToText()),
        TextToGraphics(measure = measure))
    FsmDiagram => ChainingProjection(
        FsmDiagramToGraph(),
        NestingProjection(
            ChainingProjection(GraphGraphToGraphLayout(default_topology_engine()),
                               GraphLayoutToGraphicsCanvas());
            recursion = label))
end
