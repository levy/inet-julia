# ============================================================================
# The layout descriptor — what `@header` knows, kept instead of thrown away.
#
# The macro computes the name, the bit offset, the bit width and the display
# base of every field while it builds the codec. A view of a packet needs all
# four, and a view that recomputed them from a table of its own would be a
# second description of the layout — the very thing `@header` exists to remove.
# So the macro emits the description beside the codec, as a constant.
#
# `header_layout(H)` is the only reflection a view needs. It costs nothing at
# run time: the vector is built once, when the header is declared.
# ============================================================================

"""
    FieldSpec(name, type, offset, width, base)

One field of a declared header. `offset` and `width` are in bits, and `offset`
counts from the start of the header.
"""
struct FieldSpec
    name::Symbol
    type::Type
    offset::Int
    width::Int
    base::Symbol
end

"""
    HeaderLayout(name, length, fields)

The wire layout of one declared header, in declaration order.
"""
struct HeaderLayout
    name::Symbol
    length::BitLength
    fields::Vector{FieldSpec}
end

"""
    header_layout(::Type{H})::HeaderLayout
    header_layout(h::Fields)::HeaderLayout

The layout of a declared header. `@header` defines the method on the type.
"""
function header_layout end

header_layout(h::Fields) = header_layout(typeof(h))

"""
    build_header_layout(name, names, types, widths, bases) -> HeaderLayout

Assemble a layout from the parts `@header` collected. A `nothing` in `bases`
takes the default of the field's type at that width.
"""
function build_header_layout(name::Symbol, names::Vector{Symbol}, types::Vector{Type},
                             widths::Vector{Int}, bases::Vector{Union{Symbol, Nothing}})
    specs = Vector{FieldSpec}(undef, Base.length(names))
    offset = 0
    for i in eachindex(names)
        base = bases[i] === nothing ? field_base(types[i], widths[i]) : bases[i]
        specs[i] = FieldSpec(names[i], types[i], offset, widths[i], base)
        offset += widths[i]
    end
    return HeaderLayout(name, Bits(offset), specs)
end

# ---------- reading one field ------------------------------------------------

"""
    field_bits(h::Fields, spec::FieldSpec)::UInt64

The raw bits of one field of `h`, as they go on the wire.
"""
field_bits(h::Fields, spec::FieldSpec) =
    field_encode(spec.type, getfield(h, spec.name))

"""
    field_text(h::Fields, spec::FieldSpec)::String
    field_text(bits::UInt64, spec::FieldSpec)::String
    field_text(bits::UInt64, spec::FieldSpec, base::Symbol)::String

One field, formatted for a reader. The third form forces a base, which is how a
view falls back to a shorter form when the space it has is too narrow.
"""
field_text(h::Fields, spec::FieldSpec) = field_text(field_bits(h, spec), spec)
field_text(bits::UInt64, spec::FieldSpec) = field_text(bits, spec, spec.base)

function field_text(bits::UInt64, spec::FieldSpec, base::Symbol)
    if base === :bin
        return string(bits, base = 2, pad = spec.width)
    elseif base === :dec
        return string(bits)
    elseif base === :hex
        return "0x" * string(bits, base = 16, pad = cld(spec.width, 4))
    else
        # :mac, :ipv4, :enum — the value type prints itself, which keeps one
        # formatter for the REPL, the tests and the diagram.
        return string(field_decode(spec.type, bits))
    end
end
