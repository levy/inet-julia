# ============================================================================
# ICMPv6 — RFC 4443, as a variant family.
#
# Every ICMPv6 message starts with the same four octets, and the type octet
# says what follows them. That is the ICMP shape again, so this file is the
# ICMP file with more members.
#
# Three groups of member live here, because RFC 4443 says all three are ICMPv6
# messages and a reader has one type octet to tell them apart:
#
# * the error and echo messages of RFC 4443,
# * the neighbour discovery messages of RFC 4861, types 133 to 137,
# * the multicast listener discovery messages of RFC 2710 and RFC 3810,
#   types 130, 131, 132 and 143.
#
# INET splits the third group into a serializer of its own, and its ICMPv6
# serializer throws on those four types. Here they are members like any other,
# because the wire says they are.
#
# Two members share a type octet: an MLD Query is version 1 at twenty-four
# octets and version 2 when it is longer. RFC 3810 section 8.1 makes the length
# the discriminator, so those two members read the length as well as the base.
# ============================================================================

const ICMPV6_DESTINATION_UNREACHABLE = 1
const ICMPV6_PACKET_TOO_BIG          = 2
const ICMPV6_TIME_EXCEEDED           = 3
const ICMPV6_PARAMETER_PROBLEM       = 4
const ICMPV6_ECHO_REQUEST            = 128
const ICMPV6_ECHO_REPLY              = 129
const ICMPV6_MLD_QUERY               = 130
const ICMPV6_MLD_REPORT              = 131
const ICMPV6_MLD_DONE                = 132
const ICMPV6_ROUTER_SOLICITATION     = 133
const ICMPV6_ROUTER_ADVERTISEMENT    = 134
const ICMPV6_NEIGHBOR_SOLICITATION   = 135
const ICMPV6_NEIGHBOR_ADVERTISEMENT  = 136
const ICMPV6_REDIRECT                = 137
const ICMPV6_MLDV2_REPORT            = 143

"An MLDv1 message is twenty-four octets; an MLDv2 Query is longer — RFC 3810 section 8.1."
const MLD_MESSAGE_BYTES = 24

"The ICMPv6 messages — one wire format, and the type says which."
abstract type Icmpv6Message <: Fields end

"""
    Icmpv6Common(; type, code, checksum)

The four octets every ICMPv6 message starts with — RFC 4443 section 2.1. It is
what a reader looks at to decide which message this is, and every member
embeds it.
"""
@header Icmpv6Common begin
    type          :: U8
    code          :: U8         = 0
    checksum      :: Checksum16 = 0
    checksum_mode :: Model{ChecksumMode} = CHECKSUM_DECLARED
end

"""
    Icmpv6Header(; base, unused)

An ICMPv6 message this library does not model, eight octets: the common four
and the four whose meaning its type decides. A message no member claims comes
back as this, marked misrepresented, with its bytes intact.
"""
@header Icmpv6Header <: Icmpv6Message begin
    base   :: Icmpv6Common
    unused :: U32 = 0
end

# ---------- the error messages, RFC 4443 section 3 ---------------------------

"""
    Icmpv6DestinationUnreachable(; code)

Destination Unreachable, eight octets — RFC 4443 section 3.1. The code says
why, and the four unused octets are followed by as much of the datagram as
fits.
"""
@header Icmpv6DestinationUnreachable <: Icmpv6Message begin
    base   :: Icmpv6Common = Icmpv6Common(type = ICMPV6_DESTINATION_UNREACHABLE)
    unused :: U32          = 0
end

"""
    Icmpv6PacketTooBig(; mtu)

Packet Too Big, eight octets — RFC 4443 section 3.2. IPv6 routers do not
fragment, so this is how a source learns the path MTU.
"""
@header Icmpv6PacketTooBig <: Icmpv6Message begin
    base :: Icmpv6Common = Icmpv6Common(type = ICMPV6_PACKET_TOO_BIG)
    mtu  :: U32
end

