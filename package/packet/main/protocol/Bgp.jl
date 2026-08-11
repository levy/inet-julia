# ============================================================================
# The border gateway protocol, version 4 — RFC 4271.
#
# Every message starts with the same nineteen octets: a sixteen-octet marker of
# all ones, the length of the whole message, and the type. The type says which
# of the four messages this is.
#
# One gap in INET is filled here. `BgpHeaderSerializer` writes an OPEN, an
# UPDATE and a KEEPALIVE, and throws on a NOTIFICATION. RFC 4271 clause 4.5
# defines it, and it is the message a speaker sends before it closes a session
# — so a capture of a session that went wrong is exactly the capture INET
# cannot write. It is declared.
#
# `BgpUpdate` is not here yet. Section 3.7 of the plan says what it needs: a
# prefix whose length field counts bits, and a path attribute whose flags octet
# decides whether its own length field is one octet or two.
# ============================================================================

const BGP_OPEN         = 1
const BGP_UPDATE       = 2
const BGP_NOTIFICATION = 3
const BGP_KEEPALIVE    = 4

"The header every message starts with is nineteen octets — RFC 4271 clause 4.1."
const BGP_HEADER_BYTES    = 19
const BGP_OPEN_BYTES      = 29
const BGP_MAX_MESSAGE_BYTES = 4096

"The version every speaker must send — RFC 4271 clause 4.2."
const BGP_VERSION = 4

"The marker is all ones — RFC 4271 clause 4.1."
const BGP_MARKER = fill(0xff, 16)

"The optional parameter types of an OPEN message — RFC 4271 clause 4.2."
const BGP_PARAMETER_CAPABILITIES = 2

"The capability codes — RFC 5492 and RFC 4760."
const BGP_CAPABILITY_MULTIPROTOCOL = 1

"The error codes a NOTIFICATION carries — RFC 4271 clause 4.5."
const BGP_ERROR_MESSAGE_HEADER = 1
const BGP_ERROR_OPEN_MESSAGE   = 2
const BGP_ERROR_UPDATE_MESSAGE = 3
const BGP_ERROR_HOLD_TIMER     = 4
const BGP_ERROR_FINITE_STATE   = 5
const BGP_ERROR_CEASE          = 6

"The BGP messages — one wire format, and the type octet says which."
abstract type BgpMessage <: Fields end

"""
    BgpCommon(; type, total_length)

The nineteen octets every BGP message starts with — RFC 4271 clause 4.1.

`total_length` counts the whole message, this header included, and RFC 4271
bounds it between nineteen and 4096. It is a field the sender sets: it measures
the message, and a shared header cannot measure the member that embeds it.
"""
@header BgpCommon <: BgpMessage begin
    marker       :: FixedOctets{16} = fill(0xff, 16)
    total_length :: U16 = BGP_HEADER_BYTES
    type         :: U8  = BGP_KEEPALIVE
end

"""
    BgpKeepAlive()

A KEEPALIVE, nineteen octets — RFC 4271 clause 4.4. It is the header and
nothing else.
"""
@header BgpKeepAlive <: BgpMessage begin
    base :: BgpCommon = BgpCommon(type = BGP_KEEPALIVE,
                                  total_length = BGP_HEADER_BYTES)
end

# ---------- the optional parameters of an OPEN message -----------------------

"The OPEN message's optional parameters — one shape, and the type says which."
abstract type BgpParameter <: Fields end

"""
    BgpCapabilityMultiprotocol(; address_family, subsequent_family)

A Multiprotocol Extensions capability, four octets of value — RFC 4760 clause
8. It says which address families this speaker will carry.
"""
@header BgpCapabilityMultiprotocol begin
    code              :: Constant{U8, BGP_CAPABILITY_MULTIPROTOCOL}
    length            :: Constant{U8, 4}
    address_family    :: U16 = 1
    reserved          :: U8  = 0
    subsequent_family :: U8  = 1
end

"""
    BgpParameterCapabilities(; capabilities)

The Capabilities optional parameter — RFC 5492 clause 4. Its value is a list of
capabilities, each with a code, a length and a value.
"""
@header BgpParameterCapabilities <: BgpParameter begin
    type         :: Constant{U8, BGP_PARAMETER_CAPABILITIES}
    length       :: U8 = 0
        derive(measure_header(h) ÷ 8 - 2)
    capabilities :: Repeated{BgpCapabilityMultiprotocol} =
        BgpCapabilityMultiprotocol[]
        until(Bytes(length) + Bytes(2))
end

"""
    BgpParameterRaw(; type, value)

An optional parameter this library does not model. It keeps its type and its
octets.
"""
@header BgpParameterRaw <: BgpParameter begin
    type   :: U8
    length :: U8 = 0
        derive(Base.length(value))
    value  :: Octets = UInt8[]
        length(Bytes(length))
end

list_options(::Type{BgpParameter}) = (BgpParameterCapabilities,)
find_raw_option(::Type{BgpParameter}) = BgpParameterRaw

# ---------- the messages -----------------------------------------------------

"""
    BgpOpen(; my_as, hold_time, identifier, parameters)

An OPEN message — RFC 4271 clause 4.2. Twenty-nine octets and whatever its
optional parameters take.

`hold_time` is in seconds and must be zero or at least three. `identifier` is
the speaker's BGP identifier, which is an IPv4 address whether or not the
session carries IPv4.
"""
@header BgpOpen <: BgpMessage begin
    base       :: BgpCommon = BgpCommon(type = BGP_OPEN,
                                        total_length = BGP_OPEN_BYTES)
    version    :: U8  = BGP_VERSION
        check(version == BGP_VERSION)
    my_as      :: U16 = 0
    hold_time  :: U16 = 0
    identifier :: Ipv4Address
    parameters_length :: U8 = 0
        derive(measure_header(h) ÷ 8 - BGP_OPEN_BYTES)
    parameters :: Options{BgpParameter} = BgpParameter[]
        until(Bytes(parameters_length) + Bytes(BGP_OPEN_BYTES))
end

"""
    BgpNotification(; error_code, error_subcode, data)

A NOTIFICATION message — RFC 4271 clause 4.5. Twenty-one octets and whatever
data the error carries.

INET does not write this message; its serializer throws on the type. It is the
message a speaker sends before it closes a session, so a capture of a session
that failed is the capture INET cannot produce.
"""
@header BgpNotification <: BgpMessage begin
    base          :: BgpCommon = BgpCommon(type = BGP_NOTIFICATION,
                                           total_length = 21)
    error_code    :: U8 = BGP_ERROR_CEASE
    error_subcode :: U8 = 0
    data          :: Rest = UInt8[]
end

list_variants(::Type{BgpMessage}) = (BgpOpen, BgpNotification, BgpKeepAlive)
variant_base(::Type{BgpMessage}) = BgpCommon

matches_variant(::Type{BgpOpen}, base)         = base.type == BGP_OPEN
matches_variant(::Type{BgpNotification}, base) = base.type == BGP_NOTIFICATION
matches_variant(::Type{BgpKeepAlive}, base)    = base.type == BGP_KEEPALIVE
