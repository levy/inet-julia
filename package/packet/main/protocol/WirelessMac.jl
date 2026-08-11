# ============================================================================
# The wireless MAC protocols INET carries: B-MAC, X-MAC and its CSMA/CA MAC.
#
# None of the three has a standard wire format. B-MAC and X-MAC come from
# research papers that describe the protocol and not the octets, and the
# CSMA/CA MAC is INET's own. INET's serializer is therefore the specification,
# as it is for the headers in `SimulationHeader.jl`.
#
# All three share the shape those headers have. A type octet says which frame
# this is, a length field says how long the header is, and whatever the named
# fields do not use is filler up to that length. The length is a module
# parameter in INET, so a model asks for a header longer than its fields need.
#
# The length field sits in each member rather than in the shared base, so that
# it can derive from the member's own width. What the base carries is what a
# reader needs to choose a member, which is the type octet alone.
# ============================================================================

# ---------- B-MAC ------------------------------------------------------------

const BMAC_PREAMBLE = 191
const BMAC_DATA     = 192
const BMAC_ACK      = 193

"The B-MAC frames — one wire format, and the type octet says which."
abstract type BMacHeader <: Fields end

"""
    BMacCommon(; type)

The one octet a B-MAC reader looks at to decide which frame arrived.
"""
@header BMacCommon <: BMacHeader begin
    type :: U8 = BMAC_PREAMBLE
end

"""
    BMacControlFrame(; type, source, destination, filler)

A B-MAC preamble or acknowledgement. Fifteen octets of named fields, and the
length field says how many more the model asked for.
"""
@header BMacControlFrame <: BMacHeader begin
    base          :: BMacCommon = BMacCommon(type = BMAC_PREAMBLE)
    header_length :: U16 = 120
        derive(measure_header(h))
    source        :: MacAddress
    destination   :: MacAddress
    filler        :: Octets = UInt8[]
        until(Bits(header_length))
end

"""
    BMacDataFrameHeader(; source, destination, sequence_id, network_protocol, filler)

A B-MAC data frame header. It adds a sequence number, which is how a receiver
drops a duplicate, and the protocol of what follows.
"""
@header BMacDataFrameHeader <: BMacHeader begin
    base             :: BMacCommon = BMacCommon(type = BMAC_DATA)
    header_length    :: U16 = 200
        derive(measure_header(h))
    source           :: MacAddress
    destination      :: MacAddress
    sequence_id      :: U64 = 0
    network_protocol :: U16 = 0
    filler           :: Octets = UInt8[]
        until(Bits(header_length))
end

"""
    BMacUnknownFrame(; type, filler)

A B-MAC frame whose type this library does not model. It keeps the length and
the octets, so the frame round-trips and the reader lands where the next one
starts.
"""
@header BMacUnknownFrame <: BMacHeader begin
    base          :: BMacCommon
    header_length :: U16 = 24
        derive(measure_header(h))
    filler        :: Octets = UInt8[]
        until(Bits(header_length))
end

list_variants(::Type{BMacHeader}) = (BMacDataFrameHeader, BMacControlFrame)
variant_base(::Type{BMacHeader}) = BMacCommon
variant_fallback(::Type{BMacHeader}) = BMacUnknownFrame

matches_variant(::Type{BMacDataFrameHeader}, base) = base.type == BMAC_DATA
matches_variant(::Type{BMacControlFrame}, base) =
    base.type == BMAC_PREAMBLE || base.type == BMAC_ACK

# ---------- X-MAC ------------------------------------------------------------

const XMAC_PREAMBLE = 191
const XMAC_DATA     = 192
const XMAC_ACK      = 193

"The X-MAC frames. X-MAC is B-MAC with a shortened preamble, and the same octets."
abstract type XMacHeader <: Fields end

"""
    XMacCommon(; type)

The one octet an X-MAC reader looks at to decide which frame arrived.
"""
@header XMacCommon <: XMacHeader begin
    type :: U8 = XMAC_PREAMBLE
end

