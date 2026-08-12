# ============================================================================
# The stream control transmission protocol — RFC 4960.
#
# SCTP is type-length-value all the way down, and it is the first format in the
# inventory that is TLV at three levels: a packet is a list of chunks, a chunk
# may carry a list of parameters, and a parameter may carry a list of causes.
#
# Two things separate it from every other option list here.
#
#   * **The code is sixteen bits, not eight.** A parameter and an error cause
#     both name themselves with two octets, which is what `measure_option_code`
#     is for. A chunk names itself with one, so a chunk is a variant and not an
#     option.
#   * **Every element pads itself to a multiple of four, and its length field
#     does NOT count the padding** — RFC 4960 clause 3.2. So a length is derived
#     from the fields it covers rather than from the header's own width, and a
#     `Pad{4}` field after them reaches the boundary. That is the one place a
#     length and a width are different numbers.
#
# The checksum is CRC32c — RFC 4960 clause 6.8 — not the internet checksum every
# other transport here uses. It is declared as a field the sender sets, as the
# others are, so that a capture keeps whatever arrived.
# ============================================================================

"The common header is twelve octets — RFC 4960 clause 3.1."
const SCTP_COMMON_HEADER_BYTES = 12

"Every chunk and every parameter starts with four octets — RFC 4960 clause 3.2."
const SCTP_CHUNK_HEADER_BYTES     = 4
const SCTP_PARAMETER_HEADER_BYTES = 4

"The chunk types — RFC 4960 clause 3.2, with the extensions INET carries."
const SCTP_DATA              = 0
const SCTP_INIT              = 1
const SCTP_INIT_ACK          = 2
const SCTP_SACK              = 3
const SCTP_HEARTBEAT         = 4
const SCTP_HEARTBEAT_ACK     = 5
const SCTP_ABORT             = 6
const SCTP_SHUTDOWN          = 7
const SCTP_SHUTDOWN_ACK      = 8
const SCTP_ERROR             = 9
const SCTP_COOKIE_ECHO       = 10
const SCTP_COOKIE_ACK        = 11
const SCTP_SHUTDOWN_COMPLETE = 14
const SCTP_AUTH              = 15
const SCTP_NR_SACK           = 16
const SCTP_FORWARD_TSN       = 192

"The parameter types — RFC 4960 clause 3.3.2.1, RFC 3758 and RFC 4895."
const SCTP_PARAMETER_HEARTBEAT_INFO      = 1
const SCTP_PARAMETER_IPV4_ADDRESS        = 5
const SCTP_PARAMETER_IPV6_ADDRESS        = 6
const SCTP_PARAMETER_STATE_COOKIE        = 7
const SCTP_PARAMETER_UNRECOGNIZED        = 8
const SCTP_PARAMETER_COOKIE_PRESERVATIVE = 9
const SCTP_PARAMETER_HOST_NAME           = 11
const SCTP_PARAMETER_SUPPORTED_ADDRESSES = 12
const SCTP_PARAMETER_RANDOM              = 32770
const SCTP_PARAMETER_CHUNK_LIST          = 32771
const SCTP_PARAMETER_HMAC_ALGORITHM      = 32772
const SCTP_PARAMETER_SUPPORTED_EXTENSIONS = 32776
const SCTP_PARAMETER_FORWARD_TSN         = 49152

"The error causes — RFC 4960 clause 3.3.10."
const SCTP_CAUSE_INVALID_STREAM        = 1
const SCTP_CAUSE_MISSING_PARAMETER     = 2
const SCTP_CAUSE_STALE_COOKIE          = 3
const SCTP_CAUSE_OUT_OF_RESOURCE       = 4
const SCTP_CAUSE_UNRESOLVABLE_ADDRESS  = 5
const SCTP_CAUSE_UNRECOGNIZED_CHUNK    = 6
const SCTP_CAUSE_INVALID_PARAMETER     = 7
const SCTP_CAUSE_UNRECOGNIZED_PARAMETER = 8
const SCTP_CAUSE_NO_USER_DATA          = 9
const SCTP_CAUSE_COOKIE_WHILE_SHUTDOWN = 10

"The address families a Supported Address Types parameter names."
const SCTP_ADDRESS_IPV4 = 5
const SCTP_ADDRESS_IPV6 = 6

# ---------- the parameters ---------------------------------------------------

"The chunk parameters — RFC 4960 clause 3.2.1. The code is two octets."
abstract type SctpParameter <: Fields end

measure_option_code(::Type{SctpParameter}) = 16

"""
    SctpParameterIpv4Address(; address)

An IPv4 Address parameter — RFC 4960 clause 3.3.2.1.1. A sender lists every
address it will use for the association.
"""
@header SctpParameterIpv4Address <: SctpParameter begin
    type    :: Constant{U16, SCTP_PARAMETER_IPV4_ADDRESS}
    length  :: Constant{U16, 8}
    address :: Ipv4Address = Ipv4Address(0)
end

"""
    SctpParameterIpv6Address(; address)

An IPv6 Address parameter — RFC 4960 clause 3.3.2.1.2.
"""
@header SctpParameterIpv6Address <: SctpParameter begin
    type    :: Constant{U16, SCTP_PARAMETER_IPV6_ADDRESS}
    length  :: Constant{U16, 20}
    address :: Ipv6Address = Ipv6Address("::")
end

"""
    SctpParameterCookiePreservative(; increment)

A Cookie Preservative parameter — RFC 4960 clause 3.3.2.1.3. It asks the peer to
keep the cookie alive for this many more milliseconds.
"""
@header SctpParameterCookiePreservative <: SctpParameter begin
    type      :: Constant{U16, SCTP_PARAMETER_COOKIE_PRESERVATIVE}
    length    :: Constant{U16, 8}
    increment :: U32 = 0
end

