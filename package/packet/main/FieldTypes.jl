# ============================================================================
# Field types — what a declared header field may be, and how it reaches the wire.
#
# `@header` needs four answers about every field type: how wide it is, which
# bits it becomes, which value those bits come back as, and how a reader wants
# to see it. Four generic functions give those answers, so a header field can be
# a `MacAddress` or an `Ipv4Address` instead of an integer that a comment claims
# is one.
#
# The integer types answer all four by default, so a header that declares only
# `UInt8` and `UInt16` fields needs nothing from this file.
# ============================================================================

# ---------- the protocol ----------------------------------------------------

"""
    field_width(::Type{T})::Int

The width of a `T` field in bits, when the declaration omits `| n`.
"""
function field_width end

"""
    field_encode(::Type{T}, value)::UInt64

The bits that `value` becomes on the wire, in the low bits of a `UInt64`.
"""
function field_encode end

"""
    field_decode(::Type{T}, bits::UInt64)::T

The value that `bits` comes back as. The inverse of `field_encode`.
"""
function field_decode end

"""
    field_base(::Type{T}, width::Int)::Symbol

How a reader wants to see a `T` field of `width` bits: `:bin`, `:dec`, `:hex`,
`:mac`, `:ipv4` or `:enum`. A declaration overrides this with a third segment.
"""
function field_base end

# ---------- the integer types -----------------------------------------------

field_width(::Type{T}) where {T <: Unsigned} = sizeof(T) * 8
field_encode(::Type{T}, value::Unsigned) where {T <: Unsigned} = UInt64(value)
field_decode(::Type{T}, bits::UInt64) where {T <: Unsigned} = T(bits)

# A field that is not a whole number of bytes reads as bits. A whole number of
# bytes reads as a number. Everything else is a per-field override.
field_base(::Type{T}, width::Int) where {T <: Unsigned} =
    width % 8 == 0 ? :dec : :bin

field_width(::Type{Bool}) = 1
field_encode(::Type{Bool}, value::Bool) = UInt64(value)
field_decode(::Type{Bool}, bits::UInt64) = !iszero(bits)
field_base(::Type{Bool}, ::Int) = :bin

# An enum field carries its own numbers. `field_decode` throws on a number the
# enum does not name, which is why the protocol headers below use the wrapper
# types instead: a foreign implementation may send anything.
field_width(::Type{T}) where {T <: Base.Enum} = sizeof(T) * 8
field_encode(::Type{T}, value::T) where {T <: Base.Enum} = UInt64(Integer(value))
field_decode(::Type{T}, bits::UInt64) where {T <: Base.Enum} = T(bits)
field_base(::Type{T}, ::Int) where {T <: Base.Enum} = :enum

# ---------- MacAddress ------------------------------------------------------

"""
    MacAddress(value)
    MacAddress(o1, o2, o3, o4, o5, o6)

A 48-bit IEEE 802 address. It prints and parses as `0a:00:00:00:00:01`.
"""
struct MacAddress
    value::UInt64
    MacAddress(value::Integer) = new(UInt64(value) & 0x0000_ffff_ffff_ffff)
end

MacAddress(o1::Integer, o2::Integer, o3::Integer, o4::Integer, o5::Integer, o6::Integer) =
    MacAddress((UInt64(o1) << 40) | (UInt64(o2) << 32) | (UInt64(o3) << 24) |
               (UInt64(o4) << 16) | (UInt64(o5) << 8) | UInt64(o6))

function MacAddress(text::AbstractString)
    parts = split(text, ':')
    Base.length(parts) == 6 || error("MacAddress: expected six octets, got $(repr(text))")
    MacAddress((parse(UInt8, p, base = 16) for p in parts)...)
end

mac_octets(m::MacAddress) = ntuple(i -> UInt8((m.value >> (8 * (6 - i))) & 0xff), 6)

Base.show(io::IO, m::MacAddress) =
    print(io, join((string(o, base = 16, pad = 2) for o in mac_octets(m)), ":"))

Base.convert(::Type{MacAddress}, value::Integer) = MacAddress(value)

field_width(::Type{MacAddress}) = 48
field_encode(::Type{MacAddress}, m::MacAddress) = m.value
field_decode(::Type{MacAddress}, bits::UInt64) = MacAddress(bits)
field_base(::Type{MacAddress}, ::Int) = :mac

"The broadcast address, `ff:ff:ff:ff:ff:ff`."
const MAC_BROADCAST = MacAddress(0x0000_ffff_ffff_ffff)

is_multicast(m::MacAddress) = !iszero(m.value & (UInt64(1) << 40))
is_broadcast(m::MacAddress) = m == MAC_BROADCAST

# ---------- Ipv4Address -----------------------------------------------------

"""
    Ipv4Address(value)
    Ipv4Address(a, b, c, d)

A 32-bit IPv4 address. It prints and parses as `10.0.0.1`.
"""
struct Ipv4Address
    value::UInt32
    Ipv4Address(value::Integer) = new(UInt32(value))
