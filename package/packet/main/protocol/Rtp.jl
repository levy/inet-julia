# ============================================================================
# The real-time transport protocol and its control protocol — RFC 3550.
#
# An RTP header is twelve octets and four more for each contributing source. An
# RTCP packet starts with the same four octets whatever it is, and the packet
# type says which of the four this one is.
#
# One difference from INET, and its own source argues for it.
# `RtpMpegPacketSerializer` writes a payload length and a picture type, four
# octets that RFC 2250 does not define. Directly above those two lines, the
# whole of RFC 2250 clause 3.4 sits commented out — the same four octets, laid
# out as the standard draws them. This declares the standard's layout, which is
# what the commented code was for.
# ============================================================================

const RTP_VERSION = 2

"The RTCP packet types — RFC 3550 clause 12.1."
const RTCP_SENDER_REPORT   = 200
const RTCP_RECEIVER_REPORT = 201
const RTCP_SOURCE_DESCRIPTION = 202
const RTCP_BYE             = 203
const RTCP_APPLICATION     = 204

"The source description item types — RFC 3550 clause 6.5."
const RTCP_SDES_END   = 0
const RTCP_SDES_CNAME = 1
const RTCP_SDES_NAME  = 2
const RTCP_SDES_EMAIL = 3
const RTCP_SDES_PHONE = 4
const RTCP_SDES_LOCATION = 5
const RTCP_SDES_TOOL  = 6
const RTCP_SDES_NOTE  = 7
const RTCP_SDES_PRIVATE = 8

"An RTP header without contributing sources is twelve octets — RFC 3550 clause 5.1."
const RTP_HEADER_BYTES = 12

"""
    RtpHeader(; payload_type, sequence_number, timestamp, ssrc, contributing_sources)

An RTP header — RFC 3550 clause 5.1. Twelve octets and four more for each
contributing source.

`marker` means what the payload profile says it means; for audio it usually
marks the first packet after a silence.
"""
@header RtpHeader begin
    version              :: U2 = RTP_VERSION
        check(version == RTP_VERSION)
    padding              :: Bool = false
    extension            :: Bool = false
    contributing_count   :: U4   = 0
        derive(Base.length(contributing_sources))
    marker               :: Bool = false
    payload_type         :: U7   = 0
    sequence_number      :: U16  = 0
    timestamp            :: U32  = 0
    ssrc                 :: U32  = 0
    contributing_sources :: Repeated{U32} = UInt32[]
        count(contributing_count)
end

"""
    RtpMpegHeader(; temporal_reference, picture_type, …)

The MPEG payload header, four octets — RFC 2250 clause 3.4.

`beginning_of_slice` and `end_of_slice` say whether this packet starts or ends
a slice, which is how a decoder knows what it can decode without waiting.
"""
@header RtpMpegHeader begin
    must_be_zero            :: U5   = 0
    two                     :: Bool = false
    temporal_reference      :: U10  = 0
    active_n                :: Bool = false
    new_picture_header      :: Bool = false
    sequence_header_present :: Bool = false
    beginning_of_slice      :: Bool = false
    end_of_slice            :: Bool = false
    picture_type            :: U3   = 0
    full_pel_backward       :: Bool = false
    backward_f_code         :: U3   = 0
    full_pel_forward        :: Bool = false
    forward_f_code          :: U3   = 0
end

# ---------- RTCP -------------------------------------------------------------

"The RTCP packets — one wire format, and the packet type says which."
abstract type RtcpPacket <: Fields end

"""
    RtcpCommon(; packet_type, count, length)

The four octets every RTCP packet starts with — RFC 3550 clause 6.4.1.

`length` counts thirty-two-bit words after the first, so a four-octet packet
carries zero. `count` means a different thing in each packet: reception reports
in a report, chunks in a source description, sources in a goodbye.
"""
@header RtcpCommon <: RtcpPacket begin
    version     :: U2 = RTP_VERSION
    padding     :: Bool = false
    count       :: U5  = 0
    packet_type :: U8  = RTCP_RECEIVER_REPORT
    length      :: U16 = 1
end

