# The run that `InetRepl.record_precompile_statements` traces.
#
# It is not run by a build. A person runs the recorder, this drives the editor
# the way a reader drives it, and Julia writes down every method instance it had
# to compile. The list is then checked in, and later builds replay it.
#
# Being outside the build is what lets this be slow, use a real window and open
# every page in the catalog: nobody waits for it.
#
# Needs a display. SDL asks for an accelerated renderer, which the dummy video
# driver does not offer.

using InetRepl
using Projectured
using ProjecturedExample
using InetExample
using ProjecturedSdl: SdlBackend

using Projectured.EditorModule: Editor, evaluate!, print!
using Projectured.BackendModule: initialize_backend!, quit_backend!, configure_devices!
using Projectured.DeviceModule: Device, Display, Keyboard, Mouse
using Projectured.ClockModule: set_clock_time!
using Projectured.EventModule: WindowInput, MousePress, MouseMove, MouseScroll,
    KeyDown, KeyPress, ModifierKeys
using Projectured.IntentModule: Intent
using Projectured.ProjectionApiModule: read_intent
using Projectured.OperationModule: Operation
using Projectured.WidgetModule: InvokeActionOperation

const WIDTH, HEIGHT = 1600, 1000

# The workload a `:live` build runs, so that everything it compiles is in the
# recording too. A recording is only allowed to replace it if it is a superset.
InetExample.precompile_workload()

# The keys and the wheel, once each. A key's value is a run-time value, so one
# press compiles the same code as a thousand; what has to vary is the KIND of
# event.
const GESTURES = Any[
    MouseMove(40, 200), MouseMove(800, 300), MouseMove(800, 500),
    MousePress(:left, 800, 400), MousePress(:right, 800, 400),
    MouseScroll(0, -3, 800, 400), MouseScroll(0, 3, 800, 400),
    KeyDown(:down, ModifierKeys()), KeyDown(:up, ModifierKeys()),
    KeyDown(:left, ModifierKeys()), KeyDown(:right, ModifierKeys()),
    KeyDown(:tab, ModifierKeys()), KeyDown(:home, ModifierKeys()),
    KeyDown(:end, ModifierKeys()), KeyDown(:backspace, ModifierKeys()),
    KeyDown(:delete, ModifierKeys()), KeyDown(:enter, ModifierKeys()),
    KeyPress('x'), KeyPress('1'),
]

backend = SdlBackend()
initialize_backend!(backend)
devices = Device[Display(), Keyboard(), Mouse()]
configure_devices!(backend, devices)

t0 = time()

# ── this repository's catalog ──────────────────────────────────────────────

shell = InetExample.demo_catalog()
projection = InetExample.demo_projection()
screen = ProjecturedExample._build_window_scene(Any[shell], String["demo"];
                                                width = WIDTH, height = HEIGHT)
composed = ProjecturedExample._multi_window_projection(Any[projection])
editor = Editor(backend, screen, composed, devices)

tick!() = set_clock_time!(editor.clock, time() - t0)

function drive!(event)
    tick!()
    change = read_intent(editor.projection, nothing,
                         Intent(WindowInput(:demo, event), nothing), editor.iomap)
    operation = change isa Intent ? change.operation : change
    editor.operation = operation isa Operation ? operation : nothing
    evaluate!(editor)
    print!(editor)
    operation
end

for _ in 1:4
    tick!(); print!(editor)
end

# Every navigator row the window shows, opened and painted, then opened again:
# the second click is where an io map is reconciled rather than built.
opened = String[]
for pass in 1:2, y in 20:6:(HEIGHT - 20)
    operation = drive!(MousePress(:left, 40, y))
    operation isa InvokeActionOperation || continue
    pass == 1 || continue
    name = try string(Projectured.filename(shell.page)) catch; "" end
    (isempty(name) || name in opened) || push!(opened, name)
end
println("driver: opened ", length(opened), " pages")

for event in GESTURES
    drive!(event)
end

# ── the upstream examples ──────────────────────────────────────────────────
#
# A person in this session can open any of them, and an image only helps the
# session that loads it, so this repository's list has to carry them too.
function drive_example!(document, projection)
    example_screen = ProjecturedExample._build_window_scene(Any[document],
                                                            String["example"];
                                                            width = WIDTH, height = HEIGHT)
    example_composed = ProjecturedExample._multi_window_projection(Any[projection])
    example_editor = Editor(backend, example_screen, example_composed, devices)
    set_clock_time!(example_editor.clock, time() - t0)
    print!(example_editor)
    for event in GESTURES
        set_clock_time!(example_editor.clock, time() - t0)
        change = read_intent(example_editor.projection, nothing,
                             Intent(WindowInput(:example, event), nothing),
                             example_editor.iomap)
        operation = change isa Intent ? change.operation : change
        example_editor.operation = operation isa Operation ? operation : nothing
        evaluate!(example_editor)
        print!(example_editor)
    end
    nothing
end

driven = 0
refused = 0
for example in ProjecturedExample.examples
    try
        drive_example!(example.document, example.projection)
        global driven += 1
    catch err
        global refused += 1
        println("driver: ", example.name, " refused — ",
                first(split(sprint(showerror, err), "\n")))
    end
end
println("driver: drove ", driven, " examples, ", refused, " refused")

quit_backend!(backend)
println("driver: done")
