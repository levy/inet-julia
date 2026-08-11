# ============================================================================
# The IPv6 options — RFC 8200, section 4.2.
#
# An option is a type octet, a length octet and that many octets of value. One
# option breaks the rule: Pad1 is a single zero octet with no length and no
# value, because a one-octet hole cannot hold a length.
#
# The list runs to the end of the extension header that carries it, which the
# header extension length gives. There is no end-of-list code — a hop-by-hop or
# destination options header pads with Pad1 and PadN, so a trailing zero octet
# reads back as a Pad1 and re-encodes to the same octet.
#
# An option this library does not know becomes an `Ipv6OptionRaw`, which keeps
# its type, its length and its bytes.
# ============================================================================

const IPV6_TLVOPTION_PAD1 = 0
const IPV6_TLVOPTION_PADN = 1

"The IPv6 options — one shape, and the type octet says which."
abstract type Ipv6Option <: Fields end

"""
    Ipv6OptionPad1()

Pad1, one octet. It is the only option with no length octet.
"""
@header Ipv6OptionPad1 <: Ipv6Option begin
    type :: Constant{U8, IPV6_TLVOPTION_PAD1}
end

"""
    Ipv6OptionPadN(; padding)

PadN, two octets plus the padding it carries. The padding is zero octets, and
this is how a header reaches its eight-octet boundary.
"""
@header Ipv6OptionPadN <: Ipv6Option begin
    type    :: Constant{U8, IPV6_TLVOPTION_PADN}
    length  :: U8 = 0
        derive(Base.length(padding))
    padding :: Octets
        length(Bytes(length))
end

"""
    Ipv6OptionRaw(; type, data)

An option this library does not model. It keeps everything, so the header
round-trips.
"""
@header Ipv6OptionRaw <: Ipv6Option begin
    type   :: U8
    length :: U8 = 0
        derive(Base.length(data))
    data   :: Octets
        length(Bytes(length))
end

list_options(::Type{Ipv6Option}) = (Ipv6OptionPad1, Ipv6OptionPadN)
find_raw_option(::Type{Ipv6Option}) = Ipv6OptionRaw