"""
    SctpParameterSupportedAddresses(; families)

A Supported Address Types parameter — RFC 4960 clause 3.3.2.1.4. Each entry is
one address family, and the parameter pads to a multiple of four — so an odd
number of entries carries two octets of padding.
"""
@header SctpParameterSupportedAddresses <: SctpParameter begin
    type     :: Constant{U16, SCTP_PARAMETER_SUPPORTED_ADDRESSES}
    length   :: U16 = SCTP_PARAMETER_HEADER_BYTES
        derive(SCTP_PARAMETER_HEADER_BYTES + 2 * Base.length(families))
    families :: Repeated{U16} = UInt16[]
        count((Int(length) - SCTP_PARAMETER_HEADER_BYTES) ÷ 2)
    padding  :: Pad{Bytes(4), 0x00}
end

"""
    SctpParameterStateCookie(; cookie)

A State Cookie parameter — RFC 4960 clause 3.3.3.1. The cookie is opaque: only
the sender reads it, and a receiver echoes it back untouched.
"""
@header SctpParameterStateCookie <: SctpParameter begin
    type    :: Constant{U16, SCTP_PARAMETER_STATE_COOKIE}
    length  :: U16 = SCTP_PARAMETER_HEADER_BYTES
        derive(SCTP_PARAMETER_HEADER_BYTES + Base.length(cookie))
    cookie  :: Octets = UInt8[]
        length(Bytes(Int(length) - SCTP_PARAMETER_HEADER_BYTES))
    padding :: Pad{Bytes(4), 0x00}
end

"""
    SctpParameterHeartbeatInfo(; info)

A Heartbeat Info parameter — RFC 4960 clause 3.3.5.1. It is opaque too: the
sender puts what it needs in it and the peer sends it back in the acknowledgement.
"""
@header SctpParameterHeartbeatInfo <: SctpParameter begin
    type    :: Constant{U16, SCTP_PARAMETER_HEARTBEAT_INFO}
    length  :: U16 = SCTP_PARAMETER_HEADER_BYTES
        derive(SCTP_PARAMETER_HEADER_BYTES + Base.length(info))
    info    :: Octets = UInt8[]
        length(Bytes(Int(length) - SCTP_PARAMETER_HEADER_BYTES))
    padding :: Pad{Bytes(4), 0x00}
end

"""
    SctpParameterForwardTsn()

A Forward-TSN-Supported parameter — RFC 3758 clause 3.1. It has no value: its
presence is the message.
"""
@header SctpParameterForwardTsn <: SctpParameter begin
    type   :: Constant{U16, SCTP_PARAMETER_FORWARD_TSN}
    length :: Constant{U16, 4}
end

"""
    SctpParameterSupportedExtensions(; chunk_types)

A Supported Extensions parameter — RFC 5061 clause 4.2.7. It lists the chunk
types this endpoint understands, one octet each.
"""
@header SctpParameterSupportedExtensions <: SctpParameter begin
    type        :: Constant{U16, SCTP_PARAMETER_SUPPORTED_EXTENSIONS}
    length      :: U16 = SCTP_PARAMETER_HEADER_BYTES
        derive(SCTP_PARAMETER_HEADER_BYTES + Base.length(chunk_types))
    chunk_types :: Octets = UInt8[]
        length(Bytes(Int(length) - SCTP_PARAMETER_HEADER_BYTES))
    padding     :: Pad{Bytes(4), 0x00}
end

"""
    SctpParameterRaw(; type, value)

A parameter this library does not model. It keeps its type and its octets, and
it reads exactly as many as its length says — so the parameter after it still
starts where it should.
"""
@header SctpParameterRaw <: SctpParameter begin
    type    :: U16 = 0
    length  :: U16 = SCTP_PARAMETER_HEADER_BYTES
        derive(SCTP_PARAMETER_HEADER_BYTES + Base.length(value))
    value   :: Octets = UInt8[]
        length(Bytes(Int(length) - SCTP_PARAMETER_HEADER_BYTES))
    padding :: Pad{Bytes(4), 0x00}
end


# ---------- the error causes -------------------------------------------------

"The error causes — RFC 4960 clause 3.3.10. Same shape as a parameter."
abstract type SctpCause <: Fields end

measure_option_code(::Type{SctpCause}) = 16

"""
    SctpCauseInvalidStream(; stream_identifier)

An Invalid Stream Identifier cause — RFC 4960 clause 3.3.10.1. A DATA chunk
arrived for a stream the association does not have.
"""
@header SctpCauseInvalidStream <: SctpCause begin
    code              :: Constant{U16, SCTP_CAUSE_INVALID_STREAM}
    length            :: Constant{U16, 8}
    stream_identifier :: U16 = 0
    reserved          :: U16 = 0
end

"""
    SctpCauseStaleCookie(; staleness)

A Stale Cookie cause — RFC 4960 clause 3.3.10.3. It says by how many
microseconds the cookie was late.
"""
@header SctpCauseStaleCookie <: SctpCause begin
    code      :: Constant{U16, SCTP_CAUSE_STALE_COOKIE}
    length    :: Constant{U16, 8}
    staleness :: U32 = 0
end

"""
    SctpCauseOutOfResource()

An Out of Resource cause — RFC 4960 clause 3.3.10.4. It has no value.
"""
@header SctpCauseOutOfResource <: SctpCause begin
    code   :: Constant{U16, SCTP_CAUSE_OUT_OF_RESOURCE}
    length :: Constant{U16, 4}
end

"""
    SctpCauseNoUserData(; tsn)

A No User Data cause — RFC 4960 clause 3.3.10.9. A DATA chunk arrived with no
data in it, and this names its TSN.
"""
@header SctpCauseNoUserData <: SctpCause begin
    code   :: Constant{U16, SCTP_CAUSE_NO_USER_DATA}
    length :: Constant{U16, 8}
    tsn    :: U32 = 0
end

"""
    SctpCauseCookieWhileShutdown()

A Cookie Received While Shutting Down cause — RFC 4960 clause 3.3.10.10.
"""
@header SctpCauseCookieWhileShutdown <: SctpCause begin
    code   :: Constant{U16, SCTP_CAUSE_COOKIE_WHILE_SHUTDOWN}
    length :: Constant{U16, 4}
end

