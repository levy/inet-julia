# mac_fsm_sdl.jl — the live editor: watch the MAC's state machine while a
# 10BASE-T1S simulation runs.
#
#   julia --project=watch watch/mac_fsm_sdl.jl              # stepped, one event per frame
#   julia --project=watch watch/mac_fsm_sdl.jl --run        # runs to completion, paced
#
# The current state is ringed and the last transition taken is re-stroked. In
# stepped mode every transition is visible; running free, a repaint shows
# wherever the machine got to during that slice.
#
# The run drives itself on its own task and writes no reactive cell. A frame is
# reading and painting those cells, so what the run reached is handed to the
# editor as an operation, and the editor applies it on its own task at its own
# moment — the same guarantee an operation from the reader has.
include(joinpath(@__DIR__, "mac_fsm.jl"))

# `mac_fsm.jl` already brings in the umbrella, which re-exports the editor,
# screen and projection names flatly — no sub-package imports needed. The one
# exception is a function this file adds a method to, which has to be imported
# by name.
using ProjecturedSdl: SdlBackend
import ProjecturedSdl
import Projectured.OperationModule: evaluate_operation

# The diagram inside the screen/window seam the SDL backend needs.
function screen_projection(; measure = truetype_measure_text)
    RecursiveProjection(TypeDispatchingProjection(
        ScreenDocument => WindowManagingProjection(inner = ScreenToScreen()),
        WindowDocument => ScreenToScreen(),
        Any            => NestingProjection(diagram_projection(measure = measure);
                                            recursion = IdentityProjection()),
    ))
end

# ── handing over what the run reached ───────────────────────────────────────

"""
    SyncDiagramOperation(watch, done)

Copy where the MAC got to into the diagram. `done` is notified once the editor
has applied it, which is what parks the driver until then.
"""
struct SyncDiagramOperation <: Operation
    watch::Any
    done::Any                   # ::Base.Event
end

function evaluate_operation(editor, op::SyncDiagramOperation)
    try
        refresh_diagram!(op.watch.diagram, op.watch.mac)
    finally
        notify(op.done)         # a failed sync must not leave the driver parked
    end
    nothing
end

"""
    DiagramSync(editor)

Where a driver posts, and the sync it is waiting for. `stop` is set once the
window has closed: nothing drains the inbox after that, so a driver parked on a
sync is released here rather than left waiting for a frame that never comes.
"""
mutable struct DiagramSync
    editor::Any
    pending::Any                # ::Base.Event — the sync in flight, or nothing
    stop::Bool
end

DiagramSync(editor) = DiagramSync(editor, nothing, false)

"""
    sync_diagram!(sync, w) -> Bool

Ask for one still image and wait until it has been taken. Answer `false` when
the editor is gone, which is the driver's signal to stop.

The wait is what makes the image still: the caller is the task that would
otherwise be advancing the run, so parking it here is precisely the moment
nothing is moving. It is also the backpressure — one sync is in flight at a
time, so a slow frame cannot build a backlog of images that are stale before
they are drawn.
"""
function sync_diagram!(s::DiagramSync, w)
    s.stop && return false
    done = Base.Event()
    s.pending = done
    post_operation!(s.editor, SyncDiagramOperation(w, done))
    wait(done)
    s.pending = nothing
    !s.stop
end

"""
    stop_sync!(sync) -> sync

Release a driver parked on a sync. What the closed window calls.
"""
function stop_sync!(s::DiagramSync)
    s.stop = true
    pending = s.pending
    pending === nothing || notify(pending)
    s
end

"""
    drive_editor!(sync, w; stepped, pace, slice)

Advance the run and hand each image over.

Stepped is one event and one image, and the wait inside the sync paces it to the
editor's frames — which is what makes every transition visible. Free-running,
the run paces itself in wall-clock slices and hands over what it reached after
each one; `pace` slows it to something a human can follow.
"""
function drive_editor!(s::DiagramSync, w; stepped::Bool, pace::Float64 = 0.0,
                       slice::Float64 = 0.05)
    if stepped
        while !simulation_finished(w.execution)
            step_simulation!(w.execution)
            sync_diagram!(s, w) || return w
        end
    else
        drive_simulation!(w.execution; slice = slice, after_slice = _ -> begin
            if !sync_diagram!(s, w)
                simulation_finished(w.execution) || stop_simulation!(w.execution)
            elseif pace > 0
                sleep(pace)
            end
        end)
    end
    sync_diagram!(s, w)         # the state the run finished in
    w
end

function run_sdl(; stepped::Bool = true, pace::Float64 = 0.08,
                 width = nothing, height = nothing)
    _sw, _sh = ProjecturedSdl.sdl_display_size()
    width  = something(width, _sw)
    height = something(height, _sh)

    w = build_watch()
    window = WindowDocument(; id = :mac_fsm,
                            title = "EthernetCsmaMac — the machine its code is generated from",
                            x = 80, y = 60, width = width, height = height,
                            content = w.machine)
    screen = ScreenDocument([window])

    # The editor loop below is silenced, and the driver task inherits that. Its
    # failures must still be seen, so they are reported to the logger in force
    # here.
    logger = Base.CoreLogging.current_logger()
    sync = Ref{Any}(nothing)
    try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            # `on_start` is the first moment the editor exists, and so the first
            # moment a driver can be given one to post to.
            run_editor!(SdlBackend(), screen_projection(), screen;
                        on_start = editor -> begin
                            s = DiagramSync(editor)
                            sync[] = s
                            @async try
                                drive_editor!(s, w; stepped = stepped, pace = pace)
                            catch e
                                Base.CoreLogging.with_logger(logger) do
                                    @error "simulation task failed" exception = (e, catch_backtrace())
                                end
                            end
                        end)
        end
    finally
        sync[] === nothing || stop_sync!(sync[])
        simulation_finished(w.execution) || stop_simulation!(w.execution)
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    run_sdl(stepped = !("--run" in ARGS))
end
