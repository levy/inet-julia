# ============================================================================
# IPv6 — RFC 8200, section 3.
#
# Forty bytes, and no version of the base header is longer: an option travels
# in an extension header of its own, after this one. That makes IPv6 the first
# header in this library with a field no `UInt64` can hold — an address is 128
# bits — which is why it is the proof of the wide field-value protocol.
#
# The field ORDER below is the order `Ipv6HeaderSerializer.cc` writes, not the
# order `Ipv6Header.msg` declares. The two disagree: the message file lists the
# addresses second and third, and the wire puts them last. The serializer is
# the wire format; a port that reads the message file alone gets this header
# wrong.
#
# `traffic_class` is one 8-bit field, as the serializer writes it. INET splits
# it into a 6-bit DSCP and a 2-bit ECN through accessors rather than fields,
# and `ipv6_dscp` and `ipv6_ecn` below do the same.
#
# The version check is `Ipv6HeaderSerializer.cc`'s `markIncorrect()`: a header
# whose version is not 6 still comes back, marked, so `peek` refuses it until
# the caller passes `incorrect = true`.
# ============================================================================

const IPV6_VERSION      = UInt8(6)
const IPV6_HEADER_BYTES = 40
const IPV6_DEFAULT_HOP_LIMIT = UInt8(64)

"No next header follows — RFC 8200 calls this protocol 59."
const IP_PROTOCOL_NONE = IpProtocol(59)
const IP_PROTOCOL_IPV6_ROUTING  = IpProtocol(43)
const IP_PROTOCOL_IPV6_FRAGMENT = IpProtocol(44)
const IP_PROTOCOL_ICMPV6        = IpProtocol(58)

"""
    Ipv6Header(; payload_length, next_header, src_address, dst_address, …)

The IPv6 base header, 40 bytes. Every field but the four named above carries a
default, so the keyword form states what a datagram actually decides.

`payload_length` counts the bytes after this header, extension headers
included. It is not the length of this header, and it is not the length of the
datagram.
"""
@header Ipv6Header begin
    version        :: UInt8       | 4  | check(version == IPV6_VERSION) = IPV6_VERSION
    traffic_class  :: UInt8       | 8        = 0x00
    flow_label     :: UInt32      | 20 | hex = 0x00000
    payload_length :: UInt16
    next_header    :: IpProtocol
    hop_limit      :: UInt8                  = IPV6_DEFAULT_HOP_LIMIT
    src_address    :: Ipv6Address
    dst_address    :: Ipv6Address
end

"The six differentiated-services bits of the traffic class."
ipv6_dscp(h::Ipv6Header) = (h.traffic_class >> 2) & 0x3f

"The two explicit-congestion-notification bits of the traffic class."
ipv6_ecn(h::Ipv6Header) = h.traffic_class & 0x03

"The traffic class that a differentiated-services code point and an ECN make."
ipv6_traffic_class(dscp::Integer, ecn::Integer) = UInt8((UInt8(dscp) << 2) | UInt8(ecn))
