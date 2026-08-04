# Open the queuing tutorial in the editor.
#
#     julia --project=. package/queuing/example/run.jl
#
# The page renders through the natural renderer with the simulation-embed entry
# spliced in, which is what makes an embedded card a real widget: its Run button
# is clickable, and the run drives the same workflow the full stage column does.
using InetQueuingExample
using OmnetppPresentation: simulation_embed_entry
using Projectured

page = InetQueuingExample.load_tutorial_page("queues/Queue.md")

renderer = Projectured.NaturalToGraphics(
    measure = Projectured.truetype_measure_text,
    extra   = Pair{Type,Any}[simulation_embed_entry()])

Projectured.run_editor!(Projectured.Editor(Projectured.content(page), renderer))