"""
    Icmpv6TimeExceeded(; code)

Time Exceeded, eight octets — RFC 4443 section 3.3. Code 0 is a hop limit that
reached zero, and code 1 is a reassembly that timed out.
"""
@header Icmpv6TimeExceeded <: Icmpv6Message begin
    base   :: Icmpv6Common = Icmpv6Common(type = ICMPV6_TIME_EXCEEDED)
    unused :: U32          = 0
end

"""
    Icmpv6ParameterProblem(; pointer, code)

Parameter Problem, eight octets — RFC 4443 section 3.4. `pointer` is the offset
of the octet that caused the problem, counted from the start of the datagram.
"""
@header Icmpv6ParameterProblem <: Icmpv6Message begin
    base    :: Icmpv6Common = Icmpv6Common(type = ICMPV6_PARAMETER_PROBLEM)
    pointer :: U32
end

# ---------- the informational messages, RFC 4443 section 4 -------------------

"""
    Icmpv6EchoRequest(; identifier, sequence_number)

Echo Request, eight octets — RFC 4443 section 4.1.
"""
@header Icmpv6EchoRequest <: Icmpv6Message begin
    base            :: Icmpv6Common = Icmpv6Common(type = ICMPV6_ECHO_REQUEST)
    identifier      :: U16
    sequence_number :: U16
end

"""
    Icmpv6EchoReply(; identifier, sequence_number)

Echo Reply, eight octets — RFC 4443 section 4.2.
"""
@header Icmpv6EchoReply <: Icmpv6Message begin
    base            :: Icmpv6Common = Icmpv6Common(type = ICMPV6_ECHO_REPLY)
    identifier      :: U16
    sequence_number :: U16
end

# ---------- neighbour discovery, RFC 4861 section 4 --------------------------

"""
    Ipv6RouterSolicitation(; options)

Router Solicitation — RFC 4861 section 4.1. A host sends it to ask the routers
on the link to advertise themselves at once, rather than waiting.
"""
@header Ipv6RouterSolicitation <: Icmpv6Message begin
    base     :: Icmpv6Common = Icmpv6Common(type = ICMPV6_ROUTER_SOLICITATION)
    reserved :: U32          = 0
    options  :: Options{Ipv6NdOption} = Ipv6NdOption[]
end

"""
    Ipv6RouterAdvertisement(; hop_limit, router_lifetime, options, …)

Router Advertisement — RFC 4861 section 4.2. It carries the link's parameters
and, in its prefix information options, the prefixes a host builds an address
from.

`managed` is the M bit and `other` is the O bit, which together say how much of
the configuration comes from DHCPv6. `home_agent` is the H bit of RFC 6275
section 7.1.
"""
@header Ipv6RouterAdvertisement <: Icmpv6Message begin
    base                 :: Icmpv6Common = Icmpv6Common(type = ICMPV6_ROUTER_ADVERTISEMENT)
    hop_limit            :: U8   = 0
    managed              :: Bool = false
    other                :: Bool = false
    home_agent           :: Bool = false
    reserved             :: U5   = 0
    router_lifetime      :: U16
    reachable_time       :: U32  = 0
    retransmission_timer :: U32  = 0
    options              :: Options{Ipv6NdOption} = Ipv6NdOption[]
end

"""
    Ipv6NeighborSolicitation(; target, options)

Neighbor Solicitation — RFC 4861 section 4.3. It asks for the link-layer
address of `target`, and it is what duplicate address detection sends.
"""
@header Ipv6NeighborSolicitation <: Icmpv6Message begin
    base     :: Icmpv6Common = Icmpv6Common(type = ICMPV6_NEIGHBOR_SOLICITATION)
    reserved :: U32          = 0
    target   :: Ipv6Address
    options  :: Options{Ipv6NdOption} = Ipv6NdOption[]
end

