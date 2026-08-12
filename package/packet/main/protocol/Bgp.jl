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
bounds it between nineteen and 4096. It is a measurement, so every member
derives it: the header alone cannot measure the message, but the member that
embeds it can.
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
        derive(set_field(base, :total_length, measure_header(h) ÷ 8))
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
        derive(set_field(base, :total_length, measure_header(h) ÷ 8))
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
        derive(set_field(base, :total_length, measure_header(h) ÷ 8))
    error_code    :: U8 = BGP_ERROR_CEASE
    error_subcode :: U8 = 0
    data          :: Rest = UInt8[]
end


# ---------- the UPDATE message, RFC 4271 clause 4.3 --------------------------
#
# Two shapes nothing else in the inventory has.
#
#   * A prefix whose length field counts BITS. A route is a length octet and
#     then that many bits, padded up to a whole octet — so a /24 takes three
#     octets and a /0 takes none. RFC 4760 clause 3 uses the same shape for an
#     IPv6 prefix, so one header serves both; INET declares two structs.
#   * A field whose own length field changes width. A path attribute's flags
#     octet carries an Extended Length bit, and that bit decides whether the
#     attribute's length is one octet or two. Every other length field in the
#     inventory has a fixed width. The `when` clause already says it: the high
#     octet is there exactly when the bit is set.

"An UPDATE with nothing in it is twenty-three octets — RFC 4271 clause 4.3."
const BGP_UPDATE_BYTES = 23

"The path attribute type codes — RFC 4271 clause 5 and RFC 4760."
const BGP_ATTRIBUTE_ORIGIN           = 1
const BGP_ATTRIBUTE_AS_PATH          = 2
const BGP_ATTRIBUTE_NEXT_HOP         = 3
const BGP_ATTRIBUTE_MULTI_EXIT_DISC  = 4
const BGP_ATTRIBUTE_LOCAL_PREFERENCE = 5
const BGP_ATTRIBUTE_ATOMIC_AGGREGATE = 6
const BGP_ATTRIBUTE_AGGREGATOR       = 7
const BGP_ATTRIBUTE_MP_REACH_NLRI    = 14
const BGP_ATTRIBUTE_MP_UNREACH_NLRI  = 15

"Where a route came from — RFC 4271 clause 5.1.1."
const BGP_ORIGIN_IGP        = 0
const BGP_ORIGIN_EGP        = 1
const BGP_ORIGIN_INCOMPLETE = 2

"The AS path segment types — RFC 4271 clause 5.1.2."
const BGP_AS_SET      = 1
const BGP_AS_SEQUENCE = 2

"""
    measure_prefix_octets(prefix_length)::Int

How many octets a prefix of `prefix_length` bits takes — RFC 4271 clause 4.3
pads the prefix up to a whole octet, so a /24 takes three and a /0 takes none.
"""
measure_prefix_octets(prefix_length) = cld(Int(prefix_length), 8)

"""
    BgpPrefix(; prefix_length, prefix)

One route — RFC 4271 clause 4.3. A length in bits and that many bits of prefix,
padded with zeros up to a whole octet.

This is the withdrawn route, the reachability information, and the IPv6 forms of
both in RFC 4760 clauses 3 and 4. One shape, so one header; INET declares an
IPv4 struct and an IPv6 struct that write the same octets.

`prefix_length` and `prefix` must agree, and both carry the check because either
one can be the one that is wrong.
"""
@header BgpPrefix begin
    prefix_length :: U8 = 0
        check(Base.length(prefix) == measure_prefix_octets(prefix_length))
    prefix        :: Octets = UInt8[]
        length(Bytes(measure_prefix_octets(prefix_length)))
        check(Base.length(prefix) == measure_prefix_octets(prefix_length))
end

"The path attributes — one shape, and the type code says which."
abstract type BgpAttribute <: Fields end

