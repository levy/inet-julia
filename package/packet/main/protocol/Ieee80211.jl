# ============================================================================
# The IEEE 802.11 MAC frames — clause 9.
#
# Every frame starts with a frame control field and a duration, and every frame
# carries at least one address. What follows depends on the type and the
# subtype, which is the variant shape with a two-part discriminator.
#
# Three things here are worth stating, because they differ from INET.
#
# 1. **The type and the subtype are two fields.** Clause 9.2.4.1 gives the
#    frame control field a two-bit Type and a four-bit Subtype. INET packs both
#    into one enumeration, so `ST_RTS` is 0x1b — control type 1 with subtype
#    0xb. A reader that wants "is this a data frame" then has to shift. Here
#    they are the two fields the standard draws, and `IEEE80211_TYPE_DATA` is
#    simply 2.
#
# 2. **The Block Ack Request is twenty octets, not thirty-eight.** INET writes
#    the fragment number as four octets and then eight zero octets and an
#    eight-octet sequence number. Clause 9.3.1.7 gives the BAR Information
#    field two octets in total: a four-bit fragment number and a twelve-bit
#    starting sequence number. This declares the standard's frame. It is the
#    one place in this library where a declaration will not read an INET
#    capture, and it is deliberate — the alternative is to write an eighteen
#    octet field that no radio has ever sent.
#
# 3. **The duration and the sequence control carry their own byte order.**
#    `Ieee80211Duration` and `Ieee80211SequenceControl` are little-endian
#    wherever they appear, and the rest of the header stays in network order.
#    See `FieldTypes.jl`.
#
# The fourth address and the quality-of-service control are present only
# sometimes, and the `when` clause says when: the fourth address when a frame
# travels between two access points, and the QoS control when the subtype has
# its QoS bit set.
# ============================================================================

"The four frame types — IEEE 802.11 clause 9.2.4.1.3."
const IEEE80211_TYPE_MANAGEMENT = 0
const IEEE80211_TYPE_CONTROL    = 1
const IEEE80211_TYPE_DATA       = 2

"The control subtypes — clause 9.2.4.1.3 table 9-1."
const IEEE80211_SUBTYPE_BLOCK_ACK_REQUEST = 0x8
const IEEE80211_SUBTYPE_BLOCK_ACK         = 0x9
const IEEE80211_SUBTYPE_PS_POLL           = 0xa
const IEEE80211_SUBTYPE_RTS               = 0xb
const IEEE80211_SUBTYPE_CTS               = 0xc
const IEEE80211_SUBTYPE_ACK               = 0xd

"The management subtypes."
const IEEE80211_SUBTYPE_ASSOCIATION_REQUEST    = 0x0
const IEEE80211_SUBTYPE_ASSOCIATION_RESPONSE   = 0x1
const IEEE80211_SUBTYPE_REASSOCIATION_REQUEST  = 0x2
const IEEE80211_SUBTYPE_REASSOCIATION_RESPONSE = 0x3
const IEEE80211_SUBTYPE_PROBE_REQUEST          = 0x4
const IEEE80211_SUBTYPE_PROBE_RESPONSE         = 0x5
const IEEE80211_SUBTYPE_BEACON                 = 0x8
const IEEE80211_SUBTYPE_ATIM                   = 0x9
const IEEE80211_SUBTYPE_DISASSOCIATION         = 0xa
const IEEE80211_SUBTYPE_AUTHENTICATION         = 0xb
const IEEE80211_SUBTYPE_DEAUTHENTICATION       = 0xc
const IEEE80211_SUBTYPE_ACTION                 = 0xd
const IEEE80211_SUBTYPE_ACTION_NO_ACK          = 0xe

"The data subtypes. Bit 3 of a data subtype means the frame carries QoS control."
const IEEE80211_SUBTYPE_DATA      = 0x0
const IEEE80211_SUBTYPE_QOS_DATA  = 0x8
const IEEE80211_QOS_SUBTYPE_BIT   = 0x8

"The acknowledgement policies of a QoS control field — clause 9.2.4.5.4."
const IEEE80211_ACK_NORMAL      = 0
const IEEE80211_ACK_NONE        = 1
const IEEE80211_ACK_NO_EXPLICIT = 2
const IEEE80211_ACK_BLOCK       = 3

"The action categories — clause 9.4.1.11. Only Block Ack is modelled."
const IEEE80211_CATEGORY_BLOCK_ACK = 3

"The Block Ack actions — clause 9.6.5."
const IEEE80211_ACTION_ADDBA_REQUEST  = 0
const IEEE80211_ACTION_ADDBA_RESPONSE = 1
const IEEE80211_ACTION_DELBA          = 2

