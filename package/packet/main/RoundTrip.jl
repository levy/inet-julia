# ============================================================================
# The round-trip corpus — the check the C++ branch is about.
#
# Before that branch, a `FieldsChunk` built by deserialization cached the
# original wire bytes and the serializer replayed the cache instead of
# re-encoding from the parsed fields. Every asymmetry between the reader and
# the writer was therefore invisible. With the cache cleared, the pcap corpus
# went from 1219 differing frames to 30.
#
# This library keeps no such cache, and does not want one. What it has instead
# is this: build a header whose every field is distinct, and check that
#
#     encode → decode → encode
#
# gives the same bytes and the same length. A field read in the wrong order, a
# width one bit off, a swap between two fields of the same type — each changes
# those bytes.
#
# `fill_asymmetric` builds the instance. It reads `fieldtypes`, so it needs no
# per-header recipe, and it leaves a checked field at its declared value —
# a header that fails its own check is not a round-trip test, it is a check
# test.
# ============================================================================

"""
    list_headers()::Vector{Type}

Every header `@header` declared, in declaration order. A header written as a
plain struct is absent unless it calls `register_header`.
"""
list_headers() = copy(DECLARED_HEADERS)

const DECLARED_HEADERS = Type[]

"""
    register_header(::Type{H})

Add `H` to `list_headers`. `@header` does this; a header written as a plain
struct calls it to join the corpus.
"""
function register_header(::Type{H}) where {H <: Fields}
    H in DECLARED_HEADERS || push!(DECLARED_HEADERS, H)
    return H
end

"""
    fill_field(::Type{T}, seed::Int)

A `T` whose bits are distinct from its neighbours'. `seed` is the field's
position, so two fields of the same type never hold the same value.
"""
fill_field(::Type{T}, seed::Int) where {T <: Unsigned} = T(seed * 7 % (typemax(T) + 1))
fill_field(::Type{U{N, T}}, seed::Int) where {N, T} =
    U{N, T}((seed * 7) % (N >= 64 ? typemax(UInt64) : UInt64(1) << N))
fill_field(::Type{I{N, T}}, seed::Int) where {N, T} =
    I{N, T}((seed * 7) % (Int64(1) << (N - 1)))
fill_field(::Type{Bool}, seed::Int) = isodd(seed)
fill_field(::Type{T}, seed::Int) where {T <: Base.Enum} = first(instances(T))
fill_field(::Type{MacAddress}, seed::Int) = MacAddress(0x0a0000000000 + seed)
fill_field(::Type{Ipv4Address}, seed::Int) = Ipv4Address(0x0a000000 + seed)
fill_field(::Type{Ipv6Address}, seed::Int) =
    Ipv6Address(0x2001_0db8_0000_0000, UInt64(seed))
fill_field(::Type{EtherTypeOrLength}, seed::Int) = EtherTypeOrLength(0x8000 + seed)
fill_field(::Type{IpProtocol}, seed::Int) = IpProtocol(seed)
fill_field(::Type{Port}, seed::Int) = Port(1000 + seed)
fill_field(::Type{Checksum16}, seed::Int) = Checksum16(0x1000 + seed)
fill_field(::Type{Constant{T, V}}, ::Int) where {T, V} = Constant{T, V}()
fill_field(::Type{Pad{B, F}}, ::Int) where {B, F} = Pad{B, F}()
fill_field(::Type{Model{T}}, ::Int) where {T} = Model{T}(default_field(T))
fill_field(::Type{Octets}, seed::Int) = Octets(UInt8[seed % 256])
fill_field(::Type{Rest}, seed::Int) = Rest(UInt8[seed % 256])
fill_field(::Type{Repeated{T}}, seed::Int) where {T} = Repeated{T}([fill_field(T, seed)])
fill_field(::Type{Options{F}}, ::Int) where {F} = Options{F}(F[])
# An optional field starts present. Whether it REACHES the wire is the `when`
# clause's answer, and the writer asks the clause — so a value that turns out
# not to be wanted costs nothing, and one that is wanted is there.
fill_field(::Type{Optional{T}}, seed::Int) where {T} = Optional{T}(fill_field(T, seed))
fill_field(::Type{H}, seed::Int) where {H <: Fields} = fill_asymmetric(H, seed)

"""
    fill_asymmetric(::Type{H}, seed = 0)::H

A header whose every field holds a distinct value, except the ones a `check`
clause pins — those keep the value the declaration gives, because a header
that fails its own check tests the check and not the round trip.
"""
function fill_asymmetric(::Type{H}, seed::Int = 0) where {H <: Fields}
    checked = list_checked(H)
    values = Any[]
    for index in 1:fieldcount(H)
        name = fieldname(H, index)
        type = fieldtype(H, index)
        default = find_default(H, Val(name))
        push!(values, name in checked && default !== nothing ? default :
                      fill_field(type, seed + index))
    end
    return H(values...)
end

"""
    check_round_trip(::Type{H})::Bool

Whether a header of `H` survives encode, decode and encode again — the same
bytes and the same length. This is the C++ `serializer_chunk_roundtrip` test,
and it is cheaper here because `fieldtypes` gives the field list for free.
"""
function check_round_trip(::Type{H}) where {H <: Fields}
    header = fill_asymmetric(H)
    bytes = encode_header(header)
    again = decode_header(H, bytes)
    again isa MarkedFields && (again = again.header)
    return encode_header(again) == bytes && chunk_length(again) == chunk_length(header)
end
