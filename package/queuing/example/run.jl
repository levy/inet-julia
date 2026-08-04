# Open the queuing tutorial in the editor.
#
#     julia --project=. package/queuing/example/run.jl
#
# The shell renders as a widget stage followed by the page renderer — the
# workbench's own shape. The simulation-embed entry is what makes an embedded
# card a real widget: its Run button is clickable, and the run drives the same
# workflow the full stage column does.
using InetQueuingExample
using OmnetppPresentation: simulation_embed_entry
using Projectured
using Projectured.ChainingProjectionModule: ChainingProjection
using Projectured.RecursiveProjectionModule: RecursiveProjection

shell = InetQueuingExample.load_tutorial()

renderer = ChainingProjection(
    RecursiveProjection(InetQueuingExample.TutorialShellToWidget()),
    Projectured.NaturalToGraphics(measure = Projectured.truetype_measure_text,
                                  extra   = Pair{Type,Any}[simulation_embed_entry()]))

Projectured.run_editor!(Projectured.Editor(shell, renderer))