"""
    Ipv6NeighborAdvertisement(; target, router, solicited, override, options)

Neighbor Advertisement — RFC 4861 section 4.4. It answers a solicitation, and a
node also sends one unasked when its link-layer address changes.

`router` is the R bit, `solicited` the S bit and `override` the O bit.
"""
@header Ipv6NeighborAdvertisement <: Icmpv6Message begin
    base      :: Icmpv6Common = Icmpv6Common(type = ICMPV6_NEIGHBOR_ADVERTISEMENT)
    router    :: Bool = false
    solicited :: Bool = false
    override  :: Bool = false
    reserved  :: U29  = 0
    target    :: Ipv6Address
    options   :: Options{Ipv6NdOption} = Ipv6NdOption[]
end

"""
    Ipv6Redirect(; target, destination, options)

Redirect — RFC 4861 section 4.5. A router sends it to tell a host of a better
first hop for `destination`.
"""
@header Ipv6Redirect <: Icmpv6Message begin
    base        :: Icmpv6Common = Icmpv6Common(type = ICMPV6_REDIRECT)
    reserved    :: U32          = 0
    target      :: Ipv6Address
    destination :: Ipv6Address
    options     :: Options{Ipv6NdOption} = Ipv6NdOption[]
end

# ---------- multicast listener discovery, RFC 2710 and RFC 3810 --------------

"""
    MldQuery(; maximum_response_delay, multicast_address)

An MLDv1 Multicast Listener Query, twenty-four octets — RFC 2710 section 3. An
address of all zeros makes it a general query.
"""
@header MldQuery <: Icmpv6Message begin
    base                   :: Icmpv6Common = Icmpv6Common(type = ICMPV6_MLD_QUERY)
    maximum_response_delay :: U16 = 0
    reserved               :: U16 = 0
    multicast_address      :: Ipv6Address
end

"""
    MldReport(; multicast_address)

An MLDv1 Multicast Listener Report, twenty-four octets — RFC 2710 section 3.
"""
@header MldReport <: Icmpv6Message begin
    base                   :: Icmpv6Common = Icmpv6Common(type = ICMPV6_MLD_REPORT)
    maximum_response_delay :: U16 = 0
    reserved               :: U16 = 0
    multicast_address      :: Ipv6Address
end

"""
    MldDone(; multicast_address)

An MLDv1 Multicast Listener Done, twenty-four octets — RFC 2710 section 3. It
is what a node sends when it stops listening.
"""
@header MldDone <: Icmpv6Message begin
    base                   :: Icmpv6Common = Icmpv6Common(type = ICMPV6_MLD_DONE)
    maximum_response_delay :: U16 = 0
    reserved               :: U16 = 0
    multicast_address      :: Ipv6Address
end

"""
    Mldv2Query(; multicast_address, sources, robustness, …)

An MLDv2 Multicast Listener Query — RFC 3810 section 5.1, twenty-eight octets
and sixteen more for each source.

It shares its type octet with `MldQuery`, and only its length tells the two
apart. `suppress_router_processing` is the S flag and `robustness` is the QRV.
"""
@header Mldv2Query <: Icmpv6Message begin
    base                       :: Icmpv6Common = Icmpv6Common(type = ICMPV6_MLD_QUERY)
    maximum_response_code      :: U16 = 0
    reserved                   :: U16 = 0
    multicast_address          :: Ipv6Address
    reserved2                  :: U4   = 0
    suppress_router_processing :: Bool = false
    robustness                 :: U3   = 0
    query_interval_code        :: U8   = 0
    number_of_sources          :: U16  = 0
        derive(Base.length(sources))
    sources                    :: Repeated{Ipv6Address} = Ipv6Address[]
        count(number_of_sources)
end

"""
    Mldv2MulticastAddressRecord(; record_type, multicast_address, sources)

One record of an MLDv2 report — RFC 3810 section 5.2.12. `auxiliary_length`
counts thirty-two-bit words, and RFC 3810 defines no auxiliary data yet.
"""
@header Mldv2MulticastAddressRecord begin
    record_type       :: U8
    auxiliary_length  :: U8  = 0
        derive(Base.length(auxiliary_data))
    number_of_sources :: U16 = 0
        derive(Base.length(sources))
    multicast_address :: Ipv6Address
    sources           :: Repeated{Ipv6Address} = Ipv6Address[]
        count(number_of_sources)
    auxiliary_data    :: Repeated{U32} = U32[]
        count(auxiliary_length)