"""
    SctpCauseRaw(; code, value)

An error cause this library does not model. It keeps its code and its octets.
"""
@header SctpCauseRaw <: SctpCause begin
    code    :: U16 = 0
    length  :: U16 = SCTP_PARAMETER_HEADER_BYTES
        derive(SCTP_PARAMETER_HEADER_BYTES + Base.length(value))
    value   :: Octets = UInt8[]
        length(Bytes(Int(length) - SCTP_PARAMETER_HEADER_BYTES))
    padding :: Pad{Bytes(4), 0x00}
end

list_options(::Type{SctpCause}) =
    (SctpCauseInvalidStream, SctpCauseStaleCookie, SctpCauseOutOfResource,
     SctpCauseNoUserData, SctpCauseCookieWhileShutdown)
find_raw_option(::Type{SctpCause}) = SctpCauseRaw

# ---------- the chunks -------------------------------------------------------

"The chunks — RFC 4960 clause 3.2. The type is one octet, so this is a variant."
abstract type SctpChunk <: Fields end

"""
    SctpChunkHeader(; type, flags, length)

The four octets every chunk starts with — RFC 4960 clause 3.2.

`length` counts the type, the flags, this field and the value, and it does NOT
count the padding that takes the chunk up to a multiple of four. That is why a
chunk derives its length from the fields it covers rather than from its own
width: the two are different numbers.

The flags octet means something different in each chunk, so it is one octet here
and the members that use it declare their own bits.
"""
@header SctpChunkHeader begin
    type   :: U8  = SCTP_DATA
    flags  :: U8  = 0
    length :: U16 = SCTP_CHUNK_HEADER_BYTES
end

"The value of a chunk, in octets: what its length field says beyond the header."
measure_chunk_value_bytes(base) =
    Int(base.length) - SCTP_CHUNK_HEADER_BYTES

"""
    SctpData(; tsn, stream_identifier, stream_sequence, payload_protocol, data, …)

A DATA chunk — RFC 4960 clause 3.3.1. It carries the user's octets.

`beginning` and `ending` are the B and E bits and mark the first and the last
fragment of a message; a message that fits in one chunk sets both. `unordered`
is the U bit. `immediate` is the I bit of RFC 7053, which asks the receiver to
acknowledge at once.

The flags live in the chunk header on the wire, so this chunk declares its own
flags octet in place of the shared one.
"""
@header SctpData <: SctpChunk begin
    type              :: Constant{U8, SCTP_DATA}
    reserved          :: U4   = 0
    immediate         :: Bool = false
    unordered         :: Bool = false
    beginning         :: Bool = true
    ending            :: Bool = true
    length            :: U16  = 16
        derive(16 + Base.length(data))
    tsn               :: U32 = 0
    stream_identifier :: U16 = 0
    stream_sequence   :: U16 = 0
    payload_protocol  :: U32 = 0
    data              :: Octets = UInt8[]
        length(Bytes(Int(length) - 16))
    padding           :: Pad{Bytes(4), 0x00}
end

"""
    SctpInit(; initiate_tag, advertised_receiver_window, …, parameters)

An INIT chunk — RFC 4960 clause 3.3.2. It opens an association.

`initiate_tag` is what the peer must put in the verification tag of every packet
it sends back, and RFC 4960 forbids zero. The optional parameters carry the
addresses the sender will use and the extensions it supports.
"""
@header SctpInit <: SctpChunk begin
    type                       :: Constant{U8, SCTP_INIT}
    flags                      :: U8  = 0
    length                     :: U16 = 20
        derive(20 + measure_list_bytes(parameters))
    initiate_tag               :: U32 = 1
    advertised_receiver_window :: U32 = 65535
    outbound_streams           :: U16 = 1
    inbound_streams            :: U16 = 1
    initial_tsn                :: U32 = 0
    parameters                 :: Options{SctpParameter} = SctpParameter[]
        until(Bytes(length))
end

"""
    SctpInitAck(; initiate_tag, advertised_receiver_window, …, parameters)

An INIT ACK chunk — RFC 4960 clause 3.3.3. It answers an INIT and it must carry
a State Cookie parameter.
"""
@header SctpInitAck <: SctpChunk begin
    type                       :: Constant{U8, SCTP_INIT_ACK}
    flags                      :: U8  = 0
    length                     :: U16 = 20
        derive(20 + measure_list_bytes(parameters))
    initiate_tag               :: U32 = 1
    advertised_receiver_window :: U32 = 65535
    outbound_streams           :: U16 = 1
    inbound_streams            :: U16 = 1
    initial_tsn                :: U32 = 0
    parameters                 :: Options{SctpParameter} = SctpParameter[]
        until(Bytes(length))
end

"""
    SctpGapAckBlock(; start_offset, end_offset)

One Gap Ack Block of a SACK — RFC 4960 clause 3.3.4. Both numbers are OFFSETS
from the cumulative TSN, not absolute TSNs; INET's model holds the absolute
values and converts on the way out.
"""
@header SctpGapAckBlock begin
    start_offset :: U16 = 0
    end_offset   :: U16 = 0
end

"""
    SctpSack(; cumulative_tsn_ack, advertised_receiver_window, gaps, duplicates)

A SACK chunk — RFC 4960 clause 3.3.4. It says which TSNs arrived, which gaps
remain, and how much room the receiver still has.
"""
@header SctpSack <: SctpChunk begin
    type                       :: Constant{U8, SCTP_SACK}
    flags                      :: U8  = 0
    length                     :: U16 = 16
        derive(16 + 4 * Base.length(gaps) + 4 * Base.length(duplicates))
    cumulative_tsn_ack         :: U32 = 0
    advertised_receiver_window :: U32 = 65535
    number_of_gaps             :: U16 = 0
        derive(Base.length(gaps))
    number_of_duplicates       :: U16 = 0
        derive(Base.length(duplicates))
    gaps                       :: Repeated{SctpGapAckBlock} = SctpGapAckBlock[]
        count(number_of_gaps)
    duplicates                 :: Repeated{U32} = UInt32[]
        count(number_of_duplicates)
