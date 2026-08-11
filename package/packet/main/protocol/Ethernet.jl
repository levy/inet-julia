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

"The opcode of an IEEE 802.3 clause 31 PAUSE frame."
const ETHERNET_CONTROL_PAUSE = 0x0001

"The MAC control frames — one wire format, and the opcode says which."
abstract type EthernetControlMessage <: Fields end

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

# A plain struct is a complete header, and the corpus should still walk it.
register_header(EthernetMacHeader)

"""
    EthernetPhyHeader(; preamble, sfd)

The physical-layer preamble and start-frame delimiter, 8 bytes. Both fields
carry their constant as a default, so the header is built with no arguments.
"""
@header EthernetPhyHeader begin
    preamble :: U56 = ETHERNET_PREAMBLE
    sfd      :: U8  = ETHERNET_SFD
end

"""
    Ieee8021qTag(; tpid, pcp, dei, vid)

The 802.1Q VLAN tag, 4 bytes. `tpid` defaults to `0x8100`, which is the value
that makes the tag recognisable as one.
"""
@header Ieee8021qTag begin
    tpid :: EtherTypeOrLength = ETHERTYPE_VLAN
    pcp  :: U3                = 0
    dei  :: Bool              = false
    vid  :: U12
end

"""
    EthernetMacAddressFields(; destination, source)

The address pair on its own, 12 bytes. INET declares it as a chunk of its own
and then repeats its two lines inside the MAC header; here `EthernetMacHeader`
could embed it, and does not, because IEEE 802.3 clause 3.2 draws one header
with three fields rather than a header inside a header.
"""
@header EthernetMacAddressFields begin
    destination :: MacAddress
    source      :: MacAddress
end

"""
    EthernetTypeOrLengthField(; type_or_length)

The third field of the MAC header on its own, 2 bytes.
"""
@header EthernetTypeOrLengthField begin
    type_or_length :: EtherTypeOrLength
end

"""
    EthernetControlFrame(; op_code)

The MAC control frame, 2 bytes — IEEE 802.3 clause 31. It is the base of a
variant family: the opcode says which control frame this is.
"""
@header EthernetControlFrame <: EthernetControlMessage begin
    op_code :: U16
end

"""
    EthernetPauseFrame(; base, pause_time)

The PAUSE frame, 4 bytes. `pause_time` counts units of 512 bit times.
"""
@header EthernetPauseFrame <: EthernetControlMessage begin
    base       :: EthernetControlFrame =
                  EthernetControlFrame(op_code = ETHERNET_CONTROL_PAUSE)
    pause_time :: U16
end

list_variants(::Type{EthernetControlMessage}) = (EthernetPauseFrame,)
variant_base(::Type{EthernetControlMessage}) = EthernetControlFrame
matches_variant(::Type{EthernetPauseFrame}, base) = base.op_code == ETHERNET_CONTROL_PAUSE

"""
    EthernetFcs(; fcs)

The frame check sequence, 4 bytes, carried after the payload. INET's default
`fcsMode` is `declared`, which means the value is asserted rather than
computed; this library keeps that and computes nothing.
"""
@header EthernetFcs begin
    fcs :: U32 = 0
end
