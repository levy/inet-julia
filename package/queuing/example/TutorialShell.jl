# ────────────────────────────────────────────────────────────────────────────
# TutorialShell — the tutorial as one navigable thing: the steps down the left,
# the step you are reading on the right.
#
# Concatenating 49 pages into one document would make navigation a scroll and
# every step's simulation live at once. A shell keeps them separate: the
# navigator lists what `index.md` links to, and the content pane holds the one
# page that is open. Switching pages is `file(path)` in the tutorial's own load
# session, so a page visited twice is one document — with its embeds already
# resolved, and its simulation still where the reader left it.
#
# The shell is content, so it lives here rather than in the presentation stack.
# Promoting it to a general "browse a project of markdown pages" document is
# worth doing once a second tutorial wants one.
# ────────────────────────────────────────────────────────────────────────────

using Projectured.DocumentModule: @document, Document
using Projectured.CellModule: Cell, ComputedCell, AbstractCell, set_cell_function!,
    unwrap_cell
using Projectured.CollectionModule: CellVector
using Projectured.ReferenceModule: Reference, get_reference_steps, FieldReferenceStep,
    RangeReferenceStep, ConcreteReference, EmptyReference, strip_reference_types
using Projectured.MarkdownModule: MarkdownDocument, MarkdownRoot, MarkdownLink,
    MarkdownHeading, MarkdownList, MarkdownListItem, MarkdownParagraph
import Projectured.ProjectionApiModule: print_document, read_intent,
    map_reference_forward, map_reference_backward
using Projectured.ProjectionApiModule: Projection
using Projectured.IoMapModule: IoMap, var"@iomap"
using Projectured.OperationModule: Operation, ReplaceSelectionOperation
using Projectured.WidgetModule: WidgetList, WidgetLabel, WidgetScrollPane, Point2D,
    widget_list_selection, InvokeActionOperation, Action
using Projectured.LayoutModule: HorizontalLayout, VerticalLayout
import OmnetppPresentation: _from_json, doctype_file
using OmnetppPresentation: LoadCtx

export TutorialShell, TutorialShellToWidget, tutorial_steps, open_step!

"""
    TutorialStep(title, path)

One entry of the navigator: what `index.md` calls a step, and the page it
links to (relative to the tutorial directory, like every marker path).
"""
@document struct TutorialStep
    title::String
    path::String
end

"""
    TutorialShell(index; steps, page, base_dir, loader)

The tutorial, open at one step. `index` is the parsed `index.md`, `steps` the
entries its links name, `page` the one currently shown (the index itself until
a step is opened).

`loader` is the tutorial's load session: opening a step goes through it, so
pages, fragments and simulations are interned across the whole tutorial rather
than per page.
"""
@document struct TutorialShell
    index::Any
    steps::CellVector = CellVector()
    page::Any         = nothing
    base_dir::String  = ""
    loader::Any       = nothing
end

"""
    tutorial_steps(index_document) -> Vector{TutorialStep}

The steps a tutorial index names: every markdown link to a `.md` page, in the
order they appear. The index is ordinary prose, so the links are what a reader
would click anyway — nothing declares the navigation twice.
"""
function tutorial_steps(document)
    steps = TutorialStep[]
    _collect_links!(steps, document, 0)
    steps
end

_link_text(node) = begin
    buffer = IOBuffer()
    _collect_text!(buffer, node, 0)
    strip(String(take!(buffer)))
end

function _collect_text!(buffer, node, depth)
    depth > 12 && return
    node isa AbstractCell && return _collect_text!(buffer, node[], depth)
    if hasproperty(node, :content)
        content = node.content
        content isa AbstractString && return print(buffer, content)
        for child in _children_of(content)
            _collect_text!(buffer, child, depth + 1)
        end
    end
end

_children_of(x) = x isa CellVector ? collect(x) : (x isa AbstractVector ? x : ())

function _collect_links!(steps, node, depth)
    depth > 12 && return
    node isa AbstractCell && return _collect_links!(steps, node[], depth)
    if node isa MarkdownLink
        url = node.url
        endswith(url, ".md") && push!(steps, TutorialStep(_link_text(node), url))
        return
    end
    for field in (:elements, :items, :content)
        hasproperty(node, field) || continue
        value = getproperty(node, field)
        value isa AbstractString && continue
        for child in _children_of(value)
            _collect_links!(steps, child, depth + 1)
        end
    end
end

"""
    open_step!(shell, i) -> shell

Show the `i`-th step, loading its page the first time it is asked for. `i == 0`
goes back to the index. Loading goes through the tutorial's session, so a step
reopened later is the same document — its simulation included.
"""
function open_step!(shell::TutorialShell, i::Int)
    if i == 0
        getfield(shell, :page)[] = shell.index
        return shell
    end
    steps = shell.steps
    (1 <= i <= length(steps)) || return shell
    page = doctype_file(_shell_load_ctx(shell), steps[i].path)
    Projectured.resolve_stubs!(page)
    getfield(shell, :page)[] = page
    shell
end

# The shell keeps its session rather than a LoadCtx, so rebuild the small
# context `doctype_file` wants.
_shell_load_ctx(shell::TutorialShell) =
    LoadCtx(shell.base_dir, nothing; loader = shell.loader)

# root.json says which page is the index; everything else is derived.
function _from_json(::Type{TutorialShell}, fields::Dict{Symbol,Any}, ctx::LoadCtx)
    index = get(fields, :index, nothing)
    index === nothing &&
        error("TutorialShell: `index` must name the tutorial's index page, e.g. \"index.md\"")
    page = index isa AbstractString ? doctype_file(ctx, index) : index
    Projectured.resolve_stubs!(page)
    document = Projectured.content(page)
    TutorialShell(page, CellVector(tutorial_steps(document)), page,
                  ctx.base_dir, ctx.loader)
end
