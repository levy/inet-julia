# ============================================================================
# Ethernet — IEEE 802.3, as it lies on the wire.
#
# Four chunks and one tag, in the order a frame carries them:
#
#   EthernetPhyHeader   8 B   preamble + start-frame delimiter
#   EthernetMacHeader  14 B   destination, source, ethertype
#   Ieee8021qTag        4 B   the VLAN tag, when there is one
#   ...payload...
#   EthernetFcs         4 B   the frame check sequence, a trailer
#
# The PHY header is a chunk of its own because the PHY adds it, not the MAC —
# the same split INET makes in `EthernetCsmaPhy::encapsulate`. The VLAN tag is
# a chunk of its own for the same reason: it sits between the MAC header and
# the payload on the wire, so it is not a field of either.
# ============================================================================

# ---------- constants --------------------------------------------------------

const MIN_ETHERNET_FRAME_BYTES = 64
const MAX_ETHERNET_FRAME_BYTES = 1526
const INTERFRAME_GAP_BITS      = 96
const JAM_SIGNAL_BYTES         = 4
const ETHERNET_PHY_HEADER_LEN_BYTES = 8       # preamble(7) + SFD(1)
const ETHERNET_PHY_ESD_LEN_BYTES    = 1       # 5B code, modelled symbolically
const ETHERNET_TXRATE_10MB          = 10_000_000

const ETHERNET_PREAMBLE = UInt64(0x55555555555555)   # seven 0x55 octets
const ETHERNET_SFD      = UInt8(0xD5)

const ETHERTYPE_IPV4 = EtherType(0x0800)
const ETHERTYPE_ARP  = EtherType(0x0806)
const ETHERTYPE_VLAN = EtherType(0x8100)
const ETHERTYPE_IPV6 = EtherType(0x86DD)

# ---------- the headers ------------------------------------------------------

"""
    EthernetPhyHeader()

The physical-layer preamble and start-frame delimiter, 8 bytes. Both fields
carry their constant as a default, so the header is built with no arguments.
"""
@header EthernetPhyHeader begin
    preamble :: UInt64 | 56 | hex = ETHERNET_PREAMBLE
    sfd      :: UInt8  | 8  | hex = ETHERNET_SFD
end

"""
    EthernetMacHeader(dst, src, ethertype)

The MAC header, 14 bytes. An `Integer` converts into a `MacAddress` or an
`EtherType`, so `EthernetMacHeader(0x0a0000000002, 0x0a0000000001, 0x0800)`
builds one.
"""
@header EthernetMacHeader begin
    dst       :: MacAddress
    src       :: MacAddress
    ethertype :: EtherType
end

"""
    Ieee8021qTag(; tpid, pcp, dei, vid)

The 802.1Q VLAN tag, 4 bytes. `tpid` defaults to `0x8100`, which is the value
that makes the tag recognisable as one.
"""
@header Ieee8021qTag begin
    tpid :: EtherType             = ETHERTYPE_VLAN
    pcp  :: UInt8       | 3       = 0x00
    dei  :: Bool        | 1       = false
    vid  :: UInt16      | 12
end

"""
    EthernetFcs(fcs)

The frame check sequence, 4 bytes, carried after the payload. INET's default
`fcsMode` is `declared`, which means the value is asserted rather than
computed; this library keeps that and computes nothing.
"""
@header EthernetFcs begin
    fcs :: UInt32 | 32 | hex = 0x00000000
end