"""
    BgpAttributeHeader(; type_code, optional, transitive, partial, extended_length)

The flags, the type code and the length every path attribute starts with — RFC
4271 clause 4.3.

The length is one octet or two, and the Extended Length bit decides which. The
high octet is therefore a field that is there only when the bit is set, and
`measure_attribute_length` reads the pair as one number.

The high octet defaults to zero rather than to absent, so a header that sets the
bit has the octet the bit promises. A reader gives it back absent when the bit
is clear, because then it was never on the wire.

RFC 4271 clause 4.3 also constrains the flags: a well-known attribute must be
transitive and must not be partial, and an optional non-transitive attribute
must not be partial. Neither rule is a `check` here, because a check on a header
that another header embeds turns a malformed packet into an error instead of a
mark.
"""
@header BgpAttributeHeader begin
    optional        :: Bool = false
    transitive      :: Bool = true
    partial         :: Bool = false
    extended_length :: Bool = false
    reserved        :: U4 = 0
    type_code       :: U8 = BGP_ATTRIBUTE_ORIGIN
    length_high     :: Optional{U8} = 0
        when(extended_length)
    length_low      :: U8 = 0
end

"How many octets an attribute header takes — three, or four when it is extended."
measure_attribute_header_bytes(base) = base.extended_length ? 4 : 3

"The attribute length, read from the one or two octets that carry it."
measure_attribute_length(base) =
    (base.length_high === nothing ? 0 : 256 * Int(base.length_high)) +
    Int(base.length_low)

"The offset an attribute ends at, counted from the start of the attribute."
measure_attribute_end(base) =
    measure_attribute_header_bytes(base) + measure_attribute_length(base)

"""
    set_attribute_length(base, value_bytes::Int)

The same header with its length set to `value_bytes`, in the one or two octets
the Extended Length bit asks for.
"""
function set_attribute_length(base, value_bytes::Int)
    if base.extended_length
        value_bytes <= 0xffff ||
            error("set_attribute_length: $(value_bytes) octets does not fit in two")
        return set_field(set_field(base, :length_high, UInt8(value_bytes >> 8)),
                         :length_low, UInt8(value_bytes & 0xff))
    end
    value_bytes <= 0xff ||
        error("set_attribute_length: $(value_bytes) octets needs the extended " *
              "length bit")
    return set_field(base, :length_low, UInt8(value_bytes))
end

"The length an attribute header carries, measured from the attribute that holds it."
measure_attribute_value(h, base) =
    set_attribute_length(base, measure_header(h) ÷ 8 -
                               measure_attribute_header_bytes(base))

"""
    BgpAttributeOrigin(; value)

The ORIGIN attribute — RFC 4271 clause 5.1.1. One octet that says whether the
route came from inside the autonomous system, from an exterior protocol, or from
somewhere the speaker cannot name.
"""
@header BgpAttributeOrigin <: BgpAttribute begin
    base  :: BgpAttributeHeader =
        BgpAttributeHeader(type_code = BGP_ATTRIBUTE_ORIGIN)
        derive(measure_attribute_value(h, base))
    value :: U8 = BGP_ORIGIN_IGP
end

"""
    BgpAsPathSegment(; type, as_numbers)

One segment of an AS path — RFC 4271 clause 5.1.2. Its length counts AS numbers,
not octets, which is why the segment carries a count and not a length.
"""
@header BgpAsPathSegment begin
    type       :: U8 = BGP_AS_SEQUENCE
    length     :: U8 = 0
        derive(Base.length(as_numbers))
    as_numbers :: Repeated{U16} = UInt16[]
        count(length)
end

"""
    BgpAttributeAsPath(; segments)

The AS_PATH attribute — RFC 4271 clause 5.1.2. The autonomous systems a route
has crossed, as an ordered list of segments. Nothing counts the segments: they
run to the end of the attribute.
"""
@header BgpAttributeAsPath <: BgpAttribute begin
    base     :: BgpAttributeHeader =
        BgpAttributeHeader(type_code = BGP_ATTRIBUTE_AS_PATH)
        derive(measure_attribute_value(h, base))
    segments :: Repeated{BgpAsPathSegment} = BgpAsPathSegment[]
        until(Bytes(measure_attribute_end(base)))
end

"""
    BgpAttributeNextHop(; value)

The NEXT_HOP attribute — RFC 4271 clause 5.1.3. The address of the router that
should be the next hop for the destinations this UPDATE announces.
"""
@header BgpAttributeNextHop <: BgpAttribute begin
    base  :: BgpAttributeHeader =
        BgpAttributeHeader(type_code = BGP_ATTRIBUTE_NEXT_HOP)
        derive(measure_attribute_value(h, base))
    value :: Ipv4Address = Ipv4Address(0)