end

"""
    SctpHeartbeat(; parameters)

A HEARTBEAT chunk — RFC 4960 clause 3.3.5. It carries one Heartbeat Info
parameter, and the peer sends the same octets back.
"""
@header SctpHeartbeat <: SctpChunk begin
    type       :: Constant{U8, SCTP_HEARTBEAT}
    flags      :: U8  = 0
    length     :: U16 = SCTP_CHUNK_HEADER_BYTES
        derive(SCTP_CHUNK_HEADER_BYTES + measure_list_bytes(parameters))
    parameters :: Options{SctpParameter} = SctpParameter[]
        until(Bytes(length))
end

"""
    SctpHeartbeatAck(; parameters)

A HEARTBEAT ACK chunk — RFC 4960 clause 3.3.6. It echoes the parameter the
heartbeat carried, unchanged.
"""
@header SctpHeartbeatAck <: SctpChunk begin
    type       :: Constant{U8, SCTP_HEARTBEAT_ACK}
    flags      :: U8  = 0
    length     :: U16 = SCTP_CHUNK_HEADER_BYTES
        derive(SCTP_CHUNK_HEADER_BYTES + measure_list_bytes(parameters))
    parameters :: Options{SctpParameter} = SctpParameter[]
        until(Bytes(length))
end

"""
    SctpAbort(; verification_tag_reflected, causes)

An ABORT chunk — RFC 4960 clause 3.3.7. It closes the association at once and
says why.

`verification_tag_reflected` is the T bit: it says the sender copied the
verification tag from the packet it is answering instead of using its own.
"""
@header SctpAbort <: SctpChunk begin
    type                      :: Constant{U8, SCTP_ABORT}
    reserved                  :: U7   = 0
    verification_tag_reflected :: Bool = false
    length                    :: U16  = SCTP_CHUNK_HEADER_BYTES
        derive(SCTP_CHUNK_HEADER_BYTES + measure_list_bytes(causes))
    causes                    :: Options{SctpCause} = SctpCause[]
        until(Bytes(length))
end

"""
    SctpShutdown(; cumulative_tsn_ack)

A SHUTDOWN chunk — RFC 4960 clause 3.3.8. It starts a graceful close and
acknowledges everything received so far.
"""
@header SctpShutdown <: SctpChunk begin
    type               :: Constant{U8, SCTP_SHUTDOWN}
    flags              :: U8 = 0
    length             :: Constant{U16, 8}
    cumulative_tsn_ack :: U32 = 0
end

"""
    SctpShutdownAck()

A SHUTDOWN ACK chunk — RFC 4960 clause 3.3.9. Four octets and nothing else.
"""
@header SctpShutdownAck <: SctpChunk begin
    type   :: Constant{U8, SCTP_SHUTDOWN_ACK}
    flags  :: U8 = 0
    length :: Constant{U16, 4}
end

"""
    SctpError(; causes)

An ERROR chunk — RFC 4960 clause 3.3.10. It reports a fault without closing the
association, which is what separates it from an ABORT.
"""
@header SctpError <: SctpChunk begin
    type   :: Constant{U8, SCTP_ERROR}
    flags  :: U8  = 0
    length :: U16 = SCTP_CHUNK_HEADER_BYTES
        derive(SCTP_CHUNK_HEADER_BYTES + measure_list_bytes(causes))
    causes :: Options{SctpCause} = SctpCause[]
        until(Bytes(length))
end

"""
    SctpCookieEcho(; cookie)

A COOKIE ECHO chunk — RFC 4960 clause 3.3.11. It returns the State Cookie the
INIT ACK carried, and the octets are the ones that arrived.
"""
@header SctpCookieEcho <: SctpChunk begin
    type    :: Constant{U8, SCTP_COOKIE_ECHO}
    flags   :: U8  = 0
    length  :: U16 = SCTP_CHUNK_HEADER_BYTES
        derive(SCTP_CHUNK_HEADER_BYTES + Base.length(cookie))
    cookie  :: Octets = UInt8[]
        length(Bytes(Int(length) - SCTP_CHUNK_HEADER_BYTES))
    padding :: Pad{Bytes(4), 0x00}
end

"""
    SctpCookieAck()

A COOKIE ACK chunk — RFC 4960 clause 3.3.12. Four octets and nothing else.
"""
@header SctpCookieAck <: SctpChunk begin
    type   :: Constant{U8, SCTP_COOKIE_ACK}
    flags  :: U8 = 0
    length :: Constant{U16, 4}
end

"""
    SctpShutdownComplete(; verification_tag_reflected)

A SHUTDOWN COMPLETE chunk — RFC 4960 clause 3.3.13. It ends the close, and it
carries the same T bit an ABORT does.
"""
@header SctpShutdownComplete <: SctpChunk begin
    type                      :: Constant{U8, SCTP_SHUTDOWN_COMPLETE}
    reserved                  :: U7   = 0
    verification_tag_reflected :: Bool = false
    length                    :: Constant{U16, 4}
end

"""
    SctpForwardTsn(; new_cumulative_tsn, streams)

A FORWARD TSN chunk — RFC 3758 clause 3.2. A sender that gave up on some chunks
tells the receiver to move its cumulative TSN past them.
"""
@header SctpForwardTsnStream begin
    stream_identifier :: U16 = 0
    stream_sequence   :: U16 = 0
end

@header SctpForwardTsn <: SctpChunk begin
    type               :: Constant{U8, SCTP_FORWARD_TSN}
    flags              :: U8  = 0
    length             :: U16 = 8
        derive(8 + 4 * Base.length(streams))
    new_cumulative_tsn :: U32 = 0
    streams            :: Repeated{SctpForwardTsnStream} = SctpForwardTsnStream[]
        count((Int(length) - 8) ÷ 4)
end