end

"""
    Mldv2Report(; records)

An MLDv2 Multicast Listener Report — RFC 3810 section 5.2. No two records are
the same width, so the list fills the message and `number_of_records` is what
the writer derives from it.
"""
@header Mldv2Report <: Icmpv6Message begin
    base              :: Icmpv6Common = Icmpv6Common(type = ICMPV6_MLDV2_REPORT)
    reserved          :: U16 = 0
    number_of_records :: U16 = 0
        derive(Base.length(records))
    records           :: Repeated{Mldv2MulticastAddressRecord} =
        Mldv2MulticastAddressRecord[]
end

# ---------- the family -------------------------------------------------------

list_variants(::Type{Icmpv6Message}) =
    (Icmpv6DestinationUnreachable, Icmpv6PacketTooBig, Icmpv6TimeExceeded,
     Icmpv6ParameterProblem, Icmpv6EchoRequest, Icmpv6EchoReply,
     Ipv6RouterSolicitation, Ipv6RouterAdvertisement,
     Ipv6NeighborSolicitation, Ipv6NeighborAdvertisement, Ipv6Redirect,
     Mldv2Query, MldQuery, MldReport, MldDone, Mldv2Report)
variant_base(::Type{Icmpv6Message}) = Icmpv6Common
variant_fallback(::Type{Icmpv6Message}) = Icmpv6Header

matches_variant(::Type{Icmpv6DestinationUnreachable}, base) =
    base.type == ICMPV6_DESTINATION_UNREACHABLE
matches_variant(::Type{Icmpv6PacketTooBig}, base) = base.type == ICMPV6_PACKET_TOO_BIG
matches_variant(::Type{Icmpv6TimeExceeded}, base) = base.type == ICMPV6_TIME_EXCEEDED
matches_variant(::Type{Icmpv6ParameterProblem}, base) =
    base.type == ICMPV6_PARAMETER_PROBLEM
matches_variant(::Type{Icmpv6EchoRequest}, base) = base.type == ICMPV6_ECHO_REQUEST
matches_variant(::Type{Icmpv6EchoReply}, base)   = base.type == ICMPV6_ECHO_REPLY
matches_variant(::Type{Ipv6RouterSolicitation}, base) =
    base.type == ICMPV6_ROUTER_SOLICITATION
matches_variant(::Type{Ipv6RouterAdvertisement}, base) =
    base.type == ICMPV6_ROUTER_ADVERTISEMENT
matches_variant(::Type{Ipv6NeighborSolicitation}, base) =
    base.type == ICMPV6_NEIGHBOR_SOLICITATION
matches_variant(::Type{Ipv6NeighborAdvertisement}, base) =
    base.type == ICMPV6_NEIGHBOR_ADVERTISEMENT
matches_variant(::Type{Ipv6Redirect}, base) = base.type == ICMPV6_REDIRECT
matches_variant(::Type{MldReport}, base)    = base.type == ICMPV6_MLD_REPORT
matches_variant(::Type{MldDone}, base)      = base.type == ICMPV6_MLD_DONE
matches_variant(::Type{Mldv2Report}, base)  = base.type == ICMPV6_MLDV2_REPORT

# The two that share a type octet. RFC 3810 section 8.1: a Query of exactly
# twenty-four octets is version 1, and a longer one is version 2.
matches_variant(::Type{MldQuery}, base, available::Int) =
    base.type == ICMPV6_MLD_QUERY && available <= bits(Bytes(MLD_MESSAGE_BYTES))
matches_variant(::Type{Mldv2Query}, base, available::Int) =
    base.type == ICMPV6_MLD_QUERY && available > bits(Bytes(MLD_MESSAGE_BYTES))
