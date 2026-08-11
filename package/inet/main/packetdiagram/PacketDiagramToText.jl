# ============================================================================
# PacketDiagram → TextBlock — the figure itself.
#
# A flat sequence of styled spans with a newline between rows. Four rules bind
# this printer, and breaking any one of them breaks the figure rather than
# merely making it uglier:
#
# 1. Build the spans inside the `TextBlock(() -> …)` thunk. Every cell the
#    printer reads must be read inside a cell, or the figure freezes at its
#    first render.
# 2. Emit `TextString` spans with `TextNewline` between rows. Do not emit
#    `TextLine`: `TextToGraphics` does not lay it out yet, and a
#    line-structured block renders blank there.
# 3. Use ONE font for everything inside the grid. Colour may vary, because
#    colour does not change the advance width of a glyph; a bold face can, and
#    a grid whose columns do not line up is not a grid.
# 4. Draw with ASCII only — `+ - | # ~`. The SDL backend does not fall back to
#    another face, so a Unicode box-drawing glyph the font lacks renders as an
#    empty box.
#
# The mappers return `nothing`, so the figure is display-only. The span table
# that makes a cell selectable is the next phase.
# ============================================================================

"""
    PacketDiagramToText(; show_offsets = true, show_values = true, …)

The figure, as monospaced text. `show_offsets` draws the byte-offset gutter,
`show_values` draws the value row under each name row, and `max_opaque_rows`
is how many rows of a filler or a raw run are drawn before it collapses to one
box.
"""
@projection struct PacketDiagramToText <: Projection
    show_offsets::ImmutableCell{Bool} = true
    show_values::ImmutableCell{Bool} = true
    show_legend::ImmutableCell{Bool} = true
    max_opaque_rows::ImmutableCell{Int} = 2
    font::ImmutableCell{DCStyleFont} = font_ubuntu_monospace_regular_20
    chrome_color::ImmutableCell{DCStyleColor} = color_solarized_gray
    title_color::ImmutableCell{DCStyleColor} = color_solarized_green
    name_color::ImmutableCell{DCStyleColor} = color_solarized_blue
    value_color::ImmutableCell{DCStyleColor} = color_solarized_magenta
end

function print_document(p::PacketDiagramToText, recursion, diagram::PacketDiagram, ctx)
    out = TextBlock(() -> _diagram_spans(p, diagram))
    SimpleIoMap(p, diagram, out)
end

map_reference_forward(::PacketDiagramToText, ::SimpleIoMap, _) = nothing
map_reference_backward(::PacketDiagramToText, ::SimpleIoMap, _) = nothing

# ---------- the whole figure -------------------------------------------------

const GUTTER_WIDTH = 8

function _diagram_spans(p::PacketDiagramToText, diagram::PacketDiagram)
    spans = TextDocument[]
    bands = diagram.bands
    row_bits = diagram.row_bits
    rows = diagram_rows(bands, row_bits; max_opaque_rows = p.max_opaque_rows)
    gutter = p.show_offsets ? GUTTER_WIDTH : 0
    legend = Tuple{String, String}[]

    isempty(diagram.label) || _line!(spans, p, [(diagram.label, p.title_color)], gutter)
    _line!(spans, p, [(_ruler_tens(row_bits), p.chrome_color)], gutter)
    _line!(spans, p, [(_ruler_units(row_bits), p.chrome_color)], gutter)

    for (index, row) in enumerate(rows)
        previous = index > 1 ? rows[index - 1] : nothing
        following = index < Base.length(rows) ? rows[index + 1] : nothing
        if row.kind === :box
            _box_rows!(spans, p, bands[row.band], row, gutter, row_bits)
        else
            _title_line!(spans, p, bands, row, gutter)
            (previous === nothing || previous.kind === :box) &&
                _rule!(spans, p, row_bit_width(row), gutter)
            _cell_line!(spans, p, bands, row, gutter, :name, legend)
            p.show_values && _cell_line!(spans, p, bands, row, gutter, :value, legend)
            width = following !== nothing && following.kind === :grid ?
                    max(row_bit_width(row), row_bit_width(following)) : row_bit_width(row)
            _rule!(spans, p, width, gutter)
        end
    end

    p.show_legend && !isempty(legend) && _legend!(spans, p, legend, gutter)
    return spans
end

# ---------- one line ---------------------------------------------------------

