"""
    InetExample

Umbrella package over the component example packages, so `using InetExample`
stays the one line that reaches every demo — and the home of the **demo
catalog**, which spans components and so belongs to none of them.

    using InetExample

    run_demo()                    # the catalog, in an editor window
    run_packet_demo(:packet_api)  # a component's own narrated demo

A component's example package joins the loop below and needs no other edit
here.

`demo/` is the catalog's content: `demo.json` names the index page, `index.md`
is the front page and the navigator both, and `pages/` holds one `.md` per page
plus one `.json` per runnable simulation. Marker paths are relative to the
catalog directory — never to the file the marker sits in — which is what gives
each target one canonical name, and one interned document.
"""
module InetExample

import InetPacketExample
import InetQueuingExample

using Inet
using OmnetppSimulator: workbench_refresh!
using OmnetppPresentation: CatalogShell, CatalogShellToWidget, SimulationEmbed,
    catalog_pages, open_page!, register_doctype_module!, simulation_embed_entry,
    workbench_document_dispatch
import Projectured
using Projectured.ChainingProjectionModule: ChainingProjection
using Projectured.MarkdownModule: MarkdownParagraph, MarkdownQuote
using Projectured.NaturalProjectionModule: NaturalToGraphics, natural_to_syntax_dispatch
using Projectured.RecursiveProjectionModule: RecursiveProjection
using Projectured.SyntaxToTextModule: SyntaxToText
using Projectured.TextToGraphicsModule: TextToGraphics
using Projectured.TrueTypeModule: truetype_measure_text
using Projectured.TypeDispatchingProjectionModule: TypeDispatchingProjection
using Projectured.WidgetHoverTrackingProjectionModule: WidgetHoverTrackingProjection
using Projectured.WordWrappingModule: WordWrapping
using ProjecturedDomainExample: run_example

export demo_directory, demo_catalog, demo_projection, run_demo

let _taken = Set{Symbol}()
    for _src in (InetPacketExample, InetQueuingExample)
        _srcname = nameof(_src)
        for _n in names(_src)
            _n === _srcname && continue
            isdefined(_src, _n) || continue   # an export with no binding behind it
            _n in _taken && continue          # homonym — the earlier package won
            push!(_taken, _n)
            Core.eval(@__MODULE__, Expr(:import, Expr(:(:), Expr(:., _srcname), Expr(:., _n))))
            Core.eval(@__MODULE__, Expr(:export, _n))
        end
    end
end

"""
    demo_directory() -> String

Where the catalog's content lives — the base directory every marker path in it
resolves against.
"""
demo_directory() = joinpath(@__DIR__, "demo")

"""
    demo_catalog(; dir = demo_directory()) -> CatalogShell

Load the catalog from `dir` without opening a window: `demo.json` names the
index page, and the shell derives its navigator from that page's own sections
and links.

Useful on its own for walking the catalog headlessly — every page it lists can
be opened with `open_page!` and inspected.

This is `realize(file("demo.json"))` at the catalog's root: the same pair of
marker functions a page uses to embed a simulation, applied to the root file.
"""
demo_catalog(; dir::AbstractString = demo_directory()) =
    Projectured.evaluate_marker("realize(file(\"demo.json\"))",
                                Projectured.LoaderContext(dir))

"""
    demo_projection(; measure = truetype_measure_text) -> Projection

The projection [`run_demo`](@ref) opens the catalog with. Exposed so a
screenshot or a test renders the catalog the way a reader sees it rather than
through a convenient approximation of it.

The renderer is `NaturalToGraphics`: a catalog page is a **markdown document**,
and only the natural renderer routes a `MarkdownRoot` through the rule that
turns a page into a stack of blocks. What the workbench's own renderer knows is
spliced in through `extra`, which wins over the defaults: the topology graph
with its layout engine, the parameter primitives, the result charts — plus the
embed card itself, which is what makes `<<realize(…)>>` a live widget in the
middle of prose rather than a document nobody can click.

The hover tracker turns raw pointer motion into the crossings a button's
`hovered` cell keys on, so a card's buttons light up under the pointer.
"""
demo_projection(; measure = truetype_measure_text) =
    WidgetHoverTrackingProjection(inner =
        ChainingProjection(CatalogShellToWidget(),
                           NaturalToGraphics(measure = measure,
                                             extra = vcat(
                                                 Pair{Type,Any}[simulation_embed_entry()],
                                                 _demo_prose_dispatch(measure),
                                                 workbench_document_dispatch(measure = measure)))))

