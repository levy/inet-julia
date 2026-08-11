# ============================================================================
# Mobile IPv6 — RFC 6275.
#
# A mobile node keeps one home address wherever it goes, and tells its home
# agent where it is with a Binding Update. These are the messages that say so.
#
# They all travel in a Mobility Header, whose first six octets are the same
# every time and whose type octet says which message follows. RFC 6275 clause
# 6.1 makes the whole header a multiple of eight octets, so each member ends
# with padding to that boundary.
#
# `header_length` counts eight-octet units after the first eight, the way every
# IPv6 extension header does. It derives from the message.
#
# INET adds Proxy Mobile IPv6 fields to the Binding Update and the Binding
# Acknowledgement, behind a flag. Those are RFC 5213's, not RFC 6275's, and
# they are not declared here — the messages below are the ones RFC 6275 draws.
# ============================================================================

const MIPV6_BINDING_REFRESH_REQUEST = 0
const MIPV6_HOME_TEST_INIT          = 1
const MIPV6_CARE_OF_TEST_INIT       = 2
const MIPV6_HOME_TEST               = 3
const MIPV6_CARE_OF_TEST            = 4
const MIPV6_BINDING_UPDATE          = 5
const MIPV6_BINDING_ACKNOWLEDGEMENT = 6
const MIPV6_BINDING_ERROR           = 7

"A binding lifetime is in four-second units — RFC 6275 clause 6.1.7."
const MIPV6_LIFETIME_UNIT = 4

"The Mobility Header carries no next header of its own — RFC 6275 clause 6.1."
const MIPV6_NO_NEXT_HEADER = 59

"The Mobile IPv6 messages — one wire format, and the type octet says which."
abstract type MobilityHeader <: Fields end

"""
    MobilityCommon(; mobility_type, header_length, checksum)

The six octets every Mobility Header starts with — RFC 6275 clause 6.1.

`payload_protocol` is always 59, "no next header": a Mobility Header is the last
header in the datagram.
"""
@header MobilityCommon <: MobilityHeader begin
    payload_protocol :: U8 = MIPV6_NO_NEXT_HEADER
    header_length    :: U8 = 0
    mobility_type    :: U8 = MIPV6_BINDING_REFRESH_REQUEST
    reserved         :: U8 = 0
    checksum         :: Checksum16 = 0
    checksum_mode    :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

"""
    Mipv6BindingRefreshRequest()

A Binding Refresh Request, eight octets — RFC 6275 clause 6.1.2. A home agent
sends it to ask a mobile node to renew its binding.
"""
@header Mipv6BindingRefreshRequest <: MobilityHeader begin
    base      :: MobilityCommon =
        MobilityCommon(mobility_type = MIPV6_BINDING_REFRESH_REQUEST)
    reserved2 :: U16 = 0
end

"""
    Mipv6HomeTestInit(; cookie)

A Home Test Init, sixteen octets — RFC 6275 clause 6.1.3. It starts the home
half of the return routability test.
"""
@header Mipv6HomeTestInit <: MobilityHeader begin
    base      :: MobilityCommon = MobilityCommon(mobility_type = MIPV6_HOME_TEST_INIT)
    reserved2 :: U16 = 0
    cookie    :: U64 = 0
end

"""
    Mipv6CareOfTestInit(; cookie)

A Care-of Test Init, sixteen octets — RFC 6275 clause 6.1.4. It starts the
care-of half of the same test.
"""
@header Mipv6CareOfTestInit <: MobilityHeader begin
    base      :: MobilityCommon = MobilityCommon(mobility_type = MIPV6_CARE_OF_TEST_INIT)
    reserved2 :: U16 = 0
    cookie    :: U64 = 0
end

"""
    Mipv6HomeTest(; nonce_index, cookie, key_generation_token)

A Home Test, twenty-four octets — RFC 6275 clause 6.1.5. It answers a Home Test
Init with the token half the mobile node needs.
"""
@header Mipv6HomeTest <: MobilityHeader begin
    base                 :: MobilityCommon =
        MobilityCommon(mobility_type = MIPV6_HOME_TEST)
    nonce_index          :: U16 = 0
    cookie               :: U64 = 0
    key_generation_token :: U64 = 0
end

