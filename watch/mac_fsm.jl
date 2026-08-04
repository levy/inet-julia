# mac_fsm.jl — the MAC's state machine, watched while the simulation runs.
#
#   julia --project=watch watch/mac_fsm.jl        (headless self-test, no SDL)
#   julia --project=watch watch/mac_fsm_sdl.jl    (live SDL editor)
#
# The diagram is a projection of the *same document* the MAC's code was
# generated from: `tool/generate_mac_fsm.jl` builds the machine, `MacFsm.jl` is
# generated from it, and here that machine is drawn as a graph. So the picture
# cannot drift from the code — there is only one machine.
#
# What makes it live is three integers. The simulation runs on the native
# structs at full speed and never touches a reactive cell; once per slice a
# monitor reads the MAC's `Fsm` and writes the diagram's `live_state`,
# `live_transition` and `transition_count`, each only when it changed. Those
# three cells are all the overlay reads, so a transition repaints the ring and
# the re-stroked edge without re-running the graph layout.

using OmnetppSimulator
using InetLinkLayer
using InetLinkLayer.T1sModule
using Projectured

# The machine document. Including the generator does not regenerate anything —
# it only defines the component.
include(joinpath(@__DIR__, "..", "tool", "generate_mac_fsm.jl"))

"The diagram pipeline: machine → diagram → graph → layout → graphics."
function diagram_projection(; measure = truetype_measure_text)
    label = ChainingProjection(
        RecursiveProjection(TypeDispatchingProjection(
            FsmState      => FsmStateToSyntaxLabel(),
            FsmTransition => FsmTransitionToSyntaxLabel(),
            Any           => FsmToSyntax(),
        )),
        RecursiveProjection(SyntaxToText()),
        TextToGraphics(measure = measure),
    )
    ChainingProjection(
        FsmToFsmDiagram(),
        FsmDiagramToGraph(),
        NestingProjection(
            ChainingProjection(GraphGraphToGraphLayout(FallbackLayoutEngine()),
                               GraphLayoutToGraphicsCanvas());
            recursion = label),
    )
end

"""
    build_watch(; n_nodes, time_limit, node)

The machine, its diagram, and a prepared 10BASE-T1S run to drive it. `node` is
which node's MAC to watch — 1 is the coordinator (which only receives), so the
default is a follower that actually contends and transmits.
"""
function build_watch(; n_nodes::Int = 4, time_limit::Float64 = 500e-6, node::Int = 2)
    component = ethernet_csma_mac_component()
    machine = component.machines[1]

    projection = diagram_projection()
    iomap = print_document(projection, machine)
    # The stage-1 output, whose identity is preserved across reprints — this is
    # the handle the monitor writes to for the rest of the run.
    diagram = iomap.step_iomaps[1][].output

    type = SimulationType(T1sModel)
    assignment = ParameterAssignment(Dict{Symbol,Any}(
        :n_nodes => n_nodes, :time_limit => time_limit, :scenario => :bestcase))
    run = expand_simulation(configure_simulation(type, assignment))[1]
    execution = prepare_simulation_execution(run; engine = SequentialEngineSpec())
    mac = simulation_model(execution).state.nodes[node].mac

    (; component, machine, projection, iomap, diagram, canvas = iomap.output,
       execution, mac)
end

"""
    refresh_diagram!(diagram, mac)

Copy the running MAC's position into the diagram — the whole live seam.

Minimal-write on purpose: the cell engine has no equality check, so writing a
cell its own value still invalidates everything downstream. Three comparisons
here keep a quiet slice free.

`live_state` is 1-based (an index into the machine's states) while the
generated code's state constants are 0-based, because those values are recorded
as statistics and had to match the enum they replaced. `last_transition` needs
no adjustment: the generator numbers transitions in the machine's flattened
order, which is the same order the diagram's edge highlight indexes.
"""
function refresh_diagram!(diagram, mac)
    state = Int(fsm_state(mac.fsm_mac)) + 1
    diagram.live_state == state || (diagram.live_state = state)
    transition = Int(mac.fsm_mac.last_transition)
    diagram.live_transition == transition || (diagram.live_transition = transition)
    count = mac.fsm_mac.transition_count
    diagram.transition_count == count || (diagram.transition_count = count)
    diagram
end

"""
    step_watch!(w)

Advance the simulation by exactly one event and refresh the diagram. This is
the mode in which every transition is visible: at full speed a slice collapses
many transitions into one repaint, which is honest but not watchable.
"""
function step_watch!(w)
    step_simulation!(w.execution)
    refresh_diagram!(w.diagram, w.mac)
    w
end

"""
    drive_watch!(w; slice, pace)

Run to completion in wall-clock slices, refreshing the diagram after each and
yielding so the editor repaints. `pace` slows the run down to something a human
can follow (a 500 µs simulation finishes in milliseconds otherwise).
"""
function drive_watch!(w; slice::Float64 = 0.05, pace::Float64 = 0.0)
    drive_simulation!(w.execution; slice = slice, after_slice = _ -> begin
        refresh_diagram!(w.diagram, w.mac)
        pace > 0 && sleep(pace)
    end)
    w
end

# ── headless self-test ──────────────────────────────────────────────────────
#
# Everything above, verified without a window: the overlay must track the MAC
# through a real run, and must do it by writing cells rather than reprinting.

function selftest()
    w = build_watch()
    canvas = w.canvas
    rings() = count(e -> e isa GraphicsRect, canvas.elements)
    strokes() = count(e -> e isa GraphicsPolyline, canvas.elements)

    # Six states, and one edge per transition that has a target.
    @assert length(w.machine.states) == 6
    @assert w.diagram.live_state == 0
    boxes, edges = rings(), strokes()

    # Step until the MAC first moves, then check the picture followed.
    moved = false
    for _ in 1:2000
        step_watch!(w)
        if w.diagram.transition_count > 0
            moved = true
            break
        end
    end
    @assert moved "the MAC never left its initial state"

    state = Int(fsm_state(w.mac.fsm_mac)) + 1
    @assert w.diagram.live_state == state
    # The current state draws a ring; the transition that got there re-strokes
    # its edge (unless it was a stay, which has no edge).
    @assert rings() == boxes + 1
    @assert strokes() in (edges, edges + 1)

    # Run the rest of the way and check the overlay still agrees with the MAC.
    drive_watch!(w)
    @assert w.diagram.live_state == Int(fsm_state(w.mac.fsm_mac)) + 1
    @assert w.diagram.transition_count == w.mac.fsm_mac.transition_count
    @assert w.diagram.transition_count > 1
    @assert rings() == boxes + 1

    println("mac_fsm selftest OK — ",
            w.diagram.transition_count, " transitions, MAC ended in ",
            MAC_STATE_NAMES[w.diagram.live_state],
            ", ", w.mac.num_frames_sent, " frames sent")
    w
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    selftest()
end