"""
    SctpChunkRaw(; base, value)

A chunk this library does not model. It keeps its type, its flags and its
octets, and it reads exactly as many as its length says — so the chunk after it
in the same packet still starts where it should.
"""
@header SctpChunkRaw <: SctpChunk begin
    base    :: SctpChunkHeader = SctpChunkHeader()
        derive(set_field(base, :length,
                         SCTP_CHUNK_HEADER_BYTES + Base.length(value)))
    value   :: Octets = UInt8[]
        length(Bytes(measure_chunk_value_bytes(base)))
    padding :: Pad{Bytes(4), 0x00}
end


# ---------- the packet -------------------------------------------------------

"""
    SctpHeader(; source_port, destination_port, verification_tag, chunks)

An SCTP packet — RFC 4960 clause 3.1. Twelve octets of common header and then as
many chunks as fit. Nothing counts them: the chunks run to the end of the
packet, and each one says its own length.

`verification_tag` is the tag the peer gave in its INIT, and a packet whose tag
does not match is dropped. `checksum` is a CRC32c over the whole packet — RFC
4960 clause 6.8 — and not the internet checksum the other transports use.
"""
@header SctpHeader begin
    source_port      :: Port = 0
    destination_port :: Port = 0
    verification_tag :: U32 = 0
    checksum         :: U32 = 0
    checksum_mode    :: Model{ChecksumMode} = CHECKSUM_DECLARED
    chunks           :: Repeated{SctpChunk} = SctpChunk[]
end

# ---------- the extension chunks ---------------------------------------------
#
# Seven chunk types beyond RFC 4960. Three have an RFC of their own — AUTH is
# RFC 4895, ASCONF and ASCONF-ACK are RFC 5061, RE-CONFIG is RFC 6525 and
# I-FORWARD-TSN is RFC 8260. Two do not: NR-SACK and PKTDROP are Internet
# drafts that never became RFCs, so INET is the specification for those two and
# its serializer is the source.
#
# They add no shape the language does not have. What they add is members: the
# ASCONF and RE-CONFIG parameters are ordinary members of the parameter family,
# because RFC 4960 clause 3.2.1 gives every SCTP parameter the same two-octet
# type and two-octet length.

"The chunk types beyond RFC 4960 — RFC 4895, RFC 5061, RFC 6525 and RFC 8260."
const SCTP_ASCONF_ACK    = 128
const SCTP_PACKET_DROP   = 129
const SCTP_RE_CONFIG     = 130
const SCTP_ASCONF        = 193
const SCTP_IFORWARD_TSN  = 194

"The address configuration parameters — RFC 5061 clause 4.2."
const SCTP_PARAMETER_ADD_IP_ADDRESS     = 49153
const SCTP_PARAMETER_DELETE_IP_ADDRESS  = 49154
const SCTP_PARAMETER_ERROR_CAUSE        = 49155
const SCTP_PARAMETER_SET_PRIMARY        = 49156
const SCTP_PARAMETER_SUCCESS            = 49157

"The stream reconfiguration parameters — RFC 6525 clause 4."
const SCTP_PARAMETER_OUTGOING_RESET      = 13
const SCTP_PARAMETER_INCOMING_RESET      = 14
const SCTP_PARAMETER_SSN_TSN_RESET       = 15
const SCTP_PARAMETER_RESET_RESPONSE      = 16
const SCTP_PARAMETER_ADD_OUTGOING_STREAMS = 17
const SCTP_PARAMETER_ADD_INCOMING_STREAMS = 18

"The results a reconfiguration response carries — RFC 6525 clause 4.4."
const SCTP_RESET_SUCCESS_NOTHING_TO_DO = 0
const SCTP_RESET_SUCCESS_PERFORMED     = 1
const SCTP_RESET_DENIED                = 2
const SCTP_RESET_ERROR_WRONG_SSN       = 3
const SCTP_RESET_IN_PROGRESS           = 4

"The widths the extension chunks give their fixed parts, in octets."
const SCTP_AUTH_CHUNK_BYTES        = 8
const SCTP_NR_SACK_CHUNK_BYTES     = 20
const SCTP_PACKET_DROP_CHUNK_BYTES = 16
const SCTP_ASCONF_CHUNK_BYTES      = 8

# ---------- the address configuration parameters, RFC 5061 -------------------

"""
    SctpParameterAddIpAddress(; correlation_id, address)

An Add IP Address parameter — RFC 5061 clause 4.2.1. It asks the peer to add an
address to the association.

`address` is a nested parameter, not a bare address: RFC 5061 reuses the IPv4
and IPv6 address parameters of RFC 4960, so one list holds either.
"""
@header SctpParameterAddIpAddress <: SctpParameter begin
    type           :: Constant{U16, SCTP_PARAMETER_ADD_IP_ADDRESS}
    length         :: U16 = SCTP_CHUNK_HEADER_BYTES + 4
        derive(SCTP_CHUNK_HEADER_BYTES + 4 + measure_list_bytes(address))
    correlation_id :: U32 = 0
    address        :: Options{SctpParameter} = SctpParameter[]
        until(Bytes(length))
    padding        :: Pad{Bytes(4), 0x00}
end

"""
    SctpParameterDeleteIpAddress(; correlation_id, address)

A Delete IP Address parameter — RFC 5061 clause 4.2.2.
"""
@header SctpParameterDeleteIpAddress <: SctpParameter begin
    type           :: Constant{U16, SCTP_PARAMETER_DELETE_IP_ADDRESS}
    length         :: U16 = SCTP_CHUNK_HEADER_BYTES + 4
        derive(SCTP_CHUNK_HEADER_BYTES + 4 + measure_list_bytes(address))
    correlation_id :: U32 = 0
    address        :: Options{SctpParameter} = SctpParameter[]
        until(Bytes(length))
    padding        :: Pad{Bytes(4), 0x00}
end

"""
    SctpParameterSetPrimaryAddress(; correlation_id, address)

A Set Primary Address parameter — RFC 5061 clause 4.2.4. It asks the peer to
send to this address by default.
"""
@header SctpParameterSetPrimaryAddress <: SctpParameter begin
    type           :: Constant{U16, SCTP_PARAMETER_SET_PRIMARY}
    length         :: U16 = SCTP_CHUNK_HEADER_BYTES + 4
        derive(SCTP_CHUNK_HEADER_BYTES + 4 + measure_list_bytes(address))
    correlation_id :: U32 = 0
    address        :: Options{SctpParameter} = SctpParameter[]
        until(Bytes(length))
    padding        :: Pad{Bytes(4), 0x00}
