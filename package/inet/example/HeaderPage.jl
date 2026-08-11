# ────────────────────────────────────────────────────────────────────────────
# A protocol header, as a page.
#
# `<<header_view("Ipv4Header")>>` puts five views of one wire format on a page:
#
#   1. the declaration, read out of the file that declares it
#   2. the call that builds an instance
#   3. one field read and written, and the byte that moved
#   4. the instance in the editor's reflection tree
#   5. the instance as the RFC bit grid
#
# Not one of the five is written here. The declaration is quoted from its own
# file through the same marker a page uses for any source fragment; the other
# four are computed from the type by `HeaderFacts.jl`, `DocumentReflection` and
# `packet_diagram`. A page that cannot disagree with the code is the whole
# point — a header is declared once, and this is what that buys.
#
# The page carries no title. The stub page in `demo/pages/header/` states what
# the protocol is, in the reader's language, and the marker fills in the rest.
# ────────────────────────────────────────────────────────────────────────────

using Projectured.MarkdownModule: MarkdownRoot, MarkdownHeading, MarkdownParagraph,
    MarkdownText, MarkdownCodeBlock
using Projectured.DocumentReflectionModule: reflect_document
using Projectured.FileProjectModule: LoaderContext
using Inet.PacketDiagramModule: packet_diagram
using Inet.PacketModule
import OmnetppPresentation: is_loadable_doctype

# A wire format is data. It has no behaviour, no identity and nothing running
# inside it — a page that names one is naming a value, the same way a page
# naming a `SimulationEmbed` names a value. So the loader may build one, from a
# `$doctype` object or from the constructor call an embedded fragment carries.
#
# The method sits here rather than in `Inet` because it needs the loader and the
# header at once, and `Inet` reaches the simulator but not the presentation
# stack. `register_doctype_module!(Inet)` is in this package for the same
# reason.
is_loadable_doctype(::Type{<:Fields}) = true

"""
    GALLERY_HEADERS :: Vector{Pair{Type, String}}

The headers a page may name, and what each one alone shows.

Ninety-one wire formats are declared. Ten are here, because a gallery is read
and an inventory is searched: each of these carries a feature none of the others
does, so ten pages cover the whole declaration language. The reason travels with
the header and is printed on its page — the answer to "why this one" belongs
where the question is asked.

To add a header, add a row and a stub page under `demo/pages/header/`.
"""
const GALLERY_HEADERS = Pair{Type, String}[
    EthernetMacHeader =>
        "a plain struct with no macro at all — the codec needs no declaration " *
        "language, only the fields",
    Ieee8022LlcHeader =>
        "an optional field, present or absent by a clause over the field above it",
    ArpPacket =>
        "constant fields that hold nothing and still take width, and two address " *
        "families in one header",
    Ipv4Header =>
        "sub-byte widths, a check, a derive, and an option list that runs to the " *
        "end of the header",
    UdpHeader =>
        "the smallest header there is: two fields a caller states and two the " *
        "declaration decides",
    TcpHeader =>
        "a length derived from the header's own width, over an option family of " *
        "its own",
    Ipv6Header =>
        "a 128-bit field, and a 20-bit flow label beside it",
    Ipv6FragmentHeader =>
        "an extension header: eight octets, and most of them reserved",
    IcmpEchoRequest =>
        "a variant, declared over an embedded base header rather than by " *
        "inheritance",
    Igmpv3Report =>
        "a repeated list that fills its window, and a count that derives from it",
]

"""
    gallery_headers() -> Vector{Type}

Every header a page may name, in the order the gallery lists them.
"""
gallery_headers() = Type[first(pair) for pair in GALLERY_HEADERS]

"""
    find_gallery_header(name) -> Type

The header a page names. Errors with the list when there is no such header,
because a marker that resolves to nothing is a page with a hole in it.
"""
function find_gallery_header(name::AbstractString)
    for (type, _) in GALLERY_HEADERS
        string(document_schema_name(type)) == name && return type
    end
    error("header_view(", repr(String(name)), "): no such header in the gallery; ",
          "available: ", join((string(document_schema_name(t)) for t in gallery_headers()), ", "))