"""
    Mipv6CareOfTest(; nonce_index, cookie, key_generation_token)

A Care-of Test, twenty-four octets — RFC 6275 clause 6.1.6. It answers a
Care-of Test Init with the other token half.
"""
@header Mipv6CareOfTest <: MobilityHeader begin
    base                 :: MobilityCommon =
        MobilityCommon(mobility_type = MIPV6_CARE_OF_TEST)
    nonce_index          :: U16 = 0
    cookie               :: U64 = 0
    key_generation_token :: U64 = 0
end

"""
    Mipv6BindingUpdate(; sequence_number, lifetime, home_registration, …)

A Binding Update, sixteen octets — RFC 6275 clause 6.1.7. It tells a home agent
or a correspondent node where the mobile node is now.

`lifetime` is in four-second units, so a binding of one hour carries 900.
"""
@header Mipv6BindingUpdate <: MobilityHeader begin
    base                :: MobilityCommon =
        MobilityCommon(mobility_type = MIPV6_BINDING_UPDATE)
    sequence_number     :: U16  = 0
    acknowledge         :: Bool = false
    home_registration   :: Bool = false
    link_local_compatible :: Bool = false
    key_management      :: Bool = false
    reserved2           :: U12  = 0
    lifetime            :: U16  = 0
    padding             :: Pad{Bytes(8), 0x00}
end

"""
    Mipv6BindingAcknowledgement(; status, sequence_number, lifetime, …)

A Binding Acknowledgement, sixteen octets — RFC 6275 clause 6.1.8. A status
below 128 accepts the binding; 128 and above refuses it.
"""
@header Mipv6BindingAcknowledgement <: MobilityHeader begin
    base            :: MobilityCommon =
        MobilityCommon(mobility_type = MIPV6_BINDING_ACKNOWLEDGEMENT)
    status          :: U8   = 0
    key_management  :: Bool = false
    reserved2       :: U7   = 0
    sequence_number :: U16  = 0
    lifetime        :: U16  = 0
    padding         :: Pad{Bytes(8), 0x00}
end

"""
    Mipv6BindingError(; status, home_address)

A Binding Error, twenty-four octets — RFC 6275 clause 6.1.9. A correspondent
node sends it when it has no binding for the home address it was asked about.
"""
@header Mipv6BindingError <: MobilityHeader begin
    base         :: MobilityCommon =
        MobilityCommon(mobility_type = MIPV6_BINDING_ERROR)
    status       :: U8 = 1
    reserved2    :: U8 = 0
    home_address :: Ipv6Address
end

"The binding lifetime in seconds — the field counts four-second units."
measure_binding_seconds(lifetime::Integer) = Int(lifetime) * MIPV6_LIFETIME_UNIT

"The lifetime field a binding of `seconds` needs."
build_binding_lifetime(seconds::Integer) =
    U16(min(seconds ÷ MIPV6_LIFETIME_UNIT, 0xffff))

list_variants(::Type{MobilityHeader}) =
    (Mipv6BindingRefreshRequest, Mipv6HomeTestInit, Mipv6CareOfTestInit,
     Mipv6HomeTest, Mipv6CareOfTest, Mipv6BindingUpdate,
     Mipv6BindingAcknowledgement, Mipv6BindingError)
variant_base(::Type{MobilityHeader}) = MobilityCommon

matches_variant(::Type{Mipv6BindingRefreshRequest}, base) =
    base.mobility_type == MIPV6_BINDING_REFRESH_REQUEST
matches_variant(::Type{Mipv6HomeTestInit}, base) =
    base.mobility_type == MIPV6_HOME_TEST_INIT
matches_variant(::Type{Mipv6CareOfTestInit}, base) =
    base.mobility_type == MIPV6_CARE_OF_TEST_INIT
matches_variant(::Type{Mipv6HomeTest}, base)    = base.mobility_type == MIPV6_HOME_TEST
matches_variant(::Type{Mipv6CareOfTest}, base)  = base.mobility_type == MIPV6_CARE_OF_TEST
matches_variant(::Type{Mipv6BindingUpdate}, base) =
    base.mobility_type == MIPV6_BINDING_UPDATE
matches_variant(::Type{Mipv6BindingAcknowledgement}, base) =
    base.mobility_type == MIPV6_BINDING_ACKNOWLEDGEMENT
matches_variant(::Type{Mipv6BindingError}, base) =
    base.mobility_type == MIPV6_BINDING_ERROR