end

"""
    SctpParameterSuccess(; correlation_id)

A Success Indication parameter — RFC 5061 clause 4.3.1. It answers one request
of an ASCONF chunk, and the correlation identifier says which.
"""
@header SctpParameterSuccess <: SctpParameter begin
    type           :: Constant{U16, SCTP_PARAMETER_SUCCESS}
    length         :: Constant{U16, 8}
    correlation_id :: U32 = 0
end

"""
    SctpParameterErrorCause(; correlation_id, causes)

An Error Cause Indication parameter — RFC 5061 clause 4.3.2. It refuses one
request of an ASCONF chunk and says why, in the error causes of RFC 4960.
"""
@header SctpParameterErrorCause <: SctpParameter begin
    type           :: Constant{U16, SCTP_PARAMETER_ERROR_CAUSE}
    length         :: U16 = SCTP_CHUNK_HEADER_BYTES + 4
        derive(SCTP_CHUNK_HEADER_BYTES + 4 + measure_list_bytes(causes))
    correlation_id :: U32 = 0
    causes         :: Options{SctpCause} = SctpCause[]
        until(Bytes(length))
    padding        :: Pad{Bytes(4), 0x00}
end

# ---------- the stream reconfiguration parameters, RFC 6525 ------------------

"""
    SctpParameterOutgoingReset(; request_sequence, response_sequence, last_tsn, streams)

An Outgoing SSN Reset Request parameter — RFC 6525 clause 4.1. It asks the peer
to reset the sequence numbers of the streams this endpoint sends on, and an
empty stream list means every stream.
"""
@header SctpParameterOutgoingReset <: SctpParameter begin
    type              :: Constant{U16, SCTP_PARAMETER_OUTGOING_RESET}
    length            :: U16 = 16
        derive(16 + 2 * Base.length(streams))
    request_sequence  :: U32 = 0
    response_sequence :: U32 = 0
    last_tsn          :: U32 = 0
    streams           :: Repeated{U16} = UInt16[]
        count((Int(length) - 16) ÷ 2)
    padding           :: Pad{Bytes(4), 0x00}
end

"""
    SctpParameterIncomingReset(; request_sequence, streams)

An Incoming SSN Reset Request parameter — RFC 6525 clause 4.2. It asks the peer
to reset the streams it sends on.
"""
@header SctpParameterIncomingReset <: SctpParameter begin
    type             :: Constant{U16, SCTP_PARAMETER_INCOMING_RESET}
    length           :: U16 = 8
        derive(8 + 2 * Base.length(streams))
    request_sequence :: U32 = 0
    streams          :: Repeated{U16} = UInt16[]
        count((Int(length) - 8) ÷ 2)
    padding          :: Pad{Bytes(4), 0x00}
end

"""
    SctpParameterSsnTsnReset(; request_sequence)

An SSN/TSN Reset Request parameter — RFC 6525 clause 4.3. It resets every stream
and the transmission sequence number with them.
"""
@header SctpParameterSsnTsnReset <: SctpParameter begin
    type             :: Constant{U16, SCTP_PARAMETER_SSN_TSN_RESET}
    length           :: Constant{U16, 8}
    request_sequence :: U32 = 0
end

"""
    SctpParameterResetResponse(; response_sequence, result, sender_next_tsn, receiver_next_tsn)

A Reconfiguration Response parameter — RFC 6525 clause 4.4.

It is twelve octets, or twenty when the request reset the transmission sequence
numbers as well — then it carries the two next TSNs. The length says which, and
nothing else does.

**This is the one length field in the inventory that is not derived, and the
reason is worth stating.** A derive runs on the way out and a `when` clause reads
the stored fields, so a derived length would say twenty while the clause still
read the twelve the struct held, and the writer would emit twelve octets under a
length of twenty. The length is what the standard makes authoritative, so it
stays a field the sender sets, and a `check` on all three fields says they must
agree. `build_reset_response` sets them together.

A clause sees an optional field already unwrapped, which is why the test is
against `nothing` and not `is_present`.
"""
@header SctpParameterResetResponse <: SctpParameter begin
    type              :: Constant{U16, SCTP_PARAMETER_RESET_RESPONSE}
    length            :: U16 = 12
        check((Int(length) >= 20) == (sender_next_tsn !== nothing))
    response_sequence :: U32 = 0
    result            :: U32 = SCTP_RESET_SUCCESS_PERFORMED
    sender_next_tsn   :: Optional{U32} = nothing
        when(Int(length) >= 20)
        check((Int(length) >= 20) == (sender_next_tsn !== nothing))
    receiver_next_tsn :: Optional{U32} = nothing
        when(Int(length) >= 20)
        check((Int(length) >= 20) == (receiver_next_tsn !== nothing))
end

"""
    build_reset_response(; response_sequence, result, sender_next_tsn, receiver_next_tsn)

A reconfiguration response with its length set to match what it carries — twelve
octets with no TSNs, and twenty with both.
"""
function build_reset_response(; response_sequence = 0,
                              result = SCTP_RESET_SUCCESS_PERFORMED,
                              sender_next_tsn = nothing,
                              receiver_next_tsn = nothing)
    (sender_next_tsn === nothing) == (receiver_next_tsn === nothing) ||
        error("build_reset_response: RFC 6525 clause 4.4 wants both next TSNs " *
              "or neither")
    return SctpParameterResetResponse(
        length = sender_next_tsn === nothing ? 12 : 20,
        response_sequence = response_sequence, result = result,
        sender_next_tsn = sender_next_tsn, receiver_next_tsn = receiver_next_tsn)
end

