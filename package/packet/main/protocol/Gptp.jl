# ============================================================================
# The generalized precision time protocol — IEEE 802.1AS, which is the profile
# IEEE 1588 calls PTP.
#
# Every message starts with the same thirty-four octets, and the message type
# — the low nibble of the first octet — says what follows them. That is the
# variant shape again.
#
# Three small structures repeat across the members, and each is a header of its
# own rather than a comment:
#
# * `GptpTimestamp`, ten octets, is IEEE 1588 clause 5.3.3: forty-eight bits of
#   seconds and thirty-two of nanoseconds.
# * `GptpPortIdentity`, ten octets, is clause 5.3.5: a clock identity and a
#   port number.
# * `GptpScaledNanoseconds`, twelve octets, is clause 5.3.2: one signed
#   ninety-six-bit quantity in units of 2^-16 nanoseconds, written high half
#   first.
#
# `message_length` counts the whole message. It is a field the sender sets,
# not one this library derives: it sits in the shared base, and a base cannot
# measure the member that embeds it. Each member's declaration gives it the
# right default.
# ============================================================================

const GPTP_TYPE_SYNC                   = 0x0
const GPTP_TYPE_PDELAY_REQUEST         = 0x2
const GPTP_TYPE_PDELAY_RESPONSE        = 0x3
const GPTP_TYPE_FOLLOW_UP              = 0x8
const GPTP_TYPE_PDELAY_RESPONSE_FOLLOW_UP = 0xa
const GPTP_TYPE_ANNOUNCE               = 0xb

"The flags octet — IEEE 802.1AS clause 10.6.2.2.8."
const GPTP_FLAG_ALTERNATE_MASTER = 0x0001
const GPTP_FLAG_TWO_STEP         = 0x0002

"The follow-up information type-length-value — IEEE 802.1AS clause 11.4.4.3."
const GPTP_FOLLOW_UP_INFORMATION_TLV = 0x03
const GPTP_ORGANIZATION_ID           = 0x0080c2
const GPTP_ORGANIZATION_SUBTYPE      = 1

"The common header, and the size of each message that follows it."
const GPTP_HEADER_BYTES                    = 34
const GPTP_SYNC_BYTES                      = 44
const GPTP_FOLLOW_UP_BYTES                 = 76
const GPTP_PDELAY_REQUEST_BYTES            = 54
const GPTP_PDELAY_RESPONSE_BYTES           = 54
const GPTP_PDELAY_RESPONSE_FOLLOW_UP_BYTES = 54
const GPTP_ANNOUNCE_BYTES                  = 64

"""
    GptpTimestamp(; seconds, nanoseconds)

A timestamp, ten octets — IEEE 1588 clause 5.3.3.
"""
@header GptpTimestamp begin
    seconds     :: U48 = 0
    nanoseconds :: U32 = 0
end

"""
    GptpPortIdentity(; clock_identity, port_number)

The identity of a port, ten octets — IEEE 1588 clause 5.3.5.
"""
@header GptpPortIdentity begin
    clock_identity :: U64 = 0
    port_number    :: U16 = 0
end

"""
    GptpScaledNanoseconds(; upper, lower)

A signed ninety-six-bit time interval in units of 2^-16 nanoseconds — IEEE 1588
clause 5.3.2. No integer of that width exists, so it is written as its high
thirty-two bits and its low sixty-four.
"""
@header GptpScaledNanoseconds begin
    upper :: U32 = 0
    lower :: U64 = 0
end

"The gPTP messages — one wire format, and the message type says which."
abstract type GptpMessage <: Fields end

"""
    GptpCommon(; message_type, message_length, source_port_identity, …)

The thirty-four octets every gPTP message starts with — IEEE 1588 clause 13.3.
Every member embeds it, and a reader looks at its message type to decide which
member arrived.
"""
@header GptpCommon <: GptpMessage begin
    major_sdo_id          :: U4  = 1
    message_type          :: U4  = GPTP_TYPE_SYNC
    minor_version         :: U4  = 1
    version               :: U4  = 2
    message_length        :: U16 = GPTP_HEADER_BYTES
    domain_number         :: U8  = 0
    minor_sdo_id          :: U8  = 0
    flags                 :: U16 = 0
    correction            :: I64 = 0
    message_type_specific :: U32 = 0
    source_port_identity  :: GptpPortIdentity = GptpPortIdentity()
    sequence_id           :: U16 = 0
    control               :: U8  = 0
    log_message_interval  :: U8  = 0
end

"""
    GptpSync(; source_port_identity, sequence_id, …)

A Sync message, forty-four octets — IEEE 802.1AS clause 11.4.2. A two-step port
leaves the origin timestamp zero and sends the time in the Follow_Up that
follows.
"""
@header GptpSync <: GptpMessage begin
    base             :: GptpCommon = GptpCommon(message_type = GPTP_TYPE_SYNC,
                                                message_length = GPTP_SYNC_BYTES,
                                                flags = GPTP_FLAG_TWO_STEP)
    origin_timestamp :: GptpTimestamp = GptpTimestamp()
end

