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
# `header_fields` and `header_types` ARE the layout, so everything below is
# written once and works on that struct at once: `serialize`, `deserialize`,
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

# ---------- the layout ---------------------------------------------------------

"""
    header_fields(::Type{H}) -> Tuple{Vararg{Symbol}}
    header_types(::Type{H}) -> Tuple{Vararg{Type}}
    header_count(::Type{H})::Int

The fields a header puts on the wire, in order, their types, and how many there
are.

`fieldnames`, `fieldtypes` and `fieldcount` are not those. `@header` declares a
document, and `@document` appends a `selection` field that is machinery and
never encoded. Everything that walks a header's layout reads these three, and a
site that reaches for `fieldnames` or `1:fieldcount(H)` instead will encode the
selection.

A header written as a plain struct is a complete header too, and has no such
field. So the three ask, rather than assume: `has_selection_field` decides, and
`H` is concrete wherever they are called, so the answer is a constant and the
truncation folds away.

An index at or below `header_count(H)` means the same field it always did, so
`fieldtype(H, index)` and `fieldname(H, index)` are still read directly.
"""
@inline header_fields(::Type{H}) where {H <: Fields} =
    _wire_part(fieldnames(H), Val(has_selection_field(H)))
@inline header_types(::Type{H}) where {H <: Fields} =
    _wire_part(fieldtypes(H), Val(has_selection_field(H)))
@inline header_count(::Type{H}) where {H <: Fields} =
    fieldcount(H) - (has_selection_field(H) ? 1 : 0)

header_fields(h::Fields) = header_fields(typeof(h))
header_types(h::Fields)  = header_types(typeof(h))
header_count(h::Fields)  = header_count(typeof(h))

"""
    has_selection_field(::Type{H})::Bool

Whether `H` carries `@document`'s appended `selection` field. It is always the
last one, which is what makes dropping it a truncation rather than a filter.
"""
@inline has_selection_field(::Type{H}) where {H <: Fields} =
    fieldcount(H) > 0 && fieldname(H, fieldcount(H)) === :selection

# The `Val` is what keeps the two answers apart: the tuples have different
# lengths, so a branch on a plain `Bool` would leave the length to inference.
@inline _wire_part(all, ::Val{true}) = Base.front(all)
@inline _wire_part(all, ::Val{false}) = all

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
    # A variant family describes its base, which is what every member starts
    # with and all a reader knows before it has one.
    isabstracttype(H) && return describe_layout(variant_base(H))
    specs = FieldSpec[]
    offset = 0
    for index in 1:header_count(H)
        type = fieldtype(H, index)
        # A variable field has no width until there is an instance, and nothing
        # after it has an offset either, so the TYPE layout stops here.
        is_variable_field(type) && break
        width = measure_field(type)
        width == 0 && continue
        push!(specs, FieldSpec(fieldname(H, index), type, offset, width))
        offset += width
    end
    return HeaderLayout(document_schema_name(H), Bits(offset), specs)
end

# The layout of an INSTANCE has every field, with the widths this header
# actually has. It is what a view of a real packet reads.
function describe_layout(h::H) where {H <: Fields}
    is_fixed_length(H) && return describe_layout(H)
    specs = FieldSpec[]
    offset = 0
    for index in 1:header_count(H)
        width = measure_value(getfield(h, index), offset)
        if width > 0
            push!(specs, FieldSpec(fieldname(H, index), fieldtype(H, index), offset, width))
        end
        offset += width
    end
    return HeaderLayout(document_schema_name(H), Bits(offset), specs)
end

"""
    get_field(h::Fields, spec::FieldSpec)
    get_field(h::Fields, field::Symbol)

The value of one field of `h`, by the layout's own descriptor or by name.

`set_field` writes by name, so this reads by name: a caller holding a field name
should not have to build a descriptor to see what is in it.
"""
get_field(h::Fields, spec::FieldSpec) = getfield(h, spec.name)

function get_field(h::H, field::Symbol) where {H <: Fields}
    field in header_fields(H) ||
        error("get_field: $(H) has no field `$(field)`")
    return getfield(h, field)
end

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
# An optional field reads as the value it holds, or as `nothing`. A caller that
# wants to know whether it reaches the wire asks the `when` clause, not the
# struct — the clause is what both codecs obey.
unwrap_field(value::Optional) = value.value

# `getfield` still gives the box, which is what the codec and `set_field` use.
Base.getproperty(h::Fields, name::Symbol) = unwrap_field(getfield(h, name))

# ---------- the length -------------------------------------------------------