end

"""
    BgpAttributeMultiExitDiscriminator(; value)

The MULTI_EXIT_DISC attribute — RFC 4271 clause 5.1.4. It tells a neighbouring
autonomous system which of several entry points to prefer, and the lower value
wins.
"""
@header BgpAttributeMultiExitDiscriminator <: BgpAttribute begin
    base  :: BgpAttributeHeader =
        BgpAttributeHeader(type_code = BGP_ATTRIBUTE_MULTI_EXIT_DISC,
                           optional = true, transitive = false)
        derive(measure_attribute_value(h, base))
    value :: U32 = 0
end

"""
    BgpAttributeLocalPreference(; value)

The LOCAL_PREF attribute — RFC 4271 clause 5.1.5. How much this autonomous
system prefers the route, and the higher value wins. It never leaves the
autonomous system.
"""
@header BgpAttributeLocalPreference <: BgpAttribute begin
    base  :: BgpAttributeHeader =
        BgpAttributeHeader(type_code = BGP_ATTRIBUTE_LOCAL_PREFERENCE)
        derive(measure_attribute_value(h, base))
    value :: U32 = 100
end

"""
    BgpAttributeAtomicAggregate()

The ATOMIC_AGGREGATE attribute — RFC 4271 clause 5.1.6. It has no value at all:
its presence says that the speaker chose a less specific route where a more
specific one was available.
"""
@header BgpAttributeAtomicAggregate <: BgpAttribute begin
    base :: BgpAttributeHeader =
        BgpAttributeHeader(type_code = BGP_ATTRIBUTE_ATOMIC_AGGREGATE)
        derive(measure_attribute_value(h, base))
end

"""
    BgpAttributeAggregator(; as_number, speaker)

The AGGREGATOR attribute — RFC 4271 clause 5.1.7. It names the autonomous system
and the speaker that formed the aggregate route.
"""
@header BgpAttributeAggregator <: BgpAttribute begin
    base      :: BgpAttributeHeader =
        BgpAttributeHeader(type_code = BGP_ATTRIBUTE_AGGREGATOR, optional = true)
        derive(measure_attribute_value(h, base))
    as_number :: U16 = 0
    speaker   :: Ipv4Address = Ipv4Address(0)
end

"""
    BgpAttributeMpReachNlri(; address_family, subsequent_family, next_hop, prefixes)

The MP_REACH_NLRI attribute — RFC 4760 clause 3. It announces routes for an
address family the message header cannot name, and it carries its own next hop.

`next_hop` is as many octets as `next_hop_length` says, so one attribute serves
every address family.
"""
@header BgpAttributeMpReachNlri <: BgpAttribute begin
    base              :: BgpAttributeHeader =
        BgpAttributeHeader(type_code = BGP_ATTRIBUTE_MP_REACH_NLRI, optional = true)
        derive(measure_attribute_value(h, base))
    address_family    :: U16 = 2
    subsequent_family :: U8  = 1
    next_hop_length   :: U8  = 0
        derive(Base.length(next_hop))
    next_hop          :: Octets = UInt8[]
        length(Bytes(next_hop_length))
    reserved          :: U8 = 0
    prefixes          :: Repeated{BgpPrefix} = BgpPrefix[]
        until(Bytes(measure_attribute_end(base)))
end

"""
    BgpAttributeMpUnreachNlri(; address_family, subsequent_family, withdrawn_routes)

The MP_UNREACH_NLRI attribute — RFC 4760 clause 4. It withdraws routes for an
address family the message header cannot name.
"""
@header BgpAttributeMpUnreachNlri <: BgpAttribute begin
    base              :: BgpAttributeHeader =
        BgpAttributeHeader(type_code = BGP_ATTRIBUTE_MP_UNREACH_NLRI,
                           optional = true)
        derive(measure_attribute_value(h, base))
    address_family    :: U16 = 2
    subsequent_family :: U8  = 1
    withdrawn_routes  :: Repeated{BgpPrefix} = BgpPrefix[]
        until(Bytes(measure_attribute_end(base)))
end

"""
    BgpAttributeRaw(; base, value)

A path attribute this library does not model. It keeps its flags, its type code
and its octets, and it reads exactly as many as its length says — so the
attribute after it still starts where it should.
"""
@header BgpAttributeRaw <: BgpAttribute begin
    base  :: BgpAttributeHeader = BgpAttributeHeader()
        derive(measure_attribute_value(h, base))
    value :: Octets = UInt8[]
        until(Bytes(measure_attribute_end(base)))
