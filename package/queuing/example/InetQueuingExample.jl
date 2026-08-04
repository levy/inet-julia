"""
    InetQueuingExample

INET's queueing tutorial, migrated as a **navigable document**: the prose is
ordinary markdown, and an embed marker splices in whatever its expression
evaluates to — a fragment of the model's real source, or the live simulation
the step is about.

    ```pred-ref
    <<realize(file("queues/Queue.json"))>>
    ```

So a step's page carries the model it describes, and a reader configures and
runs it without leaving the page. See
`plan/pending/queuing-tutorial-migration.md`.

`tutorial/` is the content: `index.md` is the entry page, one `.md` per step,
and one `.json` per runnable simulation. Marker paths are relative to the
tutorial directory (the project's base), never to the file the marker sits in —
which is what gives each target one canonical name, and one interned document.
"""
module InetQueuingExample

using InetQueuing
using InetPacket
using OmnetppSimulator
using OmnetppPresentation: register_doctype_module!
import Projectured
# `@document`'s expansion names these, so they must be in scope where a step
# model is declared.
using Projectured.DocumentModule: @document
using Projectured.ReferenceModule: Reference
using Projectured.CellModule: ImmutableCell

export tutorial_directory, load_tutorial, load_tutorial_page, test_tutorial

"""
    tutorial_directory() -> String

Where the tutorial's content lives — the base directory every marker path in
it resolves against.
"""
tutorial_directory() = joinpath(@__DIR__, "tutorial")

"""
    load_tutorial() -> CatalogShell

Open the tutorial: the shell described by `tutorial/root.json`, with its
navigator built from `index.md`'s own sections and links, and the index
showing.

The shell is `OmnetppPresentation`'s `CatalogShell` — a project of markdown
pages open at one of them, which is what a tutorial is and what a catalog is.
The tutorial's own copy of it was the first one written; the general version
carries the sections, the draggable divider and the survives-a-broken-embed
behaviour, so there is one shell rather than two that drift.

This is `realize(file("root.json"))` at the tutorial's root — the same pair of
marker functions a page uses to embed a step.
"""
load_tutorial() =
    Projectured.evaluate_marker("realize(file(\"root.json\"))",
                                Projectured.LoaderContext(tutorial_directory()))

"""
    load_tutorial_page(name = "index.md"; force = true) -> MarkdownFile

Load one page of the tutorial, forcing its embeds so the fragments and
simulations are present (`force = false` leaves them as markers, which is what
a lazy shell wants — a step's simulation is built the first time the step is
shown).
"""
function load_tutorial_page(name::AbstractString = "index.md"; force::Bool = true)
    page = Projectured.load_project(Projectured.MarkdownFile, String(name), tutorial_directory())
    force && Projectured.resolve_stubs!(page)
    page
end

# The models the steps run — example code, embedded by name from the pages that
# explain them.
include("steps/sources.jl")
include("steps/classify.jl")
include("steps/plumbing.jl")
include("steps/serve.jl")
include("steps/marking.jl")
include("steps/network.jl")

# The tutorial's own check: every page loads, every embed resolves, and every
# step's simulation runs to its limit. It lives with the content because that is
# what it tests.
include("TutorialTest.jl")

# `"model": "QueuingModel"` in a step file resolves through this: a model
# library makes its models findable by name, and the presentation stack never
# has to know the library exists.
function __init__()
    register_doctype_module!(InetQueuing)
    # And this package itself, so a step file naming one of the models declared
    # under `steps/` resolves it.
    register_doctype_module!(@__MODULE__)
end

end # module InetQueuingExample
