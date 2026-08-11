# ============================================================================
# The IPv6 extension headers — RFC 8200, sections 4.3 to 4.6.
#
# An IPv6 datagram carries its options in headers of their own, after the base
# header and before the payload. Each one names the header that follows it, so
# the chain is a linked list and the base header's `next_header` is its head.
#
# Four of the six share a shape: a next-header octet, a length octet counting
# eight-octet units after the first eight, and then the header's own fields.
# `Ipv6FragmentHeader` is the exception — it is always eight octets, so it
# spends the second octet on a reserved field instead.
#
# Two deliberate differences from INET, both because the standard is clearer
# than the code:
#
# * INET's `Ipv6AuthenticationHeader` is a stub that writes zero octets and
#   carries a `// TODO`. RFC 4302 section 2 gives the real layout, and this is
#   that layout. Its length octet counts four-octet units minus two, not eight-
#   octet units, which is why it does not share the shape above.
# * INET's `Ipv6EncapsulatingSecurityPayloadHeader` is the same stub, and it
#   writes a next-header octet first. RFC 4303 section 2 has no next-header
#   octet at the front of ESP at all — the next header travels in the trailer,
#   after the payload, because it is encrypted with it. This declares the
#   eight octets the RFC draws.
# ============================================================================

"Hop-by-Hop Options — RFC 8200 section 4.3, and the only header that must come first."
const IP_PROTOCOL_IPV6_HOP_BY_HOP = IpProtocol(0)
"Destination Options — RFC 8200 section 4.6."
const IP_PROTOCOL_IPV6_DESTINATION = IpProtocol(60)
"Authentication Header — RFC 4302."
const IP_PROTOCOL_IPV6_AUTHENTICATION = IpProtocol(51)
"Encapsulating Security Payload — RFC 4303."
const IP_PROTOCOL_IPV6_ESP = IpProtocol(50)

"The Segment Routing Header — RFC 8754. Routing type 0 was deprecated by RFC 5095."
const IPV6_ROUTING_TYPE_SEGMENT = 4

"""
    Ipv6HopByHopOptionsHeader(; next_header, options)

The Hop-by-Hop Options header — RFC 8200 section 4.3. Every router on the path
examines it, which is why it must be the first extension header.

`header_length` counts eight-octet units after the first eight, so the header
is always a multiple of eight octets and never shorter than eight. It derives
from the options the header carries.
"""
@header Ipv6HopByHopOptionsHeader begin
    next_header   :: IpProtocol
    header_length :: U8 = 0
        derive(cld(measure_header(h), 64) - 1)
    options       :: Options{Ipv6Option} = Ipv6Option[]
        until(Bytes(8) * header_length + Bytes(8))
    padding       :: Pad{Bytes(8), 0x00}
end

"""
    Ipv6DestinationOptionsHeader(; next_header, options)

The Destination Options header — RFC 8200 section 4.6. Only the destination
examines it, and otherwise it is the hop-by-hop header's twin.
"""
@header Ipv6DestinationOptionsHeader begin
    next_header   :: IpProtocol
    header_length :: U8 = 0
        derive(cld(measure_header(h), 64) - 1)
    options       :: Options{Ipv6Option} = Ipv6Option[]
        until(Bytes(8) * header_length + Bytes(8))
    padding       :: Pad{Bytes(8), 0x00}
end

"""
    Ipv6RoutingHeader(; next_header, segments_left, addresses, …)

The Segment Routing Header — RFC 8754 section 2. It lists the addresses a
datagram must visit, and `segments_left` says how many of them are still ahead.

The first four octets are what RFC 8200 section 4.4 gives every routing header;
the rest is what routing type 4 adds. Type 0 was deprecated by RFC 5095, and
type 2 belongs to Mobile IPv6.
"""
@header Ipv6RoutingHeader begin
    next_header   :: IpProtocol
    header_length :: U8 = 0
        derive(cld(measure_header(h), 64) - 1)
    routing_type  :: U8  = IPV6_ROUTING_TYPE_SEGMENT
    segments_left :: U8  = 0
    last_entry    :: U8  = 0
    flags         :: U8  = 0
    tag           :: U16 = 0
    addresses     :: Repeated{Ipv6Address} = Ipv6Address[]
        count(header_length ÷ 2)
end

"""
    Ipv6FragmentHeader(; next_header, fragment_offset, more_fragments, identification)

The Fragment header — RFC 8200 section 4.5, eight octets.

`fragment_offset` is in eight-octet units, as the field on the wire is. A
fragment that starts at byte 1480 carries 185 here, and
`measure_fragment_offset` gives the byte count back.
"""
@header Ipv6FragmentHeader begin
    next_header     :: IpProtocol
    reserved        :: U8   = 0
    fragment_offset :: U13  = 0
    reserved2       :: U2   = 0
    more_fragments  :: Bool = false
    identification  :: U32
end

"Where a fragment starts in the datagram, in bytes — the field counts eight-octet units."
measure_fragment_offset(h::Ipv6FragmentHeader) = 8 * Int(h.fragment_offset)

"""
    Ipv6AuthenticationHeader(; next_header, spi, sequence_number, integrity_check_value)

The Authentication Header — RFC 4302 section 2.

`payload_length` counts four-octet units and then subtracts two, which is the
one place in IPv6 where a header extension length is not in eight-octet units.
It derives from the integrity check value the header carries.
"""
@header Ipv6AuthenticationHeader begin
    next_header          :: IpProtocol
    payload_length       :: U8 = 1
        derive(cld(measure_header(h), 32) - 2)
    reserved             :: U16 = 0
    spi                  :: U32
    sequence_number      :: U32
    integrity_check_value :: Octets = UInt8[]
        length(Bytes(4) * payload_length - Bytes(4))
    padding              :: Pad{Bytes(4), 0x00}
end

"""
    Ipv6EncapsulatingSecurityPayloadHeader(; spi, sequence_number)

The Encapsulating Security Payload header — RFC 4303 section 2, eight octets.

It names no next header. ESP puts the next-header octet in its trailer, after
the payload, so that it is encrypted along with the payload.
"""
@header Ipv6EncapsulatingSecurityPayloadHeader begin
    spi             :: U32
    sequence_number :: U32
end