end

list_variants(::Type{BgpAttribute}) =
    (BgpAttributeOrigin, BgpAttributeAsPath, BgpAttributeNextHop,
     BgpAttributeMultiExitDiscriminator, BgpAttributeLocalPreference,
     BgpAttributeAtomicAggregate, BgpAttributeAggregator,
     BgpAttributeMpReachNlri, BgpAttributeMpUnreachNlri, BgpAttributeRaw)
variant_base(::Type{BgpAttribute}) = BgpAttributeHeader

matches_variant(::Type{BgpAttributeOrigin}, base) =
    base.type_code == BGP_ATTRIBUTE_ORIGIN
matches_variant(::Type{BgpAttributeAsPath}, base) =
    base.type_code == BGP_ATTRIBUTE_AS_PATH
matches_variant(::Type{BgpAttributeNextHop}, base) =
    base.type_code == BGP_ATTRIBUTE_NEXT_HOP
matches_variant(::Type{BgpAttributeMultiExitDiscriminator}, base) =
    base.type_code == BGP_ATTRIBUTE_MULTI_EXIT_DISC
matches_variant(::Type{BgpAttributeLocalPreference}, base) =
    base.type_code == BGP_ATTRIBUTE_LOCAL_PREFERENCE
matches_variant(::Type{BgpAttributeAtomicAggregate}, base) =
    base.type_code == BGP_ATTRIBUTE_ATOMIC_AGGREGATE
matches_variant(::Type{BgpAttributeAggregator}, base) =
    base.type_code == BGP_ATTRIBUTE_AGGREGATOR
matches_variant(::Type{BgpAttributeMpReachNlri}, base) =
    base.type_code == BGP_ATTRIBUTE_MP_REACH_NLRI
matches_variant(::Type{BgpAttributeMpUnreachNlri}, base) =
    base.type_code == BGP_ATTRIBUTE_MP_UNREACH_NLRI

# An attribute of an unknown code is still an attribute: it says its own length,
# so a reader can step over it. The raw member claims what no other member does.
matches_variant(::Type{BgpAttributeRaw}, base) = true

"""
    BgpUpdate(; withdrawn_routes, path_attributes, nlri)

An UPDATE message — RFC 4271 clause 4.3. It withdraws routes, announces routes,
and says what the announced routes are like.

The two length fields are measurements, so the writer derives them. The
reachability information at the end has no length field of its own: it runs to
the end of the message, and `total_length` says where that is.
"""
@header BgpUpdate <: BgpMessage begin
    base                        :: BgpCommon =
        BgpCommon(type = BGP_UPDATE, total_length = BGP_UPDATE_BYTES)
        derive(set_field(base, :total_length, measure_header(h) ÷ 8))
    withdrawn_routes_length     :: U16 = 0
        derive(measure_list_bytes(withdrawn_routes))
    withdrawn_routes            :: Repeated{BgpPrefix} = BgpPrefix[]
        until(Bytes(BGP_HEADER_BYTES + 2) + Bytes(withdrawn_routes_length))
    total_path_attribute_length :: U16 = 0
        derive(measure_list_bytes(path_attributes))
    path_attributes             :: Repeated{BgpAttribute} = BgpAttribute[]
        until(Bytes(BGP_HEADER_BYTES + 4) + Bytes(withdrawn_routes_length) +
              Bytes(total_path_attribute_length))
    nlri                        :: Repeated{BgpPrefix} = BgpPrefix[]
        until(Bytes(base.total_length))
end

list_variants(::Type{BgpMessage}) =
    (BgpOpen, BgpUpdate, BgpNotification, BgpKeepAlive)
variant_base(::Type{BgpMessage}) = BgpCommon

matches_variant(::Type{BgpOpen}, base)         = base.type == BGP_OPEN
matches_variant(::Type{BgpUpdate}, base)       = base.type == BGP_UPDATE
matches_variant(::Type{BgpNotification}, base) = base.type == BGP_NOTIFICATION
matches_variant(::Type{BgpKeepAlive}, base)    = base.type == BGP_KEEPALIVE