end

"The one line that says why this header is in the gallery."
function header_reason(::Type{H}) where {H <: Fields}
    for (type, reason) in GALLERY_HEADERS
        type === H && return reason
    end
    return ""
end

# The load session the declarations are read in. One for the whole gallery, so
# two headers declared in one file share one parse of it — the intern table is
# keyed by the marker's own source, which is what makes that automatic.
#
# Built on first use rather than at load time: it holds a directory, and a
# directory baked into a precompiled image is the build machine's.
const _GALLERY_CONTEXT = Ref{Any}(nothing)

"""
    gallery_loader_context() -> LoaderContext

The session every header declaration is read in, rooted at the packet package's
own source directory. A marker path is therefore `Ipv4.jl` or
`protocol/Ipv4.jl`, which is what the file is called.
"""
function gallery_loader_context()
    _GALLERY_CONTEXT[] === nothing &&
        (_GALLERY_CONTEXT[] = LoaderContext(package_source_directory()))
    return _GALLERY_CONTEXT[]
end

"""
    header_declaration(::Type{H})

The declaration of `H`, as the parsed Julia it is.

It goes through `definition(file(…), name)` — the marker any page uses to embed
one definition of a source file. Addressing it by the name it already carries is
what makes the embed survive editing the file around it, and it is why a
renamed header fails here loudly rather than showing the wrong declaration.
"""
function header_declaration(::Type{H}) where {H <: Fields}
    path = declaration_path(H)
    path === nothing &&
        error("header_declaration: ", document_schema_name(H), " never recorded where it was declared")
    relative = relpath(path, package_source_directory())
    Projectured.evaluate_marker(
        string("definition(file(", repr(relative), "), ", repr(string(document_schema_name(H))), ")"),
        gallery_loader_context())
end

"""
    header_page(::Type{H}) -> MarkdownRoot

The five views of one header, as a page a reader scrolls.

The reflection tree and the bit grid are live documents sitting in the page as
blocks. A page's elements each re-enter the renderer in their own domain, so a
document that draws itself needs no card and no marker of its own here — the
demo projection already knows both types.

A header asked for twice gives back the page it was given the first time, which
is what makes a fold a reader opened still open when they come back.
"""
header_page(::Type{H}) where {H <: Fields} =
    get!(() -> _build_header_page(H), HEADER_PAGES, H)

"""
    HEADER_PAGES :: IdDict{Type, Any}

The page each header has been given, so that a header opened twice is one
document — with the folds a reader left where they were, and with the catalog
paying for the page once however many times it is rebuilt. `_SIMULATION_WINDOWS`
keeps a runtime window for the same reason.

`empty!(HEADER_PAGES)` drops them, which is what a session editing the page
builder wants.
"""
const HEADER_PAGES = IdDict{Type, Any}()

function _build_header_page(::Type{H}) where {H <: Fields}
    header = example_header(H)
    construction = describe_construction(header)
    blocks = Any[]

    reason = header_reason(H)
    isempty(reason) || push!(blocks, _paragraph(string("In the gallery for ", reason, ".")))

    push!(blocks, _heading("How it is declared"))
    # The docstring comes with it: `definition` yields a documented definition
    # WITH its documentation, so the format is described once, where it was
    # written, rather than quoted again here.
    push!(blocks, header_declaration(H))
    push!(blocks, _paragraph(_declaration_note(H)))

    push!(blocks, _heading("How one is built"))
    push!(blocks, MarkdownCodeBlock("julia", construction.call))
    push!(blocks, _paragraph(_construction_note(construction)))

    update = find_updatable_field(H) === nothing ? nothing : describe_update(header)
    if update !== nothing
        push!(blocks, _heading("How a field is read and written"))
        push!(blocks, MarkdownCodeBlock("julia", _update_code(update)))
        push!(blocks, MarkdownCodeBlock("", _update_bytes(update)))
        push!(blocks, _paragraph(_update_note(update)))
    end

    push!(blocks, _heading("The instance, by reflection"))
    push!(blocks, reflect_document(header; label = string(document_schema_name(H))))

    push!(blocks, _heading("The instance, as the standard draws it"))
    # The figure as the live document it is: the field names, the values and the
    # grid each in their own colour, and a band a reader can fold. A page's
    # elements re-enter the renderer by their own type, and the demo projection
    # already knows this one.
    push!(blocks, packet_diagram(Packet(header)))

    return MarkdownRoot(blocks)