"The frame lengths clause 9.3 states, without the four-octet frame check sequence."
const IEEE80211_ACK_BYTES        = 10
const IEEE80211_CTS_BYTES        = 10
const IEEE80211_RTS_BYTES        = 16
const IEEE80211_PS_POLL_BYTES    = 16
const IEEE80211_MANAGEMENT_BYTES = 24
const IEEE80211_BLOCK_ACK_REQUEST_BYTES = 20

"The IEEE 802.11 frames — one wire format, and the type and subtype say which."
abstract type Ieee80211MacHeader <: Fields end

"""
    Ieee80211FrameControl(; frame_type, subtype, to_ds, from_ds, retry, …)

The frame control field, two octets — IEEE 802.11 clause 9.2.4.1.

The eight flags come after the subtype, the type and the protocol version,
which is the order the octets need. `order` is the bit that says a High
Throughput Control field follows the addresses.
"""
@header Ieee80211FrameControl begin
    subtype          :: U4 = IEEE80211_SUBTYPE_DATA
    frame_type       :: U2 = IEEE80211_TYPE_DATA
    protocol_version :: U2 = 0
    order            :: Bool = false
    protected        :: Bool = false
    more_data        :: Bool = false
    power_management :: Bool = false
    retry            :: Bool = false
    more_fragments   :: Bool = false
    from_ds          :: Bool = false
    to_ds            :: Bool = false
end

"Whether a data frame's subtype says a quality-of-service control field follows."
has_qos_control(control::Ieee80211FrameControl) =
    control.frame_type == IEEE80211_TYPE_DATA &&
    (UInt8(control.subtype) & IEEE80211_QOS_SUBTYPE_BIT) != 0

"Whether a frame travels between two access points, and so carries a fourth address."
has_fourth_address(control::Ieee80211FrameControl) = control.to_ds && control.from_ds

"""
    Ieee80211Common(; frame_control, duration, receiver)

The ten octets every IEEE 802.11 frame starts with: the frame control field,
the duration and the first address. An acknowledgement is these ten octets and
its frame check sequence, and nothing else.
"""
@header Ieee80211Common <: Ieee80211MacHeader begin
    frame_control :: Ieee80211FrameControl = Ieee80211FrameControl()
    duration      :: Ieee80211Duration = 0
    receiver      :: MacAddress
end

# ---------- the control frames, clause 9.3.1 ---------------------------------

"""
    Ieee80211Ack(; receiver, duration)

An acknowledgement, ten octets — clause 9.3.1.4.
"""
@header Ieee80211Ack <: Ieee80211MacHeader begin
    base :: Ieee80211Common =
        Ieee80211Common(frame_control =
            Ieee80211FrameControl(frame_type = IEEE80211_TYPE_CONTROL,
                                  subtype = IEEE80211_SUBTYPE_ACK),
            receiver = MacAddress(0))
end

"""
    Ieee80211Cts(; receiver, duration)

A clear to send, ten octets — clause 9.3.1.3. It has the shape of an
acknowledgement and its own subtype.
"""
@header Ieee80211Cts <: Ieee80211MacHeader begin
    base :: Ieee80211Common =
        Ieee80211Common(frame_control =
            Ieee80211FrameControl(frame_type = IEEE80211_TYPE_CONTROL,
                                  subtype = IEEE80211_SUBTYPE_CTS),
            receiver = MacAddress(0))
end

"""
    Ieee80211Rts(; receiver, transmitter, duration)

A request to send, sixteen octets — clause 9.3.1.2.
"""
@header Ieee80211Rts <: Ieee80211MacHeader begin
    base :: Ieee80211Common =
        Ieee80211Common(frame_control =
            Ieee80211FrameControl(frame_type = IEEE80211_TYPE_CONTROL,
                                  subtype = IEEE80211_SUBTYPE_RTS),
            receiver = MacAddress(0))
    transmitter :: MacAddress
end

"""
    Ieee80211PsPoll(; bssid, transmitter, association_id)

A power save poll, sixteen octets — clause 9.3.1.5. It is the frame whose
duration field is an association identifier rather than a duration.
"""
@header Ieee80211PsPoll <: Ieee80211MacHeader begin
    base :: Ieee80211Common =
        Ieee80211Common(frame_control =
            Ieee80211FrameControl(frame_type = IEEE80211_TYPE_CONTROL,
                                  subtype = IEEE80211_SUBTYPE_PS_POLL),
            receiver = MacAddress(0))
    transmitter :: MacAddress
end

