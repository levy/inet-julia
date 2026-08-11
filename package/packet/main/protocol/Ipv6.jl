# ============================================================================
# IPv6 — RFC 8200, section 3.
#
# Forty bytes, and no version of the base header is longer: an option travels
# in an extension header of its own, after this one. That makes IPv6 the first
# format in this library with a field no `UInt64` can hold — an address is 128
# bits — which is why it proves the wide half of the value protocol.
#
# The field ORDER below is the order RFC 8200 draws, which is also the order
# `Ipv6HeaderSerializer.cc` writes. It is NOT the order `Ipv6Header.msg`
# declares: the message file lists the addresses second and third. A port that
# reads the message file alone gets this header wrong.
#
# `traffic_class` is one 8-bit field, as the standard draws it. RFC 2474 and
# RFC 3168 split it into a 6-bit DSCP and a 2-bit ECN, and `split_dscp` and
# `split_ecn` read those out without making them fields.
# ============================================================================

const IPV6_VERSION           = 6
const IPV6_HEADER_BYTES      = 40
const IPV6_DEFAULT_HOP_LIMIT = 64

"No next header follows — RFC 8200 calls this protocol 59."
const IP_PROTOCOL_NONE          = IpProtocol(59)
const IP_PROTOCOL_IPV6_ROUTING  = IpProtocol(43)
const IP_PROTOCOL_IPV6_FRAGMENT = IpProtocol(44)
const IP_PROTOCOL_ICMPV6        = IpProtocol(58)

"""
    Ipv6Header(; payload_length, next_header, source, destination, …)

The IPv6 base header, 40 bytes.

`payload_length` counts the bytes after this header, extension headers
included. It is not the length of this header, and it is not the length of the
datagram, so the IP module sets it.
"""
@header Ipv6Header begin
    version        :: U4  = IPV6_VERSION
        check(version == IPV6_VERSION)
    traffic_class  :: U8  = 0
    flow_label     :: U20 = 0
    payload_length :: U16
    next_header    :: IpProtocol
    hop_limit      :: U8  = IPV6_DEFAULT_HOP_LIMIT
    source         :: Ipv6Address
    destination    :: Ipv6Address
end

"The six differentiated-services bits of the traffic class — RFC 2474."
split_dscp(h::Ipv6Header) = U6((UInt8(h.traffic_class) >> 2) & 0x3f)

"The two explicit-congestion-notification bits of the traffic class — RFC 3168."
split_ecn(h::Ipv6Header) = U2(UInt8(h.traffic_class) & 0x03)

"The traffic class that a differentiated-services code point and an ECN make."
join_traffic_class(dscp::Integer, ecn::Integer) = U8((UInt8(dscp) << 2) | UInt8(ecn))