"""
    measure_header(h::Fields)::Int

The width of a header in bits. `chunk_length` wraps it in a `BitLength`; a
`derive` clause wants the number.
"""
measure_header(h::Fields) = bits(chunk_length(h))

# The length of an INSTANCE walks the fields with a running offset, because a
# byte run measures itself and padding measures the distance to its boundary.
# For a header with no variable field the walk folds to the type's constant.
function chunk_length(h::H) where {H <: Fields}
    offset = 0
    for index in 1:header_count(H)
        name = fieldname(H, index)
        # Ask the writer, not the value. A `when` clause can say a field is
        # absent while the struct still holds one, and the length of a header
        # is what it puts on the wire.
        #
        # The value is the STORED one, never the derived one. A derive may call
        # `measure_header`, which asks this function, and a derived field is as
        # wide either way — it is a fixed-width number in every declaration.
        offset += measure_write(H, Val(name), h, getfield(h, index), offset)
    end
    return Bits(offset)
end

"""
    is_fixed_length(::Type{H})::Bool

Whether every instance of `H` is the same width. `false` when a field's width
depends on the value or on where the codec is, so the length is a property of
the value and not of the type.
"""
function is_fixed_length(::Type{H}) where {H <: Fields}
    # A variant family is abstract and has no fields of its own: its members
    # have different lengths, so the family has none.
    isabstracttype(H) && return false
    for index in 1:header_count(H)
        type = fieldtype(H, index)
        # Padding is variable in general and determinate here. Its width is the
        # distance from a known offset to a boundary, and the offset is known
        # unless a field above it is variable — in which case this loop has
        # already said so.
        type <: Pad && continue
        is_variable_field(type) && return false
    end
    return true
end

"""
    minimum_chunk_length(::Type{H})::BitLength

The width of the fixed part — the whole of it when the header is fixed-length.
This is always known, which is what a reader needs before any bytes arrive.
"""
function minimum_chunk_length(::Type{H}) where {H <: Fields}
    # The least a variant family can be is its base — the part every member
    # starts with, and the part a reader needs before it can choose one.
    isabstracttype(H) && return minimum_chunk_length(variant_base(H))
    total = 0
    # Padding is as wide as the distance from its offset to a boundary, so it
    # counts only while the offset is known. After a variable field it is not,
    # and the least the padding can be is nothing.
    known_offset = true
    for index in 1:header_count(H)
        type = fieldtype(H, index)
        if type <: Pad
            known_offset && (total += measure_pad_width(type, total))
        elseif is_variable_field(type)
            known_offset = false
        else
            total += measure_field(type)
        end
    end
    return Bits(total)
end

"How wide a padding field is at `offset`, without an instance to ask."
measure_pad_width(::Type{Pad{B, F}}, offset::Int) where {B, F} = measure_padding(offset, B)

# A variable-length header has no length until there is an instance, so the
# type-level question names the two that always have an answer.
function chunk_length(::Type{H}) where {H <: Fields}
    is_fixed_length(H) ||
        error("chunk_length($(document_schema_name(H))): the length depends on the instance; ask " *
              "minimum_chunk_length, or chunk_length of a header you have")
    return minimum_chunk_length(H)
end

# ---------- serialize --------------------------------------------------------

function serialize(io::BitWriter, h::H) where {H <: Fields}
    # A check refuses BEFORE any bits reach the caller's writer: a header the
    # model built wrong is a bug, and half of it on the wire helps nobody.
    refuse_bad_header(H, h)
    write_from(io, h, Val(1), bit_count(io))
    return io
end

function refuse_bad_header(::Type{H}, h::H) where {H <: Fields}
    for name in list_checked(H)
        check_field(H, Val(name), h) ||
            error("$(document_schema_name(H)): refusing to serialize — the `$(name)` check failed")
    end
    return nothing
end

# The recursion the whole codec rests on. `Val(index)` makes the index a
# compile-time constant, so `fieldtype` and `measure_field` fold away and Julia
# unrolls the walk into straight-line code.
function write_from(io::BitWriter, h::H, ::Val{INDEX}, start::Int) where {H <: Fields, INDEX}
    INDEX > header_count(H) && return nothing
    type = fieldtype(H, INDEX)
    # A derived field is what the header computes, not what the struct holds.
    value = fieldname(H, INDEX) in list_derived(H) ?
            derive_field(H, Val(fieldname(H, INDEX)), h) : getfield(h, INDEX)
    # `offset` is how far into THIS header the writer is, which is what padding
    # measures itself against. A `when` clause decides presence on BOTH sides,
    # so `measure_write` asks the clause where there is one.
    width = measure_write(H, Val(fieldname(H, INDEX)), h, value, bit_count(io) - start)
    width > 0 && write_field(io, type, value, width, byte_order(H))
    return write_from(io, h, Val(INDEX + 1), start)