"""
    Ieee80211BlockAckRequest(; receiver, transmitter, starting_sequence_number, …)

A block acknowledgement request, twenty octets — clause 9.3.1.7.

`compressed_bitmap` chooses which block acknowledgement the receiver sends
back. The two-octet BAR Information field is a four-bit fragment number and a
twelve-bit starting sequence number, which is where this frame differs from
INET's thirty-eight octets.
"""
@header Ieee80211BlockAckRequest <: Ieee80211MacHeader begin
    base :: Ieee80211Common =
        Ieee80211Common(frame_control =
            Ieee80211FrameControl(frame_type = IEEE80211_TYPE_CONTROL,
                                  subtype = IEEE80211_SUBTYPE_BLOCK_ACK_REQUEST),
            receiver = MacAddress(0))
    transmitter        :: MacAddress
    bar_ack_policy     :: Bool = false
    multi_tid          :: Bool = false
    compressed_bitmap  :: Bool = true
    reserved           :: U9   = 0
    tid                :: U4   = 0
    fragment_number    :: U4   = 0
    starting_sequence  :: U12  = 0
end

"""
    Ieee80211CompressedBlockAck(; receiver, transmitter, bitmap, …)

A compressed block acknowledgement, twenty-six octets — clause 9.3.1.8. Its
bitmap acknowledges sixty-four frames in eight octets.
"""
@header Ieee80211CompressedBlockAck <: Ieee80211MacHeader begin
    base :: Ieee80211Common =
        Ieee80211Common(frame_control =
            Ieee80211FrameControl(frame_type = IEEE80211_TYPE_CONTROL,
                                  subtype = IEEE80211_SUBTYPE_BLOCK_ACK),
            receiver = MacAddress(0))
    transmitter       :: MacAddress
    ba_ack_policy     :: Bool = false
    multi_tid         :: Bool = false
    compressed_bitmap :: Bool = true
    reserved          :: U9   = 0
    tid               :: U4   = 0
    fragment_number   :: U4   = 0
    starting_sequence :: U12  = 0
    bitmap            :: U64  = 0
end

"""
    Ieee80211BasicBlockAck(; receiver, transmitter, bitmap, …)

A basic block acknowledgement, one hundred and forty-eight octets — clause
9.3.1.8. Its bitmap acknowledges each fragment of sixty-four frames, so it
takes one hundred and twenty-eight octets.
"""
@header Ieee80211BasicBlockAck <: Ieee80211MacHeader begin
    base :: Ieee80211Common =
        Ieee80211Common(frame_control =
            Ieee80211FrameControl(frame_type = IEEE80211_TYPE_CONTROL,
                                  subtype = IEEE80211_SUBTYPE_BLOCK_ACK),
            receiver = MacAddress(0))
    transmitter       :: MacAddress
    ba_ack_policy     :: Bool = false
    multi_tid         :: Bool = false
    compressed_bitmap :: Bool = false
    reserved          :: U9   = 0
    tid               :: U4   = 0
    fragment_number   :: U4   = 0
    starting_sequence :: U12  = 0
    bitmap            :: FixedOctets{128} = zeros(UInt8, 128)
end

# ---------- the data and management frames, clause 9.3.2 and 9.3.3 -----------

"""
    Ieee80211DataHeader(; receiver, transmitter, address3, sequence_control, …)

A data frame header — clause 9.3.2.1. Twenty-four octets, six more when the
frame travels between two access points, and two more when its subtype carries
quality-of-service control.
"""
@header Ieee80211DataHeader <: Ieee80211MacHeader begin
    base :: Ieee80211Common =
        Ieee80211Common(frame_control =
            Ieee80211FrameControl(frame_type = IEEE80211_TYPE_DATA,
                                  subtype = IEEE80211_SUBTYPE_DATA),
            receiver = MacAddress(0))
    transmitter      :: MacAddress
    address3         :: MacAddress
    sequence_control :: Ieee80211SequenceControl = Ieee80211SequenceControl()
    address4         :: Optional{MacAddress} = nothing
        when(has_fourth_address(base.frame_control))
    qos_control      :: Optional{U16} = nothing
        when(has_qos_control(base.frame_control))
end

"""
    Ieee80211MgmtHeader(; receiver, transmitter, bssid, sequence_control, …)

A management frame header, twenty-four octets — clause 9.3.3.2. A beacon, a
probe, an association and an authentication all start with it, and their bodies
follow as chunks of their own.
"""
@header Ieee80211MgmtHeader <: Ieee80211MacHeader begin
    base :: Ieee80211Common =
        Ieee80211Common(frame_control =
            Ieee80211FrameControl(frame_type = IEEE80211_TYPE_MANAGEMENT,
                                  subtype = IEEE80211_SUBTYPE_BEACON),
            receiver = MacAddress(0))
    transmitter      :: MacAddress
    bssid            :: MacAddress
    sequence_control :: Ieee80211SequenceControl = Ieee80211SequenceControl()
end

