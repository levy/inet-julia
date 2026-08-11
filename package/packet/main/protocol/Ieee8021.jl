# ============================================================================
# The IEEE 802.1 tag headers.
#
# A tag sits between the MAC addresses and the payload, and every one of them
# comes in two shapes:
#
#   *TpidHeader   the tag with its own protocol identifier in front, which is
#                 how it looks when it follows the address pair
#   *EpdHeader    the tag with the ethertype-or-length of what FOLLOWS it,
#                 which is how it looks when another tag follows
#
# INET declares both, and so does this: they are two wire formats, not one
# format read two ways.
# ============================================================================

const ETHERTYPE_MACSEC = EtherTypeOrLength(0x88E5)   # IEEE 802.1AE
const ETHERTYPE_RTAG   = EtherTypeOrLength(0xF1C1)   # IEEE 802.1CB

# ---------- 802.1Q — the VLAN tag --------------------------------------------

"""
    Ieee8021qTagTpidHeader(; tpid, pcp, dei, vid)

The 802.1Q tag with its protocol identifier, 4 bytes. `Ieee8021qTag` in
`Ethernet.jl` is the same four bytes; this is the name INET gives the shape
that carries the identifier.
"""
@header Ieee8021qTagTpidHeader begin
    tpid :: EtherTypeOrLength = ETHERTYPE_VLAN
    pcp  :: U3                = 0
    dei  :: Bool              = false
    vid  :: U12
end

"""
    Ieee8021qTagEpdHeader(; pcp, dei, vid, type_or_length)

The 802.1Q tag that names what follows it, 4 bytes.
"""
@header Ieee8021qTagEpdHeader begin
    pcp            :: U3   = 0
    dei            :: Bool = false
    vid            :: U12
    type_or_length :: EtherTypeOrLength
end

# ---------- 802.1AE — MACsec -------------------------------------------------

"""
    Ieee8021aeTagTpidHeader(; tci_an, sl, pn)

The MACsec SecTAG with its protocol identifier, 8 bytes. INET does not carry
the optional 64-bit Secure Channel Identifier, and neither does this.
"""
@header Ieee8021aeTagTpidHeader begin
    tpid   :: Constant{EtherTypeOrLength, 0x88E5}
    tci_an :: U8  = 0
    sl     :: U8  = 0
    pn     :: U32 = 0
end

"""
    Ieee8021aeTagEpdHeader(; tci_an, sl, pn, type_or_length)

The MACsec SecTAG that names what follows it, 8 bytes.
"""
@header Ieee8021aeTagEpdHeader begin
    tci_an         :: U8  = 0
    sl             :: U8  = 0
    pn             :: U32 = 0
    type_or_length :: EtherTypeOrLength
end

# ---------- 802.1CB — the redundancy tag -------------------------------------

"""
    Ieee8021rTagTpidHeader(; sequence_number)

The 802.1CB R-TAG with its protocol identifier, 6 bytes. The two reserved
octets are zero, and the standard says so rather than the model.
"""
@header Ieee8021rTagTpidHeader begin
    tpid            :: Constant{EtherTypeOrLength, 0xF1C1}
    reserved        :: Constant{U16, 0x0000}
    sequence_number :: U16
end

"""
    Ieee8021rTagEpdHeader(; sequence_number, type_or_length)

The 802.1CB R-TAG that names what follows it, 6 bytes.
"""
@header Ieee8021rTagEpdHeader begin
    reserved        :: Constant{U16, 0x0000}
    sequence_number :: U16
    type_or_length  :: EtherTypeOrLength
end

# ---------- 802 — the ethertype protocol discrimination header ---------------

"""
    Ieee802EpdHeader(; ether_type)

Two bytes that name the protocol above, and nothing else.
"""
@header Ieee802EpdHeader begin
    ether_type :: EtherTypeOrLength
end
