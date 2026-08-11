# ============================================================================
# Ethernet — IEEE 802.3, as it lies on the wire.
#
# Four chunks and one tag, in the order a frame carries them:
#
#   EthernetPhyHeader   8 B   preamble + start-frame delimiter
#   EthernetMacHeader  14 B   destination, source, type or length
#   Ieee8021qTag        4 B   the VLAN tag, when there is one
#   ...payload...
#   EthernetFcs         4 B   the frame check sequence, a trailer
#
# The PHY header is a chunk of its own because the PHY adds it, not the MAC.
# The VLAN tag is a chunk of its own for the same reason: it sits between the
# MAC header and the payload on the wire, so it is a field of neither.
#
# `EthernetMacHeader` is the plainest declaration in the library — no default,
# no expression, and therefore no macro. The struct alone is the format.
# ============================================================================

# ---------- constants --------------------------------------------------------

const MIN_ETHERNET_FRAME_BYTES = 64
const MAX_ETHERNET_FRAME_BYTES = 1526
const INTERFRAME_GAP_BITS      = 96
const JAM_SIGNAL_BYTES         = 4
const ETHERNET_PHY_HEADER_LEN_BYTES = 8       # preamble(7) + SFD(1)
const ETHERNET_PHY_ESD_LEN_BYTES    = 1       # 5B code, modelled symbolically
const ETHERNET_TXRATE_10MB          = 10_000_000

const ETHERNET_PREAMBLE = 0x55555555555555    # seven 0x55 octets
const ETHERNET_SFD      = 0xD5

const ETHERTYPE_IPV4 = EtherTypeOrLength(0x0800)
const ETHERTYPE_ARP  = EtherTypeOrLength(0x0806)
const ETHERTYPE_VLAN = EtherTypeOrLength(0x8100)
const ETHERTYPE_IPV6 = EtherTypeOrLength(0x86DD)

# ---------- the headers ------------------------------------------------------

"""
    EthernetMacHeader(destination, source, type_or_length)

The MAC header, 14 bytes. IEEE 802.3 clause 3.2 gives it three fields and
nothing else, so the struct gives it three fields and nothing else.

Clause 3.2.6 makes the third field one field with two readings: a value up to
1500 is a length, and 1536 or above is an EtherType. `EtherTypeOrLength`
answers `is_length` and `is_type`.
"""
struct EthernetMacHeader <: Fields
    destination    :: MacAddress
    source         :: MacAddress
    type_or_length :: EtherTypeOrLength
end

"""
    EthernetPhyHeader(; preamble, sfd)

The physical-layer preamble and start-frame delimiter, 8 bytes. Both fields
carry their constant as a default, so the header is built with no arguments.
"""
Base.@kwdef struct EthernetPhyHeader <: Fields
    preamble :: U56 = ETHERNET_PREAMBLE
    sfd      :: U8  = ETHERNET_SFD
end

"""
    Ieee8021qTag(; tpid, pcp, dei, vid)

The 802.1Q VLAN tag, 4 bytes. `tpid` defaults to `0x8100`, which is the value
that makes the tag recognisable as one.
"""
Base.@kwdef struct Ieee8021qTag <: Fields
    tpid :: EtherTypeOrLength = ETHERTYPE_VLAN
    pcp  :: U3                = 0
    dei  :: Bool              = false
    vid  :: U12
end

"""
    EthernetFcs(; fcs)

The frame check sequence, 4 bytes, carried after the payload. INET's default
`fcsMode` is `declared`, which means the value is asserted rather than
computed; this library keeps that and computes nothing.
"""
Base.@kwdef struct EthernetFcs <: Fields
    fcs :: U32 = 0
end