# ---------- the block acknowledgement action frames, clause 9.6.5 ------------

"""
    Ieee80211AddbaRequest(; tid, buffer_size, starting_sequence, …)

An Add Block Acknowledgement request — clause 9.6.5.2. Thirty-three octets: the
management header and nine more.
"""
@header Ieee80211AddbaRequest <: Ieee80211MacHeader begin
    header            :: Ieee80211MgmtHeader
    category          :: Constant{U8, IEEE80211_CATEGORY_BLOCK_ACK}
    action            :: Constant{U8, IEEE80211_ACTION_ADDBA_REQUEST}
    dialog_token      :: U8   = 0
    amsdu_supported   :: Bool = false
    block_ack_policy  :: Bool = true
    tid               :: U4   = 0
    buffer_size       :: U10  = 0
    timeout           :: U16  = 0
    fragment_number   :: U4   = 0
    starting_sequence :: U12  = 0
end

"""
    Ieee80211AddbaResponse(; status_code, tid, buffer_size, …)

An Add Block Acknowledgement response — clause 9.6.5.3.
"""
@header Ieee80211AddbaResponse <: Ieee80211MacHeader begin
    header           :: Ieee80211MgmtHeader
    category         :: Constant{U8, IEEE80211_CATEGORY_BLOCK_ACK}
    action           :: Constant{U8, IEEE80211_ACTION_ADDBA_RESPONSE}
    dialog_token     :: U8   = 0
    status_code      :: U16  = 0
    amsdu_supported  :: Bool = false
    block_ack_policy :: Bool = true
    tid              :: U4   = 0
    buffer_size      :: U10  = 0
    timeout          :: U16  = 0
end

"""
    Ieee80211Delba(; tid, initiator, reason_code, …)

A Delete Block Acknowledgement — clause 9.6.5.4. `initiator` says which end is
tearing the agreement down.
"""
@header Ieee80211Delba <: Ieee80211MacHeader begin
    header      :: Ieee80211MgmtHeader
    category    :: Constant{U8, IEEE80211_CATEGORY_BLOCK_ACK}
    action      :: Constant{U8, IEEE80211_ACTION_DELBA}
    reserved    :: U11  = 0
    initiator   :: Bool = false
    tid         :: U4   = 0
    reason_code :: U16  = 0
end

"""
    Ieee80211ActionOther(; header, body)

An action frame whose category this library does not model. It keeps the body
verbatim, so the frame round-trips — the same answer an unknown option gets.
"""
@header Ieee80211ActionOther <: Ieee80211MacHeader begin
    header :: Ieee80211MgmtHeader
    body   :: Rest = UInt8[]
end

"""
    Ieee80211MacTrailer(; fcs)

The four octets of frame check sequence at the end of every IEEE 802.11 frame.
"""
@header Ieee80211MacTrailer begin
    fcs      :: U32 = 0
    fcs_mode :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

# ---------- the family -------------------------------------------------------

list_variants(::Type{Ieee80211MacHeader}) =
    (Ieee80211Rts, Ieee80211Cts, Ieee80211Ack, Ieee80211PsPoll,
     Ieee80211BlockAckRequest, Ieee80211DataHeader, Ieee80211MgmtHeader)
variant_base(::Type{Ieee80211MacHeader}) = Ieee80211Common

matches_variant(::Type{Ieee80211Rts}, base) =
    base.frame_control.frame_type == IEEE80211_TYPE_CONTROL &&
    base.frame_control.subtype == IEEE80211_SUBTYPE_RTS
matches_variant(::Type{Ieee80211Cts}, base) =
    base.frame_control.frame_type == IEEE80211_TYPE_CONTROL &&
    base.frame_control.subtype == IEEE80211_SUBTYPE_CTS
matches_variant(::Type{Ieee80211Ack}, base) =
    base.frame_control.frame_type == IEEE80211_TYPE_CONTROL &&
    base.frame_control.subtype == IEEE80211_SUBTYPE_ACK
matches_variant(::Type{Ieee80211PsPoll}, base) =
    base.frame_control.frame_type == IEEE80211_TYPE_CONTROL &&
    base.frame_control.subtype == IEEE80211_SUBTYPE_PS_POLL
matches_variant(::Type{Ieee80211BlockAckRequest}, base) =
    base.frame_control.frame_type == IEEE80211_TYPE_CONTROL &&
    base.frame_control.subtype == IEEE80211_SUBTYPE_BLOCK_ACK_REQUEST
matches_variant(::Type{Ieee80211DataHeader}, base) =
    base.frame_control.frame_type == IEEE80211_TYPE_DATA
matches_variant(::Type{Ieee80211MgmtHeader}, base) =
    base.frame_control.frame_type == IEEE80211_TYPE_MANAGEMENT