"""
    SctpParameterAddOutgoingStreams(; request_sequence, new_streams)

An Add Outgoing Streams Request parameter — RFC 6525 clause 4.5. It asks for
more streams to send on, without tearing the association down.
"""
@header SctpParameterAddOutgoingStreams <: SctpParameter begin
    type             :: Constant{U16, SCTP_PARAMETER_ADD_OUTGOING_STREAMS}
    length           :: Constant{U16, 12}
    request_sequence :: U32 = 0
    new_streams      :: U16 = 0
    reserved         :: U16 = 0
end

"""
    SctpParameterAddIncomingStreams(; request_sequence, new_streams)

An Add Incoming Streams Request parameter — RFC 6525 clause 4.6.
"""
@header SctpParameterAddIncomingStreams <: SctpParameter begin
    type             :: Constant{U16, SCTP_PARAMETER_ADD_INCOMING_STREAMS}
    length           :: Constant{U16, 12}
    request_sequence :: U32 = 0
    new_streams      :: U16 = 0
    reserved         :: U16 = 0
end

# ---------- the extension chunks ---------------------------------------------

"""
    SctpAuth(; shared_key_identifier, hmac_identifier, hmac)

An AUTH chunk — RFC 4895 clause 4.1. Every chunk after it in the same packet is
covered by the message authentication code it carries.

The code is computed with this chunk's own `hmac` field set to zero, which is
why a sender writes the zeros first and fills them in after.
"""
@header SctpAuth <: SctpChunk begin
    type                 :: Constant{U8, SCTP_AUTH}
    flags                :: U8  = 0
    length               :: U16 = SCTP_AUTH_CHUNK_BYTES
        derive(SCTP_AUTH_CHUNK_BYTES + Base.length(hmac))
    shared_key_identifier :: U16 = 0
    hmac_identifier      :: U16 = 1
    hmac                 :: Octets = UInt8[]
        length(Bytes(Int(length) - SCTP_AUTH_CHUNK_BYTES))
    padding              :: Pad{Bytes(4), 0x00}
end

"""
    SctpNrSack(; cumulative_tsn_ack, gaps, non_renegable_gaps, duplicates, …)

A Non-Renegable SACK chunk. It is the SACK of RFC 4960 with a second list of
gap blocks: the first list may still be given back, and the second may not.

This chunk has no RFC. It comes from an Internet draft that expired, so INET's
`SctpHeaderSerializer` is the specification here and this follows its layout.
"""
@header SctpNrSack <: SctpChunk begin
    type                       :: Constant{U8, SCTP_NR_SACK}
    flags                      :: U8  = 0
    length                     :: U16 = SCTP_NR_SACK_CHUNK_BYTES
        derive(SCTP_NR_SACK_CHUNK_BYTES + 4 * Base.length(gaps) +
               4 * Base.length(non_renegable_gaps) + 4 * Base.length(duplicates))
    cumulative_tsn_ack         :: U32 = 0
    advertised_receiver_window :: U32 = 65535
    number_of_gaps             :: U16 = 0
        derive(Base.length(gaps))
    number_of_duplicates       :: U16 = 0
        derive(Base.length(duplicates))
    number_of_non_renegable_gaps :: U16 = 0
        derive(Base.length(non_renegable_gaps))
    reserved                   :: U16 = 0
    gaps                       :: Repeated{SctpGapAckBlock} = SctpGapAckBlock[]
        count(number_of_gaps)
    non_renegable_gaps         :: Repeated{SctpGapAckBlock} = SctpGapAckBlock[]
        count(number_of_non_renegable_gaps)
    duplicates                 :: Repeated{U32} = UInt32[]
        count(number_of_duplicates)
end

"""
    SctpPacketDrop(; max_receiver_window, queued_data, dropped, …)

A Packet Drop chunk. A middlebox that dropped a packet for a reason other than
congestion says so, and returns as much of the packet as it kept.

`bandwidth_limited` is the B flag, `truncated` the T flag, `corrupted` the C
flag and `middlebox` the M flag. This chunk has no RFC either: it comes from an
expired draft, so INET is the specification.
"""
@header SctpPacketDrop <: SctpChunk begin
    type                :: Constant{U8, SCTP_PACKET_DROP}
    reserved_flags      :: U4   = 0
    corrupted           :: Bool = false
    truncated           :: Bool = false
    bandwidth_limited   :: Bool = false
    middlebox           :: Bool = false
    length              :: U16 = SCTP_PACKET_DROP_CHUNK_BYTES
        derive(SCTP_PACKET_DROP_CHUNK_BYTES + Base.length(dropped))
    max_receiver_window :: U32 = 0
    queued_data         :: U32 = 0
    truncated_length    :: U16 = 0
    reserved            :: U16 = 0
    dropped             :: Octets = UInt8[]
        length(Bytes(Int(length) - SCTP_PACKET_DROP_CHUNK_BYTES))
    padding             :: Pad{Bytes(4), 0x00}
end

"""
    SctpAsconf(; serial_number, parameters)

An ASCONF chunk — RFC 5061 clause 4.1. It changes the addresses of a live
association: it adds one, deletes one, or names a new primary.

The first parameter is the address the sender is asking from, and the rest are
the requests. They are all parameters of the one family, so they are one list.
"""
@header SctpAsconf <: SctpChunk begin
    type          :: Constant{U8, SCTP_ASCONF}
    flags         :: U8  = 0
    length        :: U16 = SCTP_ASCONF_CHUNK_BYTES
        derive(SCTP_ASCONF_CHUNK_BYTES + measure_list_bytes(parameters))
    serial_number :: U32 = 0
    parameters    :: Options{SctpParameter} = SctpParameter[]
        until(Bytes(length))
end

"""
    SctpAsconfAck(; serial_number, parameters)

An ASCONF-ACK chunk — RFC 5061 clause 4.2. It answers an ASCONF with one
success or one error cause for each request, and the serial number says which
ASCONF it answers.
"""
@header SctpAsconfAck <: SctpChunk begin
    type          :: Constant{U8, SCTP_ASCONF_ACK}
    flags         :: U8  = 0
    length        :: U16 = SCTP_ASCONF_CHUNK_BYTES
        derive(SCTP_ASCONF_CHUNK_BYTES + measure_list_bytes(parameters))
    serial_number :: U32 = 0
    parameters    :: Options{SctpParameter} = SctpParameter[]
        until(Bytes(length))
