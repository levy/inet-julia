# ============================================================================
# Field values — what a header field may be, and how it reaches the wire.
#
# A field's TYPE says what the value means and how wide it is. Nothing else
# does: there is no width segment, no display base and no byte order in a
# declaration, because all three follow from the type. `version :: U4` is a
# four-bit number, and `header_checksum :: Checksum16` prints as hex because a
# checksum does.
#
# Every value type answers three questions, and the last two have a default:
#
#     measure_field(::Type{T})::Int                   how wide a T field is
#     write_field(io, ::Type{T}, value, width, order) which bits it becomes
#     read_field(io, ::Type{T}, width, order)::T      which value they are
#
# A type of 64 bits or fewer may answer `encode_field` and `decode_field`
# instead and inherit the pair above. A type that is wider — an `Ipv6Address`
# is 128 bits — defines the pair itself, because no `UInt64` carries it.
#
# This file holds the protocol and the numbers. The named types of a protocol
# — `MacAddress`, `Port`, `EtherTypeOrLength` — are in `FieldTypes.jl`.
# ============================================================================

# ---------- the protocol ----------------------------------------------------

"""
    measure_field(::Type{T})::Int

The width of a `T` field in bits.
"""
function measure_field end

"""
    encode_field(::Type{T}, value)::UInt64

The bits that `value` becomes on the wire, in the low bits of a `UInt64`. A
type wider than 64 bits has no answer and defines `write_field` instead.
"""
function encode_field end

"""
    decode_field(::Type{T}, bits::UInt64)::T

The value that `bits` comes back as. The inverse of `encode_field`.
"""
function decode_field end

"""
    write_field(io::BitWriter, ::Type{T}, value, width::Int, order::Symbol)

Write `value` as a `T` field of `width` bits, in byte order `order`. This is
what the codec calls.
"""
function write_field end

"""
    read_field(io::BitReader, ::Type{T}, width::Int, order::Symbol)::T

Read a `T` field of `width` bits, in byte order `order`. The inverse of
`write_field`.
"""
function read_field end

write_field(io::BitWriter, ::Type{T}, value, width::Int, order::Symbol) where {T} =
    write_bits!(io, encode_field(T, value), width, order)
read_field(io::BitReader, ::Type{T}, width::Int, order::Symbol) where {T} =
    decode_field(T, read_bits!(io, width, order))

"""
    format_field(value)::String

One value, as a reader wants to see it. The default is how the value prints,
which is why a value type prints itself well: one text form then serves the
REPL, the tests, the packet diagram and the editor.
"""
format_field(value) = string(value)

"""
    classify_display(::Type{T})::Symbol

How a reflective view treats a `T` field.

  `:scalar`     never opened — the inside says nothing a reader wants
  `:openable`   shown as its text, opened on request, because the parts are real
  `:composite`  always a level, because it is one

The default is `:composite`, so an ordinary struct is unaffected.
"""
classify_display(::Type) = :composite

"""
    has_field_bits(::Type{T})::Bool

Whether one `UInt64` holds a `T` field. `false` for a run of bytes: a
three-byte field would fit, and still is not a number.
"""
has_field_bits(::Type{T}) where {T} = measure_field(T) <= 64

# ---------- U{N} — an N-bit unsigned number ---------------------------------

"""
    U{N, T}

An `N`-bit unsigned number, stored in the smallest standard unsigned that
holds it. The aliases `U1` … `U64` name the widths, so a declaration reads
`version :: U4` beside `time_to_live :: U8`.

The width is checked once, at construction: `U4(16)` raises. A four-bit field
therefore cannot carry a value that the wire would truncate.
"""
struct U{N, T <: Unsigned} <: Integer
    value::T

    function U{N, T}(value::Integer) where {N, T}
        0 <= value <= _widest(N) ||
            throw(InexactError(:U, U{N, T}, value))
        return new{N, T}(T(value))
    end
end

_widest(n::Int) = n >= 64 ? typemax(UInt64) : (UInt64(1) << n) - 1

"The smallest standard unsigned that holds `n` bits."
store_unsigned(n::Int) = n <= 8 ? UInt8 : n <= 16 ? UInt16 : n <= 32 ? UInt32 : UInt64

for n in 1:64
    @eval const $(Symbol(:U, n)) = U{$n, $(store_unsigned(n))}
    @eval export $(Symbol(:U, n))
end

U{N}(value::Integer) where {N} = U{N, store_unsigned(N)}(value)

measure_field(::Type{U{N, T}}) where {N, T} = N
encode_field(::Type{U{N, T}}, value::U{N, T}) where {N, T} = UInt64(value.value)
decode_field(::Type{U{N, T}}, bits::UInt64) where {N, T} = U{N, T}(bits)
classify_display(::Type{<:U}) = :scalar