"""
    XMacControlFrame(; type, source, destination, filler)

An X-MAC preamble or acknowledgement.
"""
@header XMacControlFrame <: XMacHeader begin
    base          :: XMacCommon = XMacCommon(type = XMAC_PREAMBLE)
    header_length :: U16 = 120
        derive(measure_header(h))
    source        :: MacAddress
    destination   :: MacAddress
    filler        :: Octets = UInt8[]
        until(Bits(header_length))
end

"""
    XMacDataFrameHeader(; source, destination, sequence_id, network_protocol, filler)

An X-MAC data frame header.
"""
@header XMacDataFrameHeader <: XMacHeader begin
    base             :: XMacCommon = XMacCommon(type = XMAC_DATA)
    header_length    :: U16 = 200
        derive(measure_header(h))
    source           :: MacAddress
    destination      :: MacAddress
    sequence_id      :: U64 = 0
    network_protocol :: U16 = 0
    filler           :: Octets = UInt8[]
        until(Bits(header_length))
end

"""
    XMacUnknownFrame(; type, filler)

An X-MAC frame whose type this library does not model.
"""
@header XMacUnknownFrame <: XMacHeader begin
    base          :: XMacCommon
    header_length :: U16 = 24
        derive(measure_header(h))
    filler        :: Octets = UInt8[]
        until(Bits(header_length))
end

list_variants(::Type{XMacHeader}) = (XMacDataFrameHeader, XMacControlFrame)
variant_base(::Type{XMacHeader}) = XMacCommon
variant_fallback(::Type{XMacHeader}) = XMacUnknownFrame

matches_variant(::Type{XMacDataFrameHeader}, base) = base.type == XMAC_DATA
matches_variant(::Type{XMacControlFrame}, base) =
    base.type == XMAC_PREAMBLE || base.type == XMAC_ACK

# ---------- the CSMA/CA MAC --------------------------------------------------

const CSMA_DATA = 1
const CSMA_ACK  = 2

"The CSMA/CA MAC frames — one wire format, and the type octet says which."
abstract type CsmaCaMacHeader <: Fields end

"""
    CsmaCaMacCommon(; type)

The one octet a CSMA/CA reader looks at to decide which frame arrived.
"""
@header CsmaCaMacCommon <: CsmaCaMacHeader begin
    type :: U8 = CSMA_DATA
end

"""
    CsmaCaMacAckHeader(; receiver, transmitter, filler)

An acknowledgement, fourteen octets. The receiver address comes first, which is
what INET's serializer writes.
"""
@header CsmaCaMacAckHeader <: CsmaCaMacHeader begin
    base          :: CsmaCaMacCommon = CsmaCaMacCommon(type = CSMA_ACK)
    header_length :: U8 = 14
        derive(measure_header(h) ÷ 8)
    receiver      :: MacAddress
    transmitter   :: MacAddress
    filler        :: Octets = UInt8[]
        until(Bytes(header_length))
end

"""
    CsmaCaMacDataHeader(; receiver, transmitter, network_protocol, priority, filler)

A data frame header, seventeen octets. `priority` is the IEEE 802.1D user
priority.
"""
@header CsmaCaMacDataHeader <: CsmaCaMacHeader begin
    base             :: CsmaCaMacCommon = CsmaCaMacCommon(type = CSMA_DATA)
    header_length    :: U8 = 17
        derive(measure_header(h) ÷ 8)
    receiver         :: MacAddress
    transmitter      :: MacAddress
    network_protocol :: U16 = 0
    priority         :: U8  = 0
    filler           :: Octets = UInt8[]
        until(Bytes(header_length))
end

"""
    CsmaCaMacTrailer(; fcs)

The four octets of frame check sequence that follow a CSMA/CA frame.
"""
@header CsmaCaMacTrailer begin
    fcs      :: U32 = 0
    fcs_mode :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

list_variants(::Type{CsmaCaMacHeader}) = (CsmaCaMacDataHeader, CsmaCaMacAckHeader)
variant_base(::Type{CsmaCaMacHeader}) = CsmaCaMacCommon

matches_variant(::Type{CsmaCaMacDataHeader}, base) = base.type == CSMA_DATA
matches_variant(::Type{CsmaCaMacAckHeader}, base)  = base.type == CSMA_ACK