# Every line starts with the gutter and ends with a newline, so a line is built
# by handing this the styled pieces between them.
function _line!(spans::Vector{TextDocument}, p::PacketDiagramToText,
                pieces::Vector{<:Tuple{AbstractString, Any}}, gutter::Int,
                gutter_text::AbstractString = "")
    if gutter > 0
        push!(spans, TextString(rpad(gutter_text, gutter), p.font, p.chrome_color))
    end
    for (text, color) in pieces
        isempty(text) || push!(spans, TextString(String(text), p.font, color))
    end
    push!(spans, TextNewline(font = p.font))
    return spans
end

_rule!(spans, p, bits::Int, gutter::Int) =
    _line!(spans, p, [("+" * repeat("-+", max(bits, 0)), p.chrome_color)], gutter)

# ---------- the bit ruler ----------------------------------------------------
#
# Two lines: the tens digit of every tenth bit, then the units digit of every
# bit, each above the column it names.

function _ruler_tens(row_bits::Int)
    line = fill(' ', 2 * row_bits)
    for bit in 0:(row_bits - 1)
        bit % 10 == 0 || continue
        for (i, c) in enumerate(string(bit ÷ 10))
            line[2 * bit + 2 + (i - 1)] = c
        end
    end
    return rstrip(String(line))
end

function _ruler_units(row_bits::Int)
    line = fill(' ', 2 * row_bits)
    for bit in 0:(row_bits - 1)
        line[2 * bit + 2] = string(bit % 10)[1]
    end
    return rstrip(String(line))
end

# ---------- a band's title ---------------------------------------------------
#
# The name floats above the row the band starts in, at the character column of
# its first bit — so a header that begins in the middle of a row says so.

function _title_line!(spans, p::PacketDiagramToText, bands, row, gutter::Int)
    starters = [cell for cell in row.cells if cell.starts_band]
    isempty(starters) && return
    line = fill(' ', grid_width(_row_bits_of(row)))
    for cell in starters
        label = _band_title(bands[cell.band])
        column = 1 + 2 * cell.column + 1
        column + Base.length(label) - 1 > Base.length(line) &&
            (column = Base.length(line) - Base.length(label) + 1)
        column = max(column, 1)
        for (i, c) in enumerate(label)
            index = column + i - 1
            index <= Base.length(line) && (line[index] = c)
        end
    end
    _line!(spans, p, [(rstrip(String(line)), p.title_color)], gutter)
end

_row_bits_of(row) = row_bit_width(row)

_band_title(band) = band.name * "  " * _length_text(band.width)

_length_text(bits::Int) = bits % 8 == 0 ? string(bits ÷ 8) * " B" : string(bits) * " b"

# ---------- a grid line ------------------------------------------------------

function _cell_line!(spans, p::PacketDiagramToText, bands, row, gutter::Int,
                     which::Symbol, legend)
    gutter_text = which === :name ? _offset_text(row.offset) : ""
    pieces = Tuple{String, Any}[]
    for (index, cell) in enumerate(row.cells)
        border = (cell.starts_band && index > 1) ? "#" : "|"
        push!(pieces, (border, p.chrome_color))
        width = cell_width(cell.width)
        if which === :name
            push!(pieces, (_centre(_cell_name(bands, cell), width), p.name_color))
        else
            push!(pieces, (_centre(_cell_value(bands, cell, width, legend), width),
                           p.value_color))
        end
    end
    push!(pieces, ("|", p.chrome_color))
    _line!(spans, p, pieces, gutter, gutter_text)
end

function _cell_name(bands, cell::DiagramCell)
    band = bands[cell.band]
    cell.field == 0 ? band.name : band.fields[cell.field].name
end

# Only the widest part of a split field prints the value; the rest print the
# continuation mark, so a reader knows the field goes on rather than repeats.
function _cell_value(bands, cell::DiagramCell, width::Int, legend)
    cell.widest || return "~"
    band = bands[cell.band]
    if cell.field == 0
        return band.preview
    end
    field = band.fields[cell.field]
    for text in _value_forms(field)
        Base.length(text) <= width && return text
    end
    # Nothing fits. Cut the shortest form and say so, and put the whole value in
    # the legend under the figure — a value that cannot be read is worse than a
    # figure one line longer.
    push!(legend, (band.name * "." * field.name, field.text))
    shortest = argmin(Base.length, _value_forms(field))
    return width >= 2 ? shortest[1:min(width - 1, Base.length(shortest))] * "*" : "*"
end

