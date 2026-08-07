# ============================================================================
# IPv4 — RFC 791, section 3.1.
#
# Twenty bytes, with `ihl` fixed at 5: this library declares no options, so
# every IPv4 header it builds is the minimum one. A header that carries options
# has an `ihl` above 5 and a tail whose width depends on that field, which is a
# variable-length codec and is deliberately out of scope.
#
# The first two bytes hold four fields, and `flags` and `frag_offset` split a
# byte boundary three bits in — which is the sort of thing a hand-written codec
# gets wrong once and then nobody notices.
# ============================================================================

const IPV4_VERSION = UInt8(4)
const IPV4_MIN_IHL = UInt8(5)              # 5 words of 32 bits = 20 bytes
const IPV4_HEADER_BYTES = 20
const IPV4_DEFAULT_TTL = UInt8(64)

# The three bits of the flags field, as a 3-bit value.
const IPV4_FLAG_RESERVED = UInt8(0b100)
const IPV4_FLAG_DF       = UInt8(0b010)    # do not fragment
const IPV4_FLAG_MF       = UInt8(0b001)    # more fragments

const IP_PROTOCOL_ICMP = IpProtocol(1)
const IP_PROTOCOL_IGMP = IpProtocol(2)
const IP_PROTOCOL_TCP  = IpProtocol(6)
const IP_PROTOCOL_UDP  = IpProtocol(17)

"""
    Ipv4Header(; total_length, protocol, src_address, dst_address, …)

The IPv4 header, 20 bytes. Every field but the four named above carries a
default, so the keyword form states what a datagram actually decides.

`header_checksum` is declared, never computed — the same choice INET's
`declared` checksum mode makes.
"""
@header Ipv4Header begin
    version         :: UInt8       | 4        = IPV4_VERSION
    ihl             :: UInt8       | 4        = IPV4_MIN_IHL
    dscp            :: UInt8       | 6        = 0x00
    ecn             :: UInt8       | 2        = 0x00
    total_length    :: UInt16
    identification  :: UInt16      | 16 | hex = 0x0000
    flags           :: UInt8       | 3        = 0x00
    frag_offset     :: UInt16      | 13 | dec = 0x0000
    ttl             :: UInt8                  = IPV4_DEFAULT_TTL
    protocol        :: IpProtocol
    header_checksum :: UInt16      | 16 | hex = 0x0000
    src_address     :: Ipv4Address
    dst_address     :: Ipv4Address
end