# Prose that wraps to the pane it is in.
#
# The natural renderer wraps a bare text document but sends markdown through the
# to-syntax fabric, which never wraps — correctly, because that fabric also
# carries code, where a line break would be a lie. A page of prose in a window
# the reader can resize needs the opposite, so the wrap is added back for the
# two block types that are prose and nothing else. Code blocks keep the
# unwrapped chain and scroll, which is what a viewport is for.
_demo_prose_dispatch(measure) = Pair{Type,Any}[
    T => ChainingProjection(
             RecursiveProjection(TypeDispatchingProjection(natural_to_syntax_dispatch())),
             RecursiveProjection(SyntaxToText()),
             WordWrapping(measure = measure),
             TextToGraphics(measure = measure))
    for T in (MarkdownParagraph, MarkdownQuote)]

"""
    run_demo(; backend = nothing, dir = demo_directory(), kwargs...)

Open the demo catalog in an editor window: the catalog on the left, the page it
has open on the right.

    using InetExample, ProjecturedSdl
    run_demo(; backend = SdlBackend())

With no `backend` the gallery picks one by reflection over the loaded backends,
so a session that already has `ProjecturedSdl` loaded needs no argument. Every
gallery keyword works here too — `width`, `height`, …

`on_frame` refreshes whichever simulation the open page is showing; a page with
no running simulation costs nothing.

When both example umbrellas are loaded in one REPL, qualify:
`InetExample.run_demo()`.
"""
function run_demo(; backend = nothing, dir::AbstractString = demo_directory(),
                  kwargs...)
    shell = demo_catalog(; dir = dir)
    run_example(shell, demo_projection(); name = "inet-julia demo", backend = backend,
                on_frame = _ -> _refresh_open_page!(shell), kwargs...)
end

# A page holds its embeds as resolved stubs; the ones that are simulations need
# the same per-frame sync the workbench does — an idle simulation is still
# observed, and a chart fills only because something asked it to. Anything else
# on the page is static and is left alone.
function _refresh_open_page!(shell)
    page = shell.page
    page === nothing && return nothing
    for embed in _page_embeds(page)
        wb = embed.workbench
        wb === nothing || workbench_refresh!(wb)
    end
    nothing
end

function _page_embeds(page)
    embeds = Any[]
    _collect_embeds!(embeds, Projectured.content(page), 0)
    embeds
end

function _collect_embeds!(embeds, node, depth)
    depth > 16 && return
    node isa Projectured.CellModule.AbstractCell &&
        return _collect_embeds!(embeds, node[], depth)
    if node isa Projectured.FileProjectModule.ReferenceStub
        resolved = node.resolved
        resolved isa SimulationEmbed && push!(embeds, resolved)
        return
    end
    node isa SimulationEmbed && return push!(embeds, node)
    for field in (:elements, :items, :content)
        hasproperty(node, field) || continue
        value = getproperty(node, field)
        value isa AbstractString && continue
        value isa Projectured.CellModule.AbstractCell && (value = value[])
        if value isa AbstractVector || value isa Projectured.CollectionModule.CellVector
            for child in value
                _collect_embeds!(embeds, child, depth + 1)
            end
        end
    end
end

# A step file naming `QueuingModel` or `T1sModel` has to be able to find it, and
# the loader searches only the modules it has been told about. `Inet` cannot
# register itself — that would point the model library at the presentation
# stack, which the layering forbids — so the registration happens here, in the
# package that already depends on both. Runtime state, hence `__init__` rather
# than a top-level call (`register_doctype_module!`'s own rule).
function __init__()
    register_doctype_module!(Inet)
end

end # module InetExample
