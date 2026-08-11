# ============================================================================
# The codec — one implementation, over every header there is.
#
# A wire format is a Julia struct whose field types carry meaning and width:
#
#     struct EthernetMacHeader <: Fields
#         destination    :: MacAddress
#         source         :: MacAddress
#         type_or_length :: EtherTypeOrLength
#     end
#
# `fieldnames` and `fieldtypes` ARE the layout, so everything below is written
# once and works on that struct at once: `serialize`, `deserialize`,
# `chunk_length`, `describe_layout`, equality and `show`. Nothing is generated
# per header, and there is no second description of the layout to keep in step
# with the first — the description and the codec read the same tuple.
#
# The recursion is over a field INDEX wrapped in `Val`, so Julia unrolls it at
# compile time and the result costs what straight-line code costs. It is also
# ordinary Julia that a debugger can step through, which generated code is not.
#
# `@header` in `Header.jl` adds what a type cannot hold — the defaults, and the
# expressions over sibling fields. It emits the same struct, so a header
# written by hand and one written through the macro are the same type with the
# same methods.
# ============================================================================

# ---------- what a header states about itself --------------------------------

"""
    byte_order(::Type{H})::Symbol

The byte order of every multi-byte field of `H`. Network order is the default,
and only a protocol that is little-endian throughout — IEEE 802.11 — states
otherwise, once, on the header rather than on each field.
"""
byte_order(::Type{<:Fields}) = :be
byte_order(h::Fields) = byte_order(typeof(h))

"""
    default_field(::Type{T})

The value a model-only field takes when a header is read, since no bits carried
it. `@header` supplies the declared default instead.
"""
default_field(::Type{T}) where {T} = zero(T)
default_field(::Type{T}) where {T <: Base.Enum} = first(instances(T))

# ---------- the layout descriptor --------------------------------------------

"""
    FieldSpec(name, type, offset, width)

One field of a header, as it lies on the wire. `offset` and `width` are in
bits, and `offset` counts from the start of the header.

Everything else a view wants is a question for the type: `is_constant`,
`has_bits` and `classify_display` all read `spec.type`.
"""
struct FieldSpec
    name::Symbol
    type::Type
    offset::Int
    width::Int
end

"""
    HeaderLayout(name, length, fields)

The wire layout of one header, in declaration order.
"""
struct HeaderLayout
    name::Symbol
    length::BitLength
    fields::Vector{FieldSpec}
end

"Whether the field is wire-only: it takes width, and holds nothing."
is_constant(spec::FieldSpec) = spec.type <: Constant

"Whether one `UInt64` holds the field, which is what `encode_field` needs."
has_bits(spec::FieldSpec) = has_field_bits(spec.type)

classify_display(spec::FieldSpec) = classify_display(spec.type)

"""
    describe_layout(::Type{H})::HeaderLayout
    describe_layout(h::Fields)::HeaderLayout

The layout of a header: the name, the bit offset and the bit width of every
field that reaches the wire. A model-only field takes no bits, so it is absent;
a constant does, so it is present.

This is the only reflection a view of a packet needs, and it reads the same
field types the codec does, so the two cannot disagree.
"""
function describe_layout(::Type{H}) where {H <: Fields}
    specs = FieldSpec[]
    offset = 0
    for index in 1:fieldcount(H)
        type = fieldtype(H, index)
        width = measure_field(type)
        width == 0 && continue
        push!(specs, FieldSpec(fieldname(H, index), type, offset, width))
        offset += width
    end
    return HeaderLayout(nameof(H), Bits(offset), specs)
end

describe_layout(h::Fields) = describe_layout(typeof(h))

"""
    get_field(h::Fields, spec::FieldSpec)

The value of one field of `h`.
"""
get_field(h::Fields, spec::FieldSpec) = getfield(h, spec.name)

"""
    encode_field(h::Fields, spec::FieldSpec)::UInt64

The raw bits of one field of `h`, as they go on the wire. A field wider than 64
bits has no `UInt64` to be; ask `format_field` for that one instead.
"""
function encode_field(h::Fields, spec::FieldSpec)
    has_bits(spec) ||
        error("encode_field: `$(spec.name)` is $(spec.width) bits wide and no UInt64 " *
              "holds it; use format_field")
    return encode_field(spec.type, get_field(h, spec))
end

"""
    format_field(h::Fields, spec::FieldSpec)::String

One field of `h`, as a reader wants to see it. The value prints itself.
"""
format_field(h::Fields, spec::FieldSpec) = format_field(get_field(h, spec))

# ---------- reading a field --------------------------------------------------

"""
    unwrap_field(value)

The value a reader sees. A `Model` and a `Constant` are boxes the codec needs
and a reader does not, so `h.checksum_mode` is the mode and not the box.
"""
unwrap_field(value) = value
unwrap_field(value::Model) = value.value
unwrap_field(::Constant{T, V}) where {T, V} = V

# `getfield` still gives the box, which is what the codec and `set_field` use.
Base.getproperty(h::Fields, name::Symbol) = unwrap_field(getfield(h, name))