# In the order a reader loses the least: what the field means, then the same
# number in hexadecimal, then in decimal.
_value_forms(field) =
    unique(String[field.text,
                  "0x" * string(field.value, base = 16, pad = cld(field.width, 4)),
                  string(field.value)])

function _centre(text::AbstractString, width::Int)
    Base.length(text) >= width && return String(text)[1:min(width, Base.length(text))]
    left = (width - Base.length(text)) ÷ 2
    return " "^left * text * " "^(width - Base.length(text) - left)
end

# ---------- a collapsed band -------------------------------------------------

function _box_rows!(spans, p::PacketDiagramToText, band, row, gutter::Int, row_bits::Int)
    inner = grid_width(row_bits) - 2
    label = _band_title(band)
    isempty(band.preview) || (label *= "  " * band.preview)
    isempty(band.quality) || (label *= "  " * band.quality)
    _line!(spans, p, [("+" * repeat("-", inner) * "+", p.chrome_color)], gutter)
    _line!(spans, p, [("|", p.chrome_color), (_centre(label, inner), p.name_color),
                      ("|", p.chrome_color)], gutter, _offset_text(row.offset))
    _line!(spans, p, [("+" * repeat("-", inner) * "+", p.chrome_color)], gutter)
end

# ---------- the gutter and the legend ----------------------------------------

# The byte offset of the row, which is what a reader compares against a hex
# dump. A row that does not start on a byte boundary shows its bit offset.
_offset_text(bits::Int) = bits % 8 == 0 ?
    " 0x" * string(bits >> 3, base = 16, pad = 4) :
    " b" * lpad(string(bits), 5)

function _legend!(spans, p::PacketDiagramToText, legend, gutter::Int)
    _line!(spans, p, [("", p.chrome_color)], gutter)
    for (name, text) in legend
        _line!(spans, p, [("  " * name * " = ", p.name_color), (text, p.value_color)], gutter)
    end
end

# ---------- the chain, and the two entry points ------------------------------

"""
    packet_projection(; measure = truetype_measure_text) -> Projection

The whole chain, from a packet to pixels.
"""
packet_projection(; measure = truetype_measure_text,
                    diagram = PacketToPacketDiagram(),
                    text = PacketDiagramToText()) =
    ChainingProjection(diagram, text, TextToGraphics(measure = measure))

"""
    packet_diagram_entry(; measure = truetype_measure_text) -> Pair{Type, Any}

The dispatch entry that draws a packet as the figure, keyed on `Packet` itself —
a packet the renderer meets in a document field, in a collection, or as the root
draws with no conversion at the place that holds it.
"""
packet_diagram_entry(; kwargs...) = Packet => packet_projection(; kwargs...)

"""
    packet_diagram_document_entry(; measure = truetype_measure_text) -> Pair{Type, Any}

The same figure for a `PacketDiagram` that already exists — the tail of the
chain, without its first stage.

An **embed needs this one**. A marker's value arrives inside a `WidgetCard`, and
a card renders its content only when the content is a `Document`
(`w.content isa Document` in `WidgetToGraphics.jl`). A `Packet` is not one and
never can be, so a page splices `packet_diagram(pk)` and this entry draws it.
"""
packet_diagram_document_entry(; measure = truetype_measure_text) =
    PacketDiagram => ChainingProjection(PacketDiagramToText(),
                                        TextToGraphics(measure = measure))

"""
    packet_diagram_entries(; measure = truetype_measure_text) -> Vector{Pair{Type, Any}}

Both entries, which is what a renderer wants: a packet draws wherever the table
sees one, and a spliced diagram draws inside a card.
"""
packet_diagram_entries(; measure = truetype_measure_text) =
    Pair{Type, Any}[packet_diagram_entry(measure = measure),
                    packet_diagram_document_entry(measure = measure)]

"""
    packet_diagram_string(packet; row_bits = 32, kwargs...) -> String

The figure as a plain string. It needs no window, which is what makes it the
form a test pins and the form a REPL prints.
"""
function packet_diagram_string(packet; row_bits::Int = 32, kwargs...)
    chain = ChainingProjection(PacketToPacketDiagram(row_bits = row_bits),
                               PacketDiagramToText(; kwargs...),
                               RecursiveProjection(TextToString()))
    iomap = print_document(chain, chain, packet, PrinterContext())
    # Every line ends with a newline, the last one included; that trailing break
    # is a fact about the span sequence, not about the figure.
    text = rstrip(iomap.output, '\n')
    return join((rstrip(line) for line in split(text, '\n')), '\n')
end