"""
    GptpFollowUpInformationTlv(; rate_offset, time_base_indicator, …)

The follow-up information type-length-value, thirty-two octets — IEEE 802.1AS
clause 11.4.4.3. It carries the rate the grandmaster runs at relative to this
clock.
"""
@header GptpFollowUpInformationTlv begin
    tlv_type              :: U16 = GPTP_FOLLOW_UP_INFORMATION_TLV
    length                :: U16 = 28
    organization_id       :: U24 = GPTP_ORGANIZATION_ID
    organization_subtype  :: U24 = GPTP_ORGANIZATION_SUBTYPE
    rate_offset           :: U32 = 0
    time_base_indicator   :: U16 = 0
    last_phase_change     :: GptpScaledNanoseconds = GptpScaledNanoseconds()
    last_frequency_change :: I32 = 0
end

"""
    GptpFollowUp(; precise_origin_timestamp, follow_up_information, …)

A Follow_Up message, seventy-six octets — IEEE 802.1AS clause 11.4.4. It
carries the time the Sync before it actually left.
"""
@header GptpFollowUp <: GptpMessage begin
    base                     :: GptpCommon =
        GptpCommon(message_type = GPTP_TYPE_FOLLOW_UP,
                   message_length = GPTP_FOLLOW_UP_BYTES)
    precise_origin_timestamp :: GptpTimestamp = GptpTimestamp()
    follow_up_information    :: GptpFollowUpInformationTlv = GptpFollowUpInformationTlv()
end

"""
    GptpPdelayReq(; source_port_identity, sequence_id, …)

A Pdelay_Req message, fifty-four octets — IEEE 802.1AS clause 11.4.5.

The clause reserves its last twenty octets, and they sit where the response
puts a timestamp and a port identity. They are declared with those widths and
sent as zeros, which is what the clause requires.
"""
@header GptpPdelayReq <: GptpMessage begin
    base                   :: GptpCommon =
        GptpCommon(message_type = GPTP_TYPE_PDELAY_REQUEST,
                   message_length = GPTP_PDELAY_REQUEST_BYTES)
    reserved_timestamp     :: GptpTimestamp = GptpTimestamp()
    reserved_port_identity :: GptpPortIdentity = GptpPortIdentity()
end

"""
    GptpPdelayResp(; request_receipt_timestamp, requesting_port_identity, …)

A Pdelay_Resp message, fifty-four octets — IEEE 802.1AS clause 11.4.6.
"""
@header GptpPdelayResp <: GptpMessage begin
    base                      :: GptpCommon =
        GptpCommon(message_type = GPTP_TYPE_PDELAY_RESPONSE,
                   message_length = GPTP_PDELAY_RESPONSE_BYTES)
    request_receipt_timestamp :: GptpTimestamp = GptpTimestamp()
    requesting_port_identity  :: GptpPortIdentity = GptpPortIdentity()
end

"""
    GptpPdelayRespFollowUp(; response_origin_timestamp, requesting_port_identity, …)

A Pdelay_Resp_Follow_Up message, fifty-four octets — IEEE 802.1AS clause
11.4.7. The two timestamps and the two that the requester holds are what make
the path delay measurable.
"""
@header GptpPdelayRespFollowUp <: GptpMessage begin
    base                      :: GptpCommon =
        GptpCommon(message_type = GPTP_TYPE_PDELAY_RESPONSE_FOLLOW_UP,
                   message_length = GPTP_PDELAY_RESPONSE_FOLLOW_UP_BYTES)
    response_origin_timestamp :: GptpTimestamp = GptpTimestamp()
    requesting_port_identity  :: GptpPortIdentity = GptpPortIdentity()
end

"""
    GptpAnnounce(; grandmaster_identity, steps_removed, …)

An Announce message, sixty-four octets — IEEE 802.1AS clause 10.6.3. It is what
the best master clock algorithm reads to choose a grandmaster.
"""
@header GptpAnnounce <: GptpMessage begin
    base                     :: GptpCommon =
        GptpCommon(message_type = GPTP_TYPE_ANNOUNCE,
                   message_length = GPTP_ANNOUNCE_BYTES)
    origin_timestamp         :: GptpTimestamp = GptpTimestamp()
    current_utc_offset       :: U16 = 0
    reserved                 :: U8  = 0
    grandmaster_priority1    :: U8  = 0
    grandmaster_clock_quality :: U32 = 0
    grandmaster_priority2    :: U8  = 0
    grandmaster_identity     :: U64 = 0
    steps_removed            :: U16 = 0
    time_source              :: U8  = 0
end

list_variants(::Type{GptpMessage}) =
    (GptpSync, GptpFollowUp, GptpPdelayReq, GptpPdelayResp,
     GptpPdelayRespFollowUp, GptpAnnounce)
variant_base(::Type{GptpMessage}) = GptpCommon

matches_variant(::Type{GptpSync}, base)     = base.message_type == GPTP_TYPE_SYNC
matches_variant(::Type{GptpFollowUp}, base) = base.message_type == GPTP_TYPE_FOLLOW_UP
matches_variant(::Type{GptpPdelayReq}, base) =
    base.message_type == GPTP_TYPE_PDELAY_REQUEST
matches_variant(::Type{GptpPdelayResp}, base) =
    base.message_type == GPTP_TYPE_PDELAY_RESPONSE
matches_variant(::Type{GptpPdelayRespFollowUp}, base) =
    base.message_type == GPTP_TYPE_PDELAY_RESPONSE_FOLLOW_UP
matches_variant(::Type{GptpAnnounce}, base) = base.message_type == GPTP_TYPE_ANNOUNCE
