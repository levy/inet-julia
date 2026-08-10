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
    FieldSpec(name, type, offset, width, base, constant = nothing)

One field of a declared header. `offset` and `width` are in bits, and `offset`
counts from the start of the header.

`constant` holds the value of a wire-only field — one the header writes and no
struct field carries. It is `nothing` for every other field. A reader of the
layout needs it: without it, `field_bits` would look for a struct field that
does not exist.
"""
struct FieldSpec
    name::Symbol
    type::Type
    offset::Int
    width::Int
    base::Symbol
    constant::Any
end

FieldSpec(name::Symbol, type::Type, offset::Int, width::Int, base::Symbol) =
    FieldSpec(name, type, offset, width, base, nothing)

"""
    is_constant(spec::FieldSpec)::Bool

Whether the field is wire-only: it takes width, and no struct field holds it.
"""
is_constant(spec::FieldSpec) = spec.constant !== nothing

"""
    has_bits(spec::FieldSpec)::Bool

Whether one `UInt64` holds the field, which is what `field_bits` needs. An
`Ipv6Address` field is 128 bits, so the answer is `false` and only
`field_text` describes it.
"""
has_bits(spec::FieldSpec) = spec.width <= 64 && field_has_bits(spec.type)

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
    minimum_chunk_length(::Type{H})::BitLength

The width of the fixed part of a header — the whole of it when the header is
fixed-length. This is always known, which is what a reader needs before any
bytes arrive.
"""
function minimum_chunk_length end

minimum_chunk_length(::Type{H}) where {H <: Fields} = chunk_length(H)

"""
    is_fixed_length(::Type{H})::Bool

Whether every instance of `H` is the same width. `false` when the header ends
in a byte tail or in padding, so its length is a property of the value and not
of the type.
"""
function is_fixed_length end

is_fixed_length(::Type{H}) where {H <: Fields} = true

"""
    build_header_layout(name, names, types, widths, bases, constants) -> HeaderLayout

Assemble a layout from the parts `@header` collected. A `nothing` in `bases`
takes the default of the field's type at that width, and a `nothing` in
`constants` says the field is in the struct.
"""
function build_header_layout(name::Symbol, names::Vector{Symbol}, types::Vector{Type},
                             widths::Vector{Int}, bases::Vector{Union{Symbol, Nothing}},
                             constants::Vector{Any} = Any[nothing for _ in names])
    specs = Vector{FieldSpec}(undef, Base.length(names))
    offset = 0
    for i in eachindex(names)
        base = bases[i] === nothing ? field_base(types[i], widths[i]) : bases[i]
        specs[i] = FieldSpec(names[i], types[i], offset, widths[i], base, constants[i])
        offset += widths[i]
    end
    return HeaderLayout(name, Bits(offset), specs)
end

# ---------- reading one field ------------------------------------------------

"""
    field_bits(h::Fields, spec::FieldSpec)::UInt64

The raw bits of one field of `h`, as they go on the wire. A field wider than 64
bits has no `UInt64` to be; ask `field_text` for that one instead.
"""
function field_bits(h::Fields, spec::FieldSpec)
    has_bits(spec) ||
        error("field_bits: `$(spec.name)` is $(spec.width) bits wide and no UInt64 holds it; " *
              "use field_text")
    return field_encode(spec.type, field_value(h, spec))
end

"""
    field_value(h::Fields, spec::FieldSpec)

The value of one field of `h`. A wire-only field takes its constant, because
the struct has no field to read.
"""
field_value(h::Fields, spec::FieldSpec) =
    is_constant(spec) ? spec.constant : getfield(h, spec.name)

"""
    field_text(h::Fields, spec::FieldSpec)::String
    field_text(bits::UInt64, spec::FieldSpec)::String
    field_text(bits::UInt64, spec::FieldSpec, base::Symbol)::String

One field, formatted for a reader. The third form forces a base, which is how a
view falls back to a shorter form when the space it has is too narrow.

A field wider than 64 bits takes the first form alone: the value prints itself,
because there is no `UInt64` for the other two forms to take.
"""
field_text(h::Fields, spec::FieldSpec) =
    has_bits(spec) ? field_text(field_bits(h, spec), spec) :
                     field_text_wide(field_value(h, spec))

"One value that no `UInt64` describes, as text. A run of bytes reads as hex."
field_text_wide(value) = string(value)
field_text_wide(value::AbstractVector{UInt8}) =
    join((string(byte, base = 16, pad = 2) for byte in value), " ")
field_text(bits::UInt64, spec::FieldSpec) = field_text(bits, spec, spec.base)

function field_text(bits::UInt64, spec::FieldSpec, base::Symbol)
    if base === :bin
        return string(bits, base = 2, pad = spec.width)
    elseif base === :dec
        return string(bits)
    elseif base === :hex
        return "0x" * string(bits, base = 16, pad = cld(spec.width, 4))
    else
        # :mac, :ipv4, :ipv6, :enum — the value type prints itself, which keeps
        # one formatter for the REPL, the tests and the diagram.
        return string(field_decode(spec.type, bits))
    end
end