Base.convert(::Type{U{N, T}}, value::Integer) where {N, T} = U{N, T}(value)
Base.promote_rule(::Type{U{N, T}}, ::Type{S}) where {N, T, S <: Integer} =
    promote_type(T, S)
Base.promote_rule(::Type{U{N, T}}, ::Type{U{M, S}}) where {N, T, M, S} =
    promote_type(T, S)
(::Type{S})(value::U) where {S <: Integer} = S(value.value)

Base.typemin(::Type{U{N, T}}) where {N, T} = U{N, T}(0)
Base.typemax(::Type{U{N, T}}) where {N, T} = U{N, T}(_widest(N))
Base.:(==)(a::U{N, T}, b::U{N, T}) where {N, T} = a.value == b.value
Base.:(<)(a::U{N, T}, b::U{N, T}) where {N, T} = a.value < b.value
Base.hash(value::U, seed::UInt) = hash(value.value, seed)
Base.show(io::IO, value::U) = print(io, value.value)

# ---------- I{N} — an N-bit signed number -----------------------------------

"""
    I{N, T}

An `N`-bit two's complement number, stored in the smallest standard signed that
holds it. The aliases `I2` … `I64` name the widths.

`Ieee80211MacHeader` is why this exists: it uses `-1` in a twelve-bit field to
mean "no association identifier", and `-1` in twelve bits is `0xfff` on the
wire, not `0xffff`. The width therefore belongs to the type, so the reader
extends the sign from the right place.
"""
struct I{N, T <: Signed} <: Integer
    value::T

    function I{N, T}(value::Integer) where {N, T}
        -(Int64(1) << (N - 1)) <= value <= (Int64(1) << (N - 1)) - 1 ||
            throw(InexactError(:I, I{N, T}, value))
        return new{N, T}(T(value))
    end
end

"The smallest standard signed that holds `n` bits."
store_signed(n::Int) = n <= 8 ? Int8 : n <= 16 ? Int16 : n <= 32 ? Int32 : Int64

for n in 2:64
    @eval const $(Symbol(:I, n)) = I{$n, $(store_signed(n))}
    @eval export $(Symbol(:I, n))
end

I{N}(value::Integer) where {N} = I{N, store_signed(N)}(value)

measure_field(::Type{I{N, T}}) where {N, T} = N
classify_display(::Type{<:I}) = :scalar

write_field(io::BitWriter, ::Type{I{N, T}}, value::I{N, T},
            width::Int, order::Symbol) where {N, T} =
    write_bits!(io, UInt64(unsigned(Int64(value.value))), width, order)
read_field(io::BitReader, ::Type{I{N, T}}, width::Int, order::Symbol) where {N, T} =
    I{N, T}(extend_sign(read_bits!(io, width, order), width))

"""
    extend_sign(bits::UInt64, width::Int)::Int64

The value of `width` two's complement bits, as a signed number.
"""
function extend_sign(bits::UInt64, width::Int)
    width >= 64 && return reinterpret(Int64, bits)
    sign = UInt64(1) << (width - 1)
    return iszero(bits & sign) ? Int64(bits) : Int64(bits) - (Int64(1) << width)
end

Base.convert(::Type{I{N, T}}, value::Integer) where {N, T} = I{N, T}(value)
Base.promote_rule(::Type{I{N, T}}, ::Type{S}) where {N, T, S <: Integer} =
    promote_type(T, S)
Base.promote_rule(::Type{I{N, T}}, ::Type{I{M, S}}) where {N, T, M, S} =
    promote_type(T, S)

Base.typemin(::Type{I{N, T}}) where {N, T} = I{N, T}(-(Int64(1) << (N - 1)))
Base.typemax(::Type{I{N, T}}) where {N, T} = I{N, T}((Int64(1) << (N - 1)) - 1)
Base.:(==)(a::I{N, T}, b::I{N, T}) where {N, T} = a.value == b.value
Base.:(<)(a::I{N, T}, b::I{N, T}) where {N, T} = a.value < b.value
Base.hash(value::I, seed::UInt) = hash(value.value, seed)
Base.show(io::IO, value::I) = print(io, value.value)

# ---------- the types a header borrows from Julia ----------------------------

# A single-bit flag is a `Bool`. There is no `Bit` type, because `Bool` already
# measures one bit and reads the way RFC 791 names the flags it defines.
measure_field(::Type{Bool}) = 1
encode_field(::Type{Bool}, value::Bool) = UInt64(value)
decode_field(::Type{Bool}, bits::UInt64) = !iszero(bits)
classify_display(::Type{Bool}) = :scalar