"""
    RtcpReceptionReport(; ssrc, fraction_lost, packets_lost, …)

One reception report block, twenty-four octets — RFC 3550 clause 6.4.1.
`packets_lost` is a signed twenty-four-bit count, so a receiver that got
duplicates reports a negative number.
"""
@header RtcpReceptionReport begin
    ssrc                  :: U32 = 0
    fraction_lost         :: U8  = 0
    packets_lost          :: I24 = 0
    sequence_number       :: U32 = 0
    jitter                :: U32 = 0
    last_sender_report    :: U32 = 0
    delay_since_last_report :: U32 = 0
end

"""
    RtcpSenderReport(; ssrc, ntp_timestamp, rtp_timestamp, reports, …)

A sender report — RFC 3550 clause 6.4.1. Twenty-eight octets and twenty-four
more for each reception report.
"""
@header RtcpSenderReport <: RtcpPacket begin
    base          :: RtcpCommon = RtcpCommon(packet_type = RTCP_SENDER_REPORT)
    ssrc          :: U32 = 0
    ntp_timestamp :: U64 = 0
    rtp_timestamp :: U32 = 0
    packet_count  :: U32 = 0
    byte_count    :: U32 = 0
    reports       :: Repeated{RtcpReceptionReport} = RtcpReceptionReport[]
end

"""
    RtcpReceiverReport(; ssrc, reports)

A receiver report — RFC 3550 clause 6.4.2. Eight octets and twenty-four more
for each reception report.
"""
@header RtcpReceiverReport <: RtcpPacket begin
    base    :: RtcpCommon = RtcpCommon(packet_type = RTCP_RECEIVER_REPORT)
    ssrc    :: U32 = 0
    reports :: Repeated{RtcpReceptionReport} = RtcpReceptionReport[]
end

"The source description items — one shape, and the type octet says which."
abstract type RtcpSdesItem <: Fields end

"""
    RtcpSdesCname(; content)

The canonical name item — RFC 3550 clause 6.5.1. Every source description
chunk must carry one.
"""
@header RtcpSdesCname <: RtcpSdesItem begin
    type    :: Constant{U8, RTCP_SDES_CNAME}
    length  :: U8 = 0
        derive(Base.length(content))
    content :: Octets = UInt8[]
        length(Bytes(length))
end

"""
    RtcpSdesItemRaw(; type, content)

A source description item this library does not model by name. It keeps its
type and its octets.
"""
@header RtcpSdesItemRaw <: RtcpSdesItem begin
    type    :: U8
    length  :: U8 = 0
        derive(Base.length(content))
    content :: Octets = UInt8[]
        length(Bytes(length))
end

list_options(::Type{RtcpSdesItem}) = (RtcpSdesCname,)
find_raw_option(::Type{RtcpSdesItem}) = RtcpSdesItemRaw
ends_option_list(::Type{RtcpSdesItem}, code) = code == RTCP_SDES_END

"""
    RtcpSourceDescription(; ssrc, items)

A source description packet — RFC 3550 clause 6.5. INET writes one chunk, so
this declares one: a source and the items that describe it.
"""
@header RtcpSourceDescription <: RtcpPacket begin
    base    :: RtcpCommon = RtcpCommon(packet_type = RTCP_SOURCE_DESCRIPTION,
                                       count = 1)
    ssrc    :: U32 = 0
    items   :: Options{RtcpSdesItem} = RtcpSdesItem[]
    padding2 :: Pad{Bytes(4), 0x00}
end

"""
    RtcpBye(; ssrc)

A goodbye packet, eight octets — RFC 3550 clause 6.6. A source sends it when it
stops.
"""
@header RtcpBye <: RtcpPacket begin
    base :: RtcpCommon = RtcpCommon(packet_type = RTCP_BYE, count = 1)
    ssrc :: U32 = 0
end

list_variants(::Type{RtcpPacket}) =
    (RtcpSenderReport, RtcpReceiverReport, RtcpSourceDescription, RtcpBye)
variant_base(::Type{RtcpPacket}) = RtcpCommon

matches_variant(::Type{RtcpSenderReport}, base)   = base.packet_type == RTCP_SENDER_REPORT
matches_variant(::Type{RtcpReceiverReport}, base) = base.packet_type == RTCP_RECEIVER_REPORT
matches_variant(::Type{RtcpSourceDescription}, base) =
    base.packet_type == RTCP_SOURCE_DESCRIPTION
matches_variant(::Type{RtcpBye}, base)            = base.packet_type == RTCP_BYE
