# ============================================================================
# IGMP — RFC 1112, RFC 2236 and RFC 3376, as a variant family.
#
# Every IGMP message starts with the same four octets: a type, a second octet
# and a checksum. RFC 2236 section 2 names the second octet Max Resp Time for
# the whole family and says a report and a leave leave it zero; RFC 3376 calls
# it Max Resp Code in a version 3 query. One name, one field.
#
# Three members share the Membership Query type octet, and only the length
# tells them apart. RFC 3376 section 7.1 states the rule: a query of eight
# octets is version 1 when its second octet is zero and version 2 when it is
# not, and a query longer than eight octets is version 3. Those three members
# therefore read the length as well as the base.
#
# RGMP — RFC 3488 — is here because it borrows the IGMP message format and its
# own type octet, so a reader that knows IGMP already reads it.
# ============================================================================

const IGMP_MEMBERSHIP_QUERY    = 0x11
const IGMPV1_MEMBERSHIP_REPORT = 0x12
const IGMPV2_MEMBERSHIP_REPORT = 0x16
const IGMPV2_LEAVE_GROUP       = 0x17
const IGMPV3_MEMBERSHIP_REPORT = 0x22
const RGMP_HELLO               = 0xff

"A version 1 or version 2 message is eight octets; a version 3 query is longer."
const IGMP_MESSAGE_BYTES = 8

"The group record types of RFC 3376 section 4.2.12."
const IGMP_MODE_IS_INCLUDE        = 1
const IGMP_MODE_IS_EXCLUDE        = 2
const IGMP_CHANGE_TO_INCLUDE_MODE = 3
const IGMP_CHANGE_TO_EXCLUDE_MODE = 4
const IGMP_ALLOW_NEW_SOURCES      = 5
const IGMP_BLOCK_OLD_SOURCES      = 6

"The IGMP messages — one wire format, and the type says which."
abstract type IgmpMessage <: Fields end

"""
    IgmpCommon(; type, max_response_time, checksum)

The four octets every IGMP message starts with. It is what a reader looks at to
decide which message this is, and every member embeds it.

`max_response_time` is in tenths of a second in a version 1 or 2 query. A
report and a leave send zero.
"""
@header IgmpCommon begin
    type              :: U8
    max_response_time :: U8         = 0
    checksum          :: Checksum16 = 0
    checksum_mode     :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

"""
    IgmpHeader(; base, unused)

An IGMP message this library does not model, eight octets. A message no member
claims comes back as this, marked misrepresented, with its bytes intact.
"""
@header IgmpHeader <: IgmpMessage begin
    base   :: IgmpCommon
    unused :: U32 = 0
end

# ---------- the queries ------------------------------------------------------

"""
    Igmpv1Query(; group_address)

A version 1 Host Membership Query, eight octets — RFC 1112 appendix I. Its
second octet is unused and zero, which is what separates it from a version 2
query of the same width.
"""
@header Igmpv1Query <: IgmpMessage begin
    base          :: IgmpCommon = IgmpCommon(type = IGMP_MEMBERSHIP_QUERY)
    group_address :: Ipv4Address
end

"""
    Igmpv2Query(; group_address, max_response_time)

A version 2 Membership Query, eight octets — RFC 2236 section 2. A group
address of zero makes it a general query.
"""
@header Igmpv2Query <: IgmpMessage begin
    base          :: IgmpCommon = IgmpCommon(type = IGMP_MEMBERSHIP_QUERY)
    group_address :: Ipv4Address
end

"""
    Igmpv3Query(; group_address, sources, robustness, query_interval_code, …)

A version 3 Membership Query — RFC 3376 section 4.1, twelve octets and four
more for each source.

`suppress_router_processing` is the S flag and `robustness` is the QRV.
"""
@header Igmpv3Query <: IgmpMessage begin
    base                       :: IgmpCommon = IgmpCommon(type = IGMP_MEMBERSHIP_QUERY)
    group_address              :: Ipv4Address
    reserved                   :: U4   = 0
    suppress_router_processing :: Bool = false
    robustness                 :: U3   = 0
    query_interval_code        :: U8   = 0
    number_of_sources          :: U16  = 0
        derive(Base.length(sources))
    sources                    :: Repeated{Ipv4Address} = Ipv4Address[]
        count(number_of_sources)
end

# ---------- the reports and the leave ----------------------------------------