# ---------- the length -------------------------------------------------------

"""
    measure_header(h::Fields)::Int

The width of a header in bits. `chunk_length` wraps it in a `BitLength`; a
`derive` clause wants the number.
"""
measure_header(h::Fields) = bits(chunk_length(h))

chunk_length(h::Fields) = chunk_length(typeof(h))

function chunk_length(::Type{H}) where {H <: Fields}
    total = 0
    for index in 1:fieldcount(H)
        total += measure_field(fieldtype(H, index))
    end
    return Bits(total)
end

minimum_chunk_length(::Type{H}) where {H <: Fields} = chunk_length(H)
is_fixed_length(::Type{H}) where {H <: Fields} = true

# ---------- serialize --------------------------------------------------------

function serialize(io::BitWriter, h::H) where {H <: Fields}
    # A check refuses BEFORE any bits reach the caller's writer: a header the
    # model built wrong is a bug, and half of it on the wire helps nobody.
    refuse_bad_header(H, h)
    write_from(io, h, Val(1))
    return io
end

function refuse_bad_header(::Type{H}, h::H) where {H <: Fields}
    for name in list_checked(H)
        check_field(H, Val(name), h) ||
            error("$(nameof(H)): refusing to serialize — the `$(name)` check failed")
    end
    return nothing
end

# The recursion the whole codec rests on. `Val(index)` makes the index a
# compile-time constant, so `fieldtype` and `measure_field` fold away and Julia
# unrolls the walk into straight-line code.
function write_from(io::BitWriter, h::H, ::Val{INDEX}) where {H <: Fields, INDEX}
    INDEX > fieldcount(H) && return nothing
    type = fieldtype(H, INDEX)
    width = measure_field(type)
    # A derived field is what the header computes, not what the struct holds.
    value = fieldname(H, INDEX) in list_derived(H) ?
            derive_field(H, Val(fieldname(H, INDEX)), h) : getfield(h, INDEX)
    width > 0 && write_field(io, type, value, width, byte_order(H))
    return write_from(io, h, Val(INDEX + 1))
end

# ---------- deserialize ------------------------------------------------------

function deserialize(::Type{H}, io::BitReader) where {H <: Fields}
    h = H(read_from(H, io, Val(1))...)
    # A check that fails on READ marks and hands the header back: a packet that
    # arrived malformed is data, not a program error. `peek` gates on the mark,
    # so the caller decides whether to accept it.
    return mark_bad_header(H, h)
end

function mark_bad_header(::Type{H}, h::H) where {H <: Fields}
    for name in list_checked(H)
        check_field(H, Val(name), h) || return mark_incorrect(h)
    end
    return h
end

function read_from(::Type{H}, io::BitReader, ::Val{INDEX}) where {H <: Fields, INDEX}
    INDEX > fieldcount(H) && return ()
    type = fieldtype(H, INDEX)
    width = measure_field(type)
    # A model-only field took no bits, so it takes its default instead.
    value = width > 0 ? read_field(io, type, width, byte_order(H)) :
                        convert(type, default_field(model_type(type)))
    return (value, read_from(H, io, Val(INDEX + 1))...)
end

model_type(::Type{Model{T}}) where {T} = T
model_type(::Type{T}) where {T} = T

# ---------- the entry points -------------------------------------------------

"""
    encode_header(h::Fields)::Vector{UInt8}

A header as bytes, padded to a whole number of them.
"""
function encode_header(h::Fields)
    writer = BitWriter()
    serialize(writer, h)
    needed = (bits(chunk_length(h)) + 7) >> 3
    while Base.length(writer.bytes) < needed
        push!(writer.bytes, 0x00)
    end
    return writer.bytes
end

"""
    decode_header(::Type{H}, bytes::Vector{UInt8})::H

A header read from bytes.
"""
decode_header(::Type{H}, bytes::Vector{UInt8}) where {H <: Fields} =
    deserialize(H, BitReader(bytes))

# ---------- what every header gets -------------------------------------------

# `quality(::Fields)` is already `Q_COMPLETE` in `Chunk.jl`: a bare header is
# complete. A `check` clause that fails on read returns the header inside a
# `MarkedFields` envelope, which carries the mark instead.

# Field-wise equality. Julia's default `==` on an immutable struct falls back to
# `===` once a field is not `isbits`, so a header with a byte field would never
# equal the identical one read back off the wire.
function Base.:(==)(a::H, b::H) where {H <: Fields}
    for index in 1:fieldcount(H)
        getfield(a, index) == getfield(b, index) || return false
    end
    return true
end

function Base.hash(h::H, seed::UInt) where {H <: Fields}
    for index in 1:fieldcount(H)
        seed = hash(getfield(h, index), seed)
    end
    return hash(nameof(H), seed)
end

function Base.show(io::IO, h::H) where {H <: Fields}
    print(io, nameof(H), "(")
    for (index, name) in enumerate(fieldnames(H))
        index > 1 && print(io, ", ")
        print(io, name, "=", getfield(h, index))
    end
    print(io, ")")
end
