# ────────────────────────────────────────────────────────────────────────────
# TutorialShellToWidget — the shell as two panes: the step list, and the page.
#
# The navigator is a `WidgetList` whose rows are the index's links; picking one
# opens that step. The content pane holds the page DOCUMENT rather than a
# projection of it, so the surrounding renderer routes it by type — which is
# what keeps a page's own embeds live (a simulation card arrives as a widget and
# its buttons work) without this projection knowing anything about them.
# ────────────────────────────────────────────────────────────────────────────

"""
    TutorialShellToWidget(; width, height)

Project a [`TutorialShell`](@ref) to a navigator beside the open page.
"""
struct TutorialShellToWidget <: Projection
    navigator_width::Int
    content_width::Int
    height::Int
end

TutorialShellToWidget(; navigator_width::Int = 260, content_width::Int = 1040,
                      height::Int = 720) =
    TutorialShellToWidget(navigator_width, content_width, height)

"""
    TutorialShellIoMap(projection, input, output, navigator)

`navigator` is the step list, kept so the reader can tell a click on a row from
a click anywhere else.
"""
@iomap struct TutorialShellIoMap
    projection::Any
    input::Any
    output::Any
    navigator::Any
end

# Row 1 is the index itself, so a reader can always get back to it.
_shell_rows(shell) = vcat(["Contents"], [s.title for s in shell.steps])

# Which row is highlighted: the index, or the step whose page is showing.
function _shell_selected(shell)
    page = shell.page
    page === shell.index && return 1
    for (i, step) in enumerate(shell.steps)
        Projectured.filename(page) == step.path && return i + 1
    end
    1
end

function print_document(p::TutorialShellToWidget, recursion, shell::TutorialShell, ctx)
    navigator = WidgetList(Point2D(0, 0), _shell_rows(shell);
                           selected = _shell_selected(shell),
                           width = p.navigator_width)
    set_cell_function!(getfield(navigator, :items),
                       () -> CellVector(_shell_rows(shell)))
    set_cell_function!(getfield(navigator, :selection),
                       () -> widget_list_selection(_shell_selected(shell)))

    # The page is handed over as a document: the renderer picks the projection
    # by its type, which is how a markdown page keeps its embeds live.
    # A pane's size is explicit — a viewport with no width clips its content
    # away entirely rather than filling what is left.
    content = WidgetScrollPane(nothing; size = Point2D(p.content_width, p.height))
    set_cell_function!(getfield(content, :content),
                       () -> (page = shell.page;
                              page === nothing ? nothing : Projectured.content(page)))

    columns = HorizontalLayout(Any[WidgetScrollPane(navigator;
                                                    size = Point2D(p.navigator_width, p.height)),
                                   content];
                               gap = 12)
    TutorialShellIoMap(p, shell, columns, navigator)
end

# The page's own interior is addressed through the content pane; the navigator
# has no document counterpart (its rows are titles, not documents).
function map_reference_forward(::TutorialShellToWidget, iomap::TutorialShellIoMap, reference)
    reference isa Reference || return nothing
    steps = get_reference_steps(strip_reference_types(reference))
    isempty(steps) && return nothing
    (steps[1] isa FieldReferenceStep && steps[1].name == "page") || return nothing
    foldr((step, tail) -> ConcreteReference(step, tail),
          vcat(Any[FieldReferenceStep("children"), RangeReferenceStep(1, 2),
                   FieldReferenceStep("content")], steps[2:end]);
          init = EmptyReference())
end

function map_reference_backward(::TutorialShellToWidget, iomap::TutorialShellIoMap, reference)
    reference isa Reference || return nothing
    steps = get_reference_steps(strip_reference_types(reference))
    length(steps) >= 3 || return nothing
    (steps[1] isa FieldReferenceStep && steps[1].name == "children") || return nothing
    (steps[2] isa RangeReferenceStep && steps[2].start + 1 == 2) || return nothing
    (steps[3] isa FieldReferenceStep && steps[3].name == "content") || return nothing
    foldr((step, tail) -> ConcreteReference(step, tail),
          vcat(Any[FieldReferenceStep("page")], steps[4:end]); init = EmptyReference())
end

# Picking a navigator row opens that step. The reader RETURNS the action rather
# than performing it, and the row band is derived from which page is open, so a
# widget-local selection write would only be clobbered.
function read_intent(p::TutorialShellToWidget, iomap::TutorialShellIoMap,
                     op::ReplaceSelectionOperation)
    shell = iomap.input
    row = _shell_clicked_row(op.path)
    if row !== nothing
        return InvokeActionOperation(Action("open step";
            callback = _editor -> open_step!(shell, row - 1)))
    end
    r = map_reference_backward(p, iomap, op.path)
    r === nothing ? nothing : ReplaceSelectionOperation(r)
end

# `children[1]…items[k]` — a click in the navigator pane's list.
function _shell_clicked_row(reference)
    reference isa Reference || return nothing
    steps = get_reference_steps(strip_reference_types(reference))
    length(steps) >= 2 || return nothing
    (steps[1] isa FieldReferenceStep && steps[1].name == "children") || return nothing
    (steps[2] isa RangeReferenceStep && steps[2].start + 1 == 1) || return nothing
    for (i, step) in enumerate(steps)
        step isa FieldReferenceStep && step.name == "items" || continue
        next = i + 1
        next <= length(steps) && steps[next] isa RangeReferenceStep || return nothing
        return steps[next].start + 1
    end
    nothing
end