"""
    Igmpv1Report(; group_address)

A version 1 Host Membership Report, eight octets — RFC 1112 appendix I.
"""
@header Igmpv1Report <: IgmpMessage begin
    base          :: IgmpCommon = IgmpCommon(type = IGMPV1_MEMBERSHIP_REPORT)
    group_address :: Ipv4Address
end

"""
    Igmpv2Report(; group_address)

A version 2 Membership Report, eight octets — RFC 2236 section 2.
"""
@header Igmpv2Report <: IgmpMessage begin
    base          :: IgmpCommon = IgmpCommon(type = IGMPV2_MEMBERSHIP_REPORT)
    group_address :: Ipv4Address
end

"""
    Igmpv2Leave(; group_address)

A Leave Group message, eight octets — RFC 2236 section 2. A host sends it to
the all-routers group when it stops listening.
"""
@header Igmpv2Leave <: IgmpMessage begin
    base          :: IgmpCommon = IgmpCommon(type = IGMPV2_LEAVE_GROUP)
    group_address :: Ipv4Address
end

"""
    Igmpv3GroupRecord(; record_type, group_address, sources)

One record of a version 3 report — RFC 3376 section 4.2.4. `auxiliary_length`
counts thirty-two-bit words, and RFC 3376 defines no auxiliary data yet.
"""
@header Igmpv3GroupRecord begin
    record_type       :: U8
    auxiliary_length  :: U8  = 0
        derive(Base.length(auxiliary_data))
    number_of_sources :: U16 = 0
        derive(Base.length(sources))
    group_address     :: Ipv4Address
    sources           :: Repeated{Ipv4Address} = Ipv4Address[]
        count(number_of_sources)
    auxiliary_data    :: Repeated{U32} = U32[]
        count(auxiliary_length)
end

"""
    Igmpv3Report(; group_records)

A version 3 Membership Report — RFC 3376 section 4.2. No two records are the
same width, so the list fills the message and `number_of_group_records` is what
the writer derives from it.
"""
@header Igmpv3Report <: IgmpMessage begin
    base                    :: IgmpCommon = IgmpCommon(type = IGMPV3_MEMBERSHIP_REPORT)
    reserved                :: U16 = 0
    number_of_group_records :: U16 = 0
        derive(Base.length(group_records))
    group_records           :: Repeated{Igmpv3GroupRecord} = Igmpv3GroupRecord[]
end

# ---------- RGMP, RFC 3488 ---------------------------------------------------

"""
    RgmpHello(; group_address)

An RGMP Hello, eight octets — RFC 3488 section 3. A router sends it to
224.0.0.25 to turn RGMP on, and it borrows the IGMP message format.
"""
@header RgmpHello <: IgmpMessage begin
    base          :: IgmpCommon = IgmpCommon(type = RGMP_HELLO)
    group_address :: Ipv4Address
end

# ---------- the family -------------------------------------------------------

list_variants(::Type{IgmpMessage}) =
    (Igmpv3Query, Igmpv1Query, Igmpv2Query, Igmpv1Report, Igmpv2Report,
     Igmpv2Leave, Igmpv3Report, RgmpHello)
variant_base(::Type{IgmpMessage}) = IgmpCommon
variant_fallback(::Type{IgmpMessage}) = IgmpHeader

matches_variant(::Type{Igmpv1Report}, base) = base.type == IGMPV1_MEMBERSHIP_REPORT
matches_variant(::Type{Igmpv2Report}, base) = base.type == IGMPV2_MEMBERSHIP_REPORT
matches_variant(::Type{Igmpv2Leave}, base)  = base.type == IGMPV2_LEAVE_GROUP
matches_variant(::Type{Igmpv3Report}, base) = base.type == IGMPV3_MEMBERSHIP_REPORT
matches_variant(::Type{RgmpHello}, base)    = base.type == RGMP_HELLO

# The three queries share a type octet — RFC 3376 section 7.1.
matches_variant(::Type{Igmpv1Query}, base, available::Int) =
    base.type == IGMP_MEMBERSHIP_QUERY &&
    available <= bits(Bytes(IGMP_MESSAGE_BYTES)) && base.max_response_time == 0
matches_variant(::Type{Igmpv2Query}, base, available::Int) =
    base.type == IGMP_MEMBERSHIP_QUERY &&
    available <= bits(Bytes(IGMP_MESSAGE_BYTES)) && base.max_response_time != 0
matches_variant(::Type{Igmpv3Query}, base, available::Int) =
    base.type == IGMP_MEMBERSHIP_QUERY && available > bits(Bytes(IGMP_MESSAGE_BYTES))