end

# ---------- deserialize ------------------------------------------------------

function deserialize(::Type{H}, io::BitReader) where {H <: Fields}
    # A variant family reads its base first and then reads again as the member
    # the base chose. `list_variants` is empty for every other header, so the
    # branch folds away.
    isempty(list_variants(H)) || return deserialize_variant(H, io)
    h = H(read_from(H, io, Val(1), NamedTuple(), io.bit_pos)...)
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

# The read walk carries the fields it has already read, because the width of a
# byte run is an expression over them — `length(Bytes(count))` reads a `count`
# the reader met three fields ago.
function read_from(::Type{H}, io::BitReader, ::Val{INDEX},
                   sofar::NamedTuple, start::Int) where {H <: Fields, INDEX}
    INDEX > header_count(H) && return ()
    type = fieldtype(H, INDEX)
    name = fieldname(H, INDEX)
    width = measure_read(H, Val(name), type, sofar,
                         io.bit_pos - start, io.total - io.bit_pos)
    # A model-only field took no bits, so it takes its default instead.
    value = width > 0 || is_variable_field(type) ?
            read_field(io, type, width, byte_order(H)) :
            convert(type, default_field(model_type(type)))
    return (value, read_from(H, io, Val(INDEX + 1),
                             merge(sofar, NamedTuple{(name,)}((unwrap_field(value),))),
                             start)...)
end

"""
    measure_write(::Type{H}, ::Val{NAME}, h, value, offset::Int)::Int

How many bits the `NAME` field takes, on the way out. The default is the width
of the value. `@header` defines one for a `when` field, so the clause decides
presence on the way out as it does on the way in — a struct that says absent
where the clause says present is a header the model built wrong, and the
writer says so rather than emitting a shorter one.
"""
measure_write(::Type{H}, ::Val{NAME}, h, value, offset::Int) where {H, NAME} =
    measure_value(value, offset)

"""
    measure_read(::Type{H}, ::Val{NAME}, ::Type{T}, sofar, offset, remaining)::Int

How many bits the `NAME` field takes, on the way in. `@header` defines one per
field that carries a `length`, `count`, `until` or `when` clause; every other
field falls to the one method below, which asks the type.

There is exactly one method here on purpose. A clause names its header and its
field, and a type-specialised method names its type, so neither is more
specific than the other and a field with both would be an ambiguous call.
`measure_default` moves the type's answer out of dispatch on `NAME`, where it
cannot collide.
"""
measure_read(::Type{H}, ::Val{NAME}, ::Type{T}, sofar, offset::Int,
             remaining::Int) where {H, NAME, T} = measure_default(T, offset, remaining)

"""
    measure_default(::Type{T}, offset::Int, remaining::Int)::Int

The width a field of type `T` takes when its header states no clause for it.
"""
measure_default(::Type{T}, offset::Int, remaining::Int) where {T} = measure_field(T)

# An embedded variable-length header decides its own size out of the stream, so
# the reader asks it rather than working the width out first.
measure_default(::Type{E}, offset::Int, remaining::Int) where {E <: Fields} =
    is_fixed_length(E) ? measure_field(E) : 0

measure_default(::Type{Rest}, offset::Int, remaining::Int) = remaining

measure_default(::Type{Pad{B, F}}, offset::Int, remaining::Int) where {B, F} =
    measure_padding(offset, B)

# A list with no window runs to the end of what is there. That is the IGMPv3
# group records, and it is the neighbour discovery options — `Options.jl`
# carries that one, because `Options` is declared after this file.
measure_default(::Type{<:Repeated}, offset::Int, remaining::Int) = remaining

model_type(::Type{Model{T}}) where {T} = T
model_type(::Type{T}) where {T} = T

"The value type an `Optional` field wraps."
optional_type(::Type{Optional{T}}) where {T} = T
optional_type(::Type{T}) where {T} = T

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
    for index in 1:header_count(H)
        getfield(a, index) == getfield(b, index) || return false
    end
    return true
end

function Base.hash(h::H, seed::UInt) where {H <: Fields}
    for index in 1:header_count(H)
        seed = hash(getfield(h, index), seed)
    end
    return hash(document_schema_name(H), seed)
end

function Base.show(io::IO, h::H) where {H <: Fields}
    print(io, document_schema_name(H), "(")
    for (index, name) in enumerate(header_fields(H))
        index > 1 && print(io, ", ")
        print(io, name, "=", getfield(h, name))
    end
    print(io, ")")
end
