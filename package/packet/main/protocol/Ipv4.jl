# ============================================================================
# IPv4 — RFC 791, section 3.1.
#
# Twenty bytes with no options, and `ihl` counts what there is: it derives from
# the header's own width, so a datagram that carries options gets the right
# value without anyone setting it.
#
# The option list runs to the end of the header, which is what `until` says,
# and `padding` takes the header up to a whole number of 32-bit words. An
# option this library does not know survives in `Ipv4OptionRaw`.
#
# The declaration follows RFC 791 and not INET. Two consequences:
#
#   * the three flag bits are three fields, because §3.1 names them one at a
#     time — `Bit 1: (DF)`, `Bit 2: (MF)` — rather than as a 3-bit number;
#   * the first byte of the second word is `dscp` and `ecn`, per RFC 2474 and
#     RFC 3168, rather than RFC 791's original `Type of Service`.
#
# `flags` and `fragment_offset` split a byte boundary three bits in, which is
# the sort of thing a hand-written codec gets wrong once and then nobody
# notices.
# ============================================================================

const IPV4_VERSION      = 4
const IPV4_MIN_IHL      = 5                # 5 words of 32 bits = 20 bytes
const IPV4_HEADER_BYTES = 20
const IPV4_DEFAULT_TTL  = 64

const IP_PROTOCOL_ICMP = IpProtocol(1)
const IP_PROTOCOL_IGMP = IpProtocol(2)
const IP_PROTOCOL_TCP  = IpProtocol(6)
const IP_PROTOCOL_UDP  = IpProtocol(17)

"""
    Ipv4Header(; total_length, protocol, source, destination, …)

The IPv4 header, 20 bytes. Every field but the four named above carries the
default RFC 791 gives it, so the keyword form states what a datagram actually
decides.

`total_length` counts the header and the payload together, which the header
cannot see, so the IP module sets it. `header_checksum` is declared, never
computed — the same choice INET's `declared` checksum mode makes.
"""
@header Ipv4Header begin
    version         :: U4         = IPV4_VERSION
        check(version == IPV4_VERSION)
    ihl             :: U4         = IPV4_MIN_IHL
        derive(cld(measure_header(h), 32))
    dscp            :: U6         = 0
    ecn             :: U2         = 0
    total_length    :: U16
    identification  :: U16        = 0
    reserved        :: Bool       = false
    dont_fragment   :: Bool       = false
    more_fragments  :: Bool       = false
    fragment_offset :: U13        = 0
    time_to_live    :: U8         = IPV4_DEFAULT_TTL
    protocol        :: IpProtocol
    header_checksum :: Checksum16 = 0
        derive(checksum_mode == CHECKSUM_COMPUTED ? compute_internet_checksum(h, :header_checksum) :
                                                    header_checksum)
    source          :: Ipv4Address
    destination     :: Ipv4Address
    options         :: Options{Ipv4Option} = Ipv4Option[]
        until(Bytes(4) * ihl)
    padding         :: Pad{Bytes(4), 0x00}
    checksum_mode   :: Model{ChecksumMode} = CHECKSUM_DECLARED
    @check ihl >= IPV4_MIN_IHL
end
