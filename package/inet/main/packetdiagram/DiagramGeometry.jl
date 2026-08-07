# ============================================================================
# The row layout — where every field lands in the grid.
#
# Pure functions over numbers. They import no projection, no font and no
# document, so a layout defect is found by calling one of them in a REPL rather
# than by looking at a rendered figure.
#
# The grid is CONTINUOUS over the whole packet: a header does not start a new
# row. That is the truth about the wire — an Ethernet MAC header is 14 bytes and
# does end in the middle of the fourth row — and it is what makes the headers
# flow through the packet rather than sit in boxes beside it.
#
# Geometry, in characters:
#   a bit          2 characters
#   a row          1 + 2 * row_bits characters
#   a field of b   2b - 1 characters between its two borders
# ============================================================================

"""
    DiagramCell

One field, or one part of a field, in one row of the grid.

A field that crosses a row boundary splits into parts. Every part prints the
name; only the widest part prints the value, and the others print a
continuation mark. When two parts tie, the first one wins.
"""
struct DiagramCell
    band::Int            # index of the band this belongs to
    field::Int           # index of the field within the band, 0 for an opaque band
    column::Int          # bit column where this part starts, 0-based within the row
    width::Int           # bits this part occupies
    part::Int            # 1-based index of this part
    parts::Int           # how many parts the field has in total
    widest::Bool         # true on the part that prints the value
    starts_band::Bool    # true on the first part of a band's first field
end

"""
    DiagramRow

One line of the figure. `:grid` rows carry cells; a `:box` row stands for one
opaque band that was too long to draw bit by bit.
"""
struct DiagramRow
    kind::Symbol              # :grid | :box
    offset::Int               # bit offset where the row starts
    band::Int                 # for :box, the band it stands for; 0 otherwise
    cells::Vector{DiagramCell}
end

"""
    grid_width(row_bits) -> Int

How many characters one row of the grid takes, borders included.
"""
grid_width(row_bits::Int) = 1 + 2 * row_bits

"""
    cell_width(bits) -> Int

How many characters a field of `bits` bits has between its two borders.
"""
cell_width(bits::Int) = 2 * bits - 1

"""
    diagram_rows(bands, row_bits; max_opaque_rows = 2) -> Vector{DiagramRow}

Lay the bands out as a continuous grid `row_bits` bits wide.

An opaque band longer than `max_opaque_rows` rows collapses to a single `:box`
row: a 1500-byte payload is 375 rows of nothing, and drawing them buries the
headers. The grid restarts at the end of a collapsed band, so a row always
begins where the last one ended.
"""
function diagram_rows(bands, row_bits::Int; max_opaque_rows::Int = 2)
    row_bits > 0 || error("diagram_rows: row_bits must be positive, got $row_bits")
    rows = DiagramRow[]
    cells = DiagramCell[]
    column = 0                       # bits already used in the row being built
    offset = Base.length(bands) == 0 ? 0 : bands[1].offset   # where the row starts

    function close_row!()
        if !isempty(cells)
            push!(rows, DiagramRow(:grid, offset, 0, cells))
            offset += column
            cells = DiagramCell[]
            column = 0
        end
    end

    for (b, band) in enumerate(bands)
        if _is_collapsed(band, row_bits, max_opaque_rows)
            close_row!()
            push!(rows, DiagramRow(:box, band.offset, b, DiagramCell[]))
            offset = band.offset + band.width
            continue
        end
        for (f, width) in _band_pieces(band)
            # How the piece splits: one part per row it reaches into.
            widths = Int[]
            remaining = width
            room = row_bits - column
            while remaining > 0
                take = min(room, remaining)
                push!(widths, take)
                remaining -= take
                room = row_bits
            end
            widest = argmax(widths)
            for (part, w) in enumerate(widths)
                push!(cells, DiagramCell(b, f, column, w, part, Base.length(widths),
                                         part == widest, f <= 1 && part == 1))
                column += w
                column == row_bits && close_row!()
            end
        end
    end
    close_row!()
    return rows
end

# A header band's pieces are its fields; an opaque band is one piece.
function _band_pieces(band)
    if band isa DiagramHeaderBand
        return [(f, band.fields[f].width) for f in 1:Base.length(band.fields)]
    else
        return [(0, band.width)]
    end
end

_is_collapsed(band, row_bits::Int, max_opaque_rows::Int) =
    !(band isa DiagramHeaderBand) && band.width > max_opaque_rows * row_bits

"""
    band_start(rows, band) -> (row_index, column) or nothing

Where a band begins: the row it starts in, and the bit column within that row.
The printer puts the band's name above that row, at that column.
"""
function band_start(rows::Vector{DiagramRow}, band::Int)
    for (r, row) in enumerate(rows)
        row.kind === :box && row.band == band && return (r, 0)
        for cell in row.cells
            cell.band == band && cell.starts_band && return (r, cell.column)
        end
    end
    return nothing
end

"""
    row_bit_width(row) -> Int

How many bits a row actually holds. The last row of a packet may be short, and
the separator under it is drawn only as wide as the row.
"""
row_bit_width(row::DiagramRow) =
    isempty(row.cells) ? 0 : (row.cells[end].column + row.cells[end].width)