end

Ipv4Address(a::Integer, b::Integer, c::Integer, d::Integer) =
    Ipv4Address((UInt32(a) << 24) | (UInt32(b) << 16) | (UInt32(c) << 8) | UInt32(d))

function Ipv4Address(text::AbstractString)
    parts = split(text, '.')
    Base.length(parts) == 4 || error("Ipv4Address: expected four octets, got $(repr(text))")
    Ipv4Address((parse(UInt8, p) for p in parts)...)
end

ipv4_octets(a::Ipv4Address) = ntuple(i -> UInt8((a.value >> (8 * (4 - i))) & 0xff), 4)

Base.show(io::IO, a::Ipv4Address) = print(io, join(ipv4_octets(a), "."))

Base.convert(::Type{Ipv4Address}, value::Integer) = Ipv4Address(value)

field_width(::Type{Ipv4Address}) = 32
field_encode(::Type{Ipv4Address}, a::Ipv4Address) = UInt64(a.value)
field_decode(::Type{Ipv4Address}, bits::UInt64) = Ipv4Address(UInt32(bits))
field_base(::Type{Ipv4Address}, ::Int) = :ipv4

# ---------- EtherType -------------------------------------------------------

"""
    EtherType(value)

The 16-bit type field of an Ethernet MAC header. A value the table below names
prints as `IPv4 (0x0800)`; any other value prints as its number alone, because
a foreign implementation may send a type this library does not know.
"""
struct EtherType
    value::UInt16
    EtherType(value::Integer) = new(UInt16(value))
end

const ETHERTYPE_NAMES = Dict{UInt16, String}(
    0x0800 => "IPv4",
    0x0806 => "ARP",
    0x8100 => "VLAN",
    0x86dd => "IPv6",
    0x88a8 => "QinQ",
    0x88cc => "LLDP",
    0x88f7 => "PTP")

ethertype_name(t::EtherType) = get(ETHERTYPE_NAMES, t.value, nothing)

function Base.show(io::IO, t::EtherType)
    name = ethertype_name(t)
    hex = "0x" * string(t.value, base = 16, pad = 4)
    name === nothing ? print(io, hex) : print(io, name, " (", hex, ")")
end

Base.convert(::Type{EtherType}, value::Integer) = EtherType(value)

field_width(::Type{EtherType}) = 16
field_encode(::Type{EtherType}, t::EtherType) = UInt64(t.value)
field_decode(::Type{EtherType}, bits::UInt64) = EtherType(UInt16(bits))
field_base(::Type{EtherType}, ::Int) = :enum

# ---------- IpProtocol ------------------------------------------------------

"""
    IpProtocol(value)

The 8-bit protocol field of an IPv4 header. It prints as `UDP (17)` when the
table names it, and as its number alone when it does not.
"""
struct IpProtocol
    value::UInt8
    IpProtocol(value::Integer) = new(UInt8(value))
end

const IP_PROTOCOL_NAMES = Dict{UInt8, String}(
    0x01 => "ICMP",
    0x02 => "IGMP",
    0x06 => "TCP",
    0x11 => "UDP",
    0x29 => "IPv6",
    0x3a => "ICMPv6",
    0x59 => "OSPF",
    0x84 => "SCTP")

ip_protocol_name(p::IpProtocol) = get(IP_PROTOCOL_NAMES, p.value, nothing)

function Base.show(io::IO, p::IpProtocol)
    name = ip_protocol_name(p)
    name === nothing ? print(io, Int(p.value)) : print(io, name, " (", Int(p.value), ")")
end

Base.convert(::Type{IpProtocol}, value::Integer) = IpProtocol(value)

field_width(::Type{IpProtocol}) = 8
field_encode(::Type{IpProtocol}, p::IpProtocol) = UInt64(p.value)
field_decode(::Type{IpProtocol}, bits::UInt64) = IpProtocol(UInt8(bits))
field_base(::Type{IpProtocol}, ::Int) = :enum

# ---------- PortNumber ------------------------------------------------------

"""
    PortNumber(value)

A 16-bit transport port. It is a type of its own so that a header cannot take a
port where it wants a length, and so that the diagram knows to print it as a
decimal number.
"""
struct PortNumber
    value::UInt16
    PortNumber(value::Integer) = new(UInt16(value))
end

Base.show(io::IO, p::PortNumber) = print(io, Int(p.value))

Base.convert(::Type{PortNumber}, value::Integer) = PortNumber(value)

field_width(::Type{PortNumber}) = 16
field_encode(::Type{PortNumber}, p::PortNumber) = UInt64(p.value)
field_decode(::Type{PortNumber}, bits::UInt64) = PortNumber(UInt16(bits))
field_base(::Type{PortNumber}, ::Int) = :dec
