# mac_fsm_sdl.jl — the live editor: watch the MAC's state machine while a
# 10BASE-T1S simulation runs.
#
#   julia --project=watch watch/mac_fsm_sdl.jl              # stepped, one event per key
#   julia --project=watch watch/mac_fsm_sdl.jl --run        # runs to completion, paced
#
# The current state is ringed and the last transition taken is re-stroked. In
# stepped mode every transition is visible; running free, a repaint shows
# wherever the machine got to during that slice.
include(joinpath(@__DIR__, "mac_fsm.jl"))

# `mac_fsm.jl` already brings in the umbrella, which re-exports the editor,
# screen and projection names flatly — no sub-package imports needed.
using ProjecturedSdl: SdlBackend
import ProjecturedSdl

# The diagram inside the screen/window seam the SDL backend needs.
function screen_projection(; measure = truetype_measure_text)
    RecursiveProjection(TypeDispatchingProjection(
        ScreenDocument => WindowManagingProjection(inner = ScreenToScreen()),
        WindowDocument => ScreenToScreen(),
        Any            => NestingProjection(diagram_projection(measure = measure);
                                            recursion = IdentityProjection()),
    ))
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

    driver = stepped ? nothing : @async try
        drive_watch!(w; pace = pace)
    catch e
        @error "simulation task failed" exception = (e, catch_backtrace())
    end

    try
        Base.CoreLogging.with_logger(Base.CoreLogging.NullLogger()) do
            # Stepped mode advances the simulation one event per frame, which is
            # what makes each transition individually visible; the free-running
            # mode leaves the driver task to pace itself.
            run_editor!(SdlBackend(), screen_projection(), screen;
                        on_frame = stepped ? (_ -> step_watch!(w)) : (_ -> refresh_diagram!(w.diagram, w.mac)))
        end
    finally
        driver === nothing || stop_simulation!(w.execution)
    end
end

if abspath(PROGRAM_FILE) == abspath(@__FILE__)
    run_sdl(stepped = !("--run" in ARGS))
end