end

# `<<header_view("Ipv4Header")>>`.
marker_header_view(_ctx, name::AbstractString) = header_page(find_gallery_header(name))

# ---------- the prose the page needs -----------------------------------------

# A plain vector, never a `CellVector`. The field wraps what it is given, so
# handing it a collection wraps that collection in a second one — and a
# collection inside a paragraph draws as the list it is, brackets and all.
_heading(text::AbstractString) = MarkdownHeading(2, Any[MarkdownText(String(text))])

_paragraph(text::AbstractString) = MarkdownParagraph(Any[MarkdownText(String(text))])

function _declaration_note(::Type{H}) where {H <: Fields}
    site = find_declaration(H)
    where_it_is = site === nothing ? "the packet library" :
                  string(basename(site.file), ", line ", site.line)
    return string("That is the whole format: ", where_it_is,
                  " is the only place it is written down. The struct is the layout, ",
                  "`fieldtypes` is the width of every field, and the codec reads both.")
end

function _construction_note(construction)
    named = list_named(construction)
    omitted = list_omitted(construction)
    construction.keyword ||
        return string("Every field is stated, in order: ", document_schema_name(construction.type),
                      " is a plain struct, so the only constructor it has is the ",
                      "positional one Julia gives every struct — and a positional ",
                      "call has no default to leave anything to.")
    isempty(omitted) &&
        return string("Every field is named: ", document_schema_name(construction.type),
                      " gives none of them a default.")
    parts = String[]
    for reason in (:default, :derived, :fixed)
        fields = [string("`", a.name, "`") for a in omitted if a.reason === reason]
        isempty(fields) && continue
        push!(parts, string(join(fields, ", "), " ", _reason_phrase(reason)))
    end
    return string("The call names ", Base.length(named),
                  Base.length(named) == 1 ? " field, and leaves out " : " fields, and leaves out ",
                  join(parts, "; "), ".")
end

_reason_phrase(reason::Symbol) =
    reason === :default ? "carry the value the declaration gives them" :
    reason === :derived ? "the writer computes from the header itself" :
    "the type describes completely, so nobody names one"

function _update_code(update)
    read_before = string("get_field(header, :", update.field, ")")
    read_after = string("get_field(changed, :", update.field, ")")
    column = max(Base.length(read_before), Base.length(read_after)) + 2
    return string(
        "header = example_header(", document_schema_name(update.type), ")\n",
        rpad(read_before, column), "# ", update.before, "\n",
        "changed = set_field(header, :", update.field, ", ", update.literal, ")\n",
        rpad(read_after, column), "# ", update.after)
end

# The two byte strings, and a marker under the byte that moved. A diff nobody
# has to hunt for is the whole reason to print the bytes twice.
function _update_bytes(update)
    before = _hex_line(update.before_bytes)
    after = _hex_line(update.after_bytes)
    marker = fill(' ', Base.length(after))
    for index in update.changed
        at = (index - 1) * 3 + 1
        at + 1 <= Base.length(marker) && (marker[at] = '^'; marker[at + 1] = '^')
    end
    return string(before, "\n", after, "\n", String(marker))
end

_hex_line(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

function _update_note(update)
    count = Base.length(update.changed)
    where_it_is = count == 1 ? string("byte ", only(update.changed)) :
                  string("bytes ", join(update.changed, ", "))
    return string("`", update.field, "` reads ", update.before, " and is written ",
                  update.after, ". Exactly ", where_it_is, " of ",
                  Base.length(update.before_bytes), " moves; nothing else in the header ",
                  "does, because a field's width and offset come from its type.")
end