# The standard unsigned types keep their natural widths, so a field that is a
# whole number of bytes may say `UInt16` rather than `U16`.
measure_field(::Type{T}) where {T <: Unsigned} = sizeof(T) * 8
encode_field(::Type{T}, value::Unsigned) where {T <: Unsigned} = UInt64(value)
decode_field(::Type{T}, bits::UInt64) where {T <: Unsigned} = T(bits)
classify_display(::Type{<:Unsigned}) = :scalar

# An enum field carries its own numbers, and prints the name it knows.
measure_field(::Type{T}) where {T <: Base.Enum} = sizeof(T) * 8
encode_field(::Type{T}, value::T) where {T <: Base.Enum} = UInt64(Integer(value))
decode_field(::Type{T}, bits::UInt64) where {T <: Base.Enum} = T(bits)
classify_display(::Type{<:Base.Enum}) = :scalar

# ---------- Constant and Model ----------------------------------------------

"""
    Constant{T, V}

A field that is on the wire and holds nothing. It takes the width of `T`,
writes `V`, and discards what it reads. That is a reserved field and a fixed
delimiter — `Ieee80211MpduSubframeHeader` writes a constant `0x4E`.

The struct field is a zero-size singleton, so it stores nothing at all.
"""
struct Constant{T, V}
    Constant{T, V}() where {T, V} = new{T, V}()
end

Constant{T, V}(::Constant{T, V}) where {T, V} = Constant{T, V}()

measure_field(::Type{Constant{T, V}}) where {T, V} = measure_field(T)
classify_display(::Type{<:Constant}) = :scalar
Base.show(io::IO, ::Constant{T, V}) where {T, V} = print(io, V)

write_field(io::BitWriter, ::Type{Constant{T, V}}, ::Constant{T, V},
            width::Int, order::Symbol) where {T, V} =
    write_field(io, T, convert(T, V), width, order)
function read_field(io::BitReader, ::Type{Constant{T, V}},
                    width::Int, order::Symbol) where {T, V}
    read_field(io, T, width, order)          # read and drop
    return Constant{T, V}()
end

"""
    Model{T}

A field that is in the struct and never on the wire. That is how a header
carries state its protocol needs and its format does not — INET's
`ChecksumMode` and `FcsMode`, and `Ieee80211MacHeader::MACArrive`.

A model-only field must have a default, because a reader has no bits for it.
"""
struct Model{T}
    value::T
end

Model{T}(value::Model{T}) where {T} = value

measure_field(::Type{Model{T}}) where {T} = 0
classify_display(::Type{<:Model}) = :scalar
Base.show(io::IO, value::Model) = print(io, value.value)
Base.:(==)(a::Model{T}, b::Model{T}) where {T} = a.value == b.value
Base.hash(value::Model, seed::UInt) = hash(value.value, seed)
Base.convert(::Type{Model{T}}, value) where {T} = Model{T}(convert(T, value))

# A model-only field takes no bits, so the codec never calls these; they exist
# so a generic walk over the field types needs no special case.
write_field(::BitWriter, ::Type{<:Model}, _value, ::Int, ::Symbol) = nothing

# `U` and `I` are `Integer`s, so Base expects the Integer interface of them.
# Everything below delegates to the storage and returns a plain number: a
# narrowed value is a wire fact, and arithmetic on one is arithmetic.
#
# Two values of the same type do not promote — Julia short-circuits same-type
# promotion — so a pair needs its own method as well.
for operator in (:+, :-, :*, :div, :rem, :mod, :&, :|, :xor)
    @eval Base.$operator(a::U, b::U) = $operator(a.value, b.value)
    @eval Base.$operator(a::I, b::I) = $operator(a.value, b.value)
end
for operator in (:-, :+, :~, :abs, :sign, :trailing_zeros, :leading_zeros, :count_ones)
    @eval Base.$operator(a::U) = $operator(a.value)
    @eval Base.$operator(a::I) = $operator(a.value)
end
for operator in (:<<, :>>, :>>>)
    @eval Base.$operator(a::U, n::Integer) = $operator(a.value, n)
    @eval Base.$operator(a::I, n::Integer) = $operator(a.value, n)
end
Base.zero(::Type{U{N, T}}) where {N, T} = U{N, T}(0)
Base.one(::Type{U{N, T}}) where {N, T} = U{N, T}(1)
Base.zero(::Type{I{N, T}}) where {N, T} = I{N, T}(0)
Base.one(::Type{I{N, T}}) where {N, T} = I{N, T}(1)
Base.iszero(a::U) = iszero(a.value)
Base.iszero(a::I) = iszero(a.value)