end

"""
    SctpReConfig(; parameters)

A RE-CONFIG chunk — RFC 6525 clause 3.1. It resets stream sequence numbers or
asks for more streams, and it carries one or two parameters and nothing else.
"""
@header SctpReConfig <: SctpChunk begin
    type       :: Constant{U8, SCTP_RE_CONFIG}
    flags      :: U8  = 0
    length     :: U16 = SCTP_CHUNK_HEADER_BYTES
        derive(SCTP_CHUNK_HEADER_BYTES + measure_list_bytes(parameters))
    parameters :: Options{SctpParameter} = SctpParameter[]
        until(Bytes(length))
end

"""
    SctpIforwardTsnStream(; stream_identifier, unordered, message_identifier)

One stream of an I-FORWARD-TSN chunk — RFC 8260 clause 2.3.1. Eight octets,
where the FORWARD-TSN of RFC 3758 spends four: a message identifier is
thirty-two bits where a stream sequence number is sixteen.
"""
@header SctpIforwardTsnStream begin
    stream_identifier  :: U16 = 0
    reserved           :: U15 = 0
    unordered          :: Bool = false
    message_identifier :: U32 = 0
end

"""
    SctpIforwardTsn(; new_cumulative_tsn, streams)

An I-FORWARD-TSN chunk — RFC 8260 clause 2.3.1. It is the FORWARD-TSN of RFC
3758 for an association that numbers messages rather than orders them.
"""
@header SctpIforwardTsn <: SctpChunk begin
    type               :: Constant{U8, SCTP_IFORWARD_TSN}
    flags              :: U8  = 0
    length             :: U16 = 8
        derive(8 + 8 * Base.length(streams))
    new_cumulative_tsn :: U32 = 0
    streams            :: Repeated{SctpIforwardTsnStream} = SctpIforwardTsnStream[]
        count((Int(length) - 8) ÷ 8)
end

list_options(::Type{SctpParameter}) =
    (SctpParameterIpv4Address, SctpParameterIpv6Address,
     SctpParameterCookiePreservative, SctpParameterSupportedAddresses,
     SctpParameterStateCookie, SctpParameterHeartbeatInfo,
     SctpParameterForwardTsn, SctpParameterSupportedExtensions,
     SctpParameterAddIpAddress, SctpParameterDeleteIpAddress,
     SctpParameterSetPrimaryAddress, SctpParameterSuccess,
     SctpParameterErrorCause, SctpParameterOutgoingReset,
     SctpParameterIncomingReset, SctpParameterSsnTsnReset,
     SctpParameterResetResponse, SctpParameterAddOutgoingStreams,
     SctpParameterAddIncomingStreams)
find_raw_option(::Type{SctpParameter}) = SctpParameterRaw

# ---------- the chunk family -------------------------------------------------
#
# The family is declared here, after every member: a `matches_variant` names its
# member in the SIGNATURE, and a signature is evaluated where it is written.

list_variants(::Type{SctpChunk}) =
    (SctpData, SctpInit, SctpInitAck, SctpSack, SctpHeartbeat, SctpHeartbeatAck,
     SctpAbort, SctpShutdown, SctpShutdownAck, SctpError, SctpCookieEcho,
     SctpCookieAck, SctpShutdownComplete, SctpForwardTsn, SctpAuth, SctpNrSack,
     SctpPacketDrop, SctpAsconf, SctpAsconfAck, SctpReConfig, SctpIforwardTsn,
     SctpChunkRaw)
variant_base(::Type{SctpChunk}) = SctpChunkHeader

matches_variant(::Type{SctpData}, base)             = base.type == SCTP_DATA
matches_variant(::Type{SctpInit}, base)             = base.type == SCTP_INIT
matches_variant(::Type{SctpInitAck}, base)          = base.type == SCTP_INIT_ACK
matches_variant(::Type{SctpSack}, base)             = base.type == SCTP_SACK
matches_variant(::Type{SctpHeartbeat}, base)        = base.type == SCTP_HEARTBEAT
matches_variant(::Type{SctpHeartbeatAck}, base)     = base.type == SCTP_HEARTBEAT_ACK
matches_variant(::Type{SctpAbort}, base)            = base.type == SCTP_ABORT
matches_variant(::Type{SctpShutdown}, base)         = base.type == SCTP_SHUTDOWN
matches_variant(::Type{SctpShutdownAck}, base)      = base.type == SCTP_SHUTDOWN_ACK
matches_variant(::Type{SctpError}, base)            = base.type == SCTP_ERROR
matches_variant(::Type{SctpCookieEcho}, base)       = base.type == SCTP_COOKIE_ECHO
matches_variant(::Type{SctpCookieAck}, base)        = base.type == SCTP_COOKIE_ACK
matches_variant(::Type{SctpShutdownComplete}, base) = base.type == SCTP_SHUTDOWN_COMPLETE
matches_variant(::Type{SctpForwardTsn}, base)       = base.type == SCTP_FORWARD_TSN
matches_variant(::Type{SctpAuth}, base)             = base.type == SCTP_AUTH
matches_variant(::Type{SctpNrSack}, base)           = base.type == SCTP_NR_SACK
matches_variant(::Type{SctpPacketDrop}, base)       = base.type == SCTP_PACKET_DROP
matches_variant(::Type{SctpAsconf}, base)           = base.type == SCTP_ASCONF
matches_variant(::Type{SctpAsconfAck}, base)        = base.type == SCTP_ASCONF_ACK
matches_variant(::Type{SctpReConfig}, base)         = base.type == SCTP_RE_CONFIG
matches_variant(::Type{SctpIforwardTsn}, base)      = base.type == SCTP_IFORWARD_TSN

# A chunk of an unknown type is still a chunk: it says its own length, so a
# reader can step over it. The raw member claims what no other member does.
matches_variant(::Type{SctpChunkRaw}, base) = true
