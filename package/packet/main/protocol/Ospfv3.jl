# ============================================================================
# Open shortest path first, version 3 — RFC 5340.
#
# The same two families as version 2, and three things version 2 does not have.
#
#   * The header is sixteen octets, not twenty-four. Version 3 authenticates
#     with the IPv6 authentication header, so it carries no authentication field
#     of its own — RFC 5340 clause 2.5. The two octets it saves become an
#     instance identifier and a reserved octet.
#   * The options field is twenty-four bits and it moved: version 2 puts it in
#     the LSA header, and version 3 puts it in the LSA body of the types that
#     need it — RFC 5340 appendix A.2.
#   * An address prefix is as wide as its length says. RFC 5340 appendix A.4.1
#     writes it as a whole number of thirty-two-bit words, so a prefix of
#     sixty-four bits takes eight octets and a prefix of nothing takes none.
#
# Two departures from INET, both reported:
#
#   * INET does not keep the LS type. `encodeLsType` computes the scope bits
#     from the function code on the way out and drops the U bit entirely, and on
#     the way in it puts the whole high octet into a field it calls the options.
#     An LSA with the U bit set does not survive. RFC 5340 appendix A.4.2.1
#     makes the sixteen bits one field with three parts, and that is what this
#     declares.
#   * INET serialises five of the nine LSA function codes and throws on the
#     rest. The inter-area router LSA, the AS external LSA and the NSSA LSA are
#     declared here; an LSA of any other code keeps its octets and its place.
# ============================================================================

const OSPF_VERSION_3 = 3

"The width of each fixed part, in octets."
const OSPFV3_HEADER_BYTES               = 16
const OSPFV3_HELLO_BODY_BYTES           = 20
const OSPFV3_DATABASE_DESCRIPTION_BYTES = 12
const OSPFV3_LSA_HEADER_BYTES           = 20
const OSPFV3_REQUEST_BYTES              = 12
const OSPFV3_ROUTER_LINK_BYTES          = 16

"The LSA function codes — RFC 5340 appendix A.4.2.1."
const OSPFV3_ROUTER_LSA            = 1
const OSPFV3_NETWORK_LSA           = 2
const OSPFV3_INTER_AREA_PREFIX_LSA = 3
const OSPFV3_INTER_AREA_ROUTER_LSA = 4
const OSPFV3_AS_EXTERNAL_LSA       = 5
const OSPFV3_NSSA_LSA              = 7
const OSPFV3_LINK_LSA              = 8
const OSPFV3_INTRA_AREA_PREFIX_LSA = 9

"The flooding scopes an LS type carries — RFC 5340 appendix A.4.2.1."
const OSPFV3_SCOPE_LINK_LOCAL = 0
const OSPFV3_SCOPE_AREA       = 1
const OSPFV3_SCOPE_AS         = 2
const OSPFV3_SCOPE_RESERVED   = 3

"The router link types — RFC 5340 appendix A.4.3."
const OSPFV3_LINK_POINT_TO_POINT = 1
const OSPFV3_LINK_TRANSIT        = 2
const OSPFV3_LINK_VIRTUAL        = 4

# ---------- the options, and the prefix --------------------------------------

"""
    Ospfv3Options(; ipv6, external_routing, router, …)

The twenty-four-bit options field — RFC 5340 appendix A.2. A hello carries it, a
database description carries it, and so do the router, network, inter-area
router and link LSAs. Version 2 keeps its options in the LSA header instead.

`ipv6` is the V6 bit and says this router forwards IPv6. `router` is the R bit
and says it is an active router; a node that clears it still runs the protocol
but no path may go through it.
"""
@header Ospfv3Options begin
    reserved         :: U18  = 0
    demand_circuits  :: Bool = false
    router           :: Bool = true
    not_so_stubby    :: Bool = false
    multicast        :: Bool = false
    external_routing :: Bool = false
    ipv6             :: Bool = true
end

"""
    Ospfv3PrefixOptions(; no_unicast, local_address, propagate, down, …)

The one octet of prefix options — RFC 5340 appendix A.4.1.1.

`no_unicast` is the NU bit and takes the prefix out of unicast calculation.
`local_address` is the LA bit and says the prefix is an interface address of the
advertising router. `propagate` is the P bit and asks an NSSA border router to
translate the prefix.
"""
@header Ospfv3PrefixOptions begin
    reserved      :: U3   = 0
    down          :: Bool = false
    propagate     :: Bool = false
    multicast     :: Bool = false
    local_address :: Bool = false
    no_unicast    :: Bool = false
end

"""
    measure_prefix_bytes(prefix_length)::Int

How many octets an address prefix of `prefix_length` bits takes — RFC 5340
appendix A.4.1 writes it as a whole number of thirty-two-bit words, so a prefix
of sixty-five bits takes twelve octets and a prefix of nothing takes none.
"""
measure_prefix_bytes(prefix_length) = 4 * cld(Int(prefix_length), 32)

"""
    Ospfv3Prefix(; prefix_length, options, address)

One address prefix — RFC 5340 appendix A.4.1. Four octets and as many more as
the prefix length asks for.

The two octets after the options are reserved here. An intra-area prefix LSA
spends them on a metric and an AS external LSA on a referenced LS type, so the
standard draws one prefix with three meanings for the same two octets, and this
declares each of the three where it belongs.

`prefix_length` and `address` must agree, and both carry the check because
either one can be the one that is wrong.
"""
@header Ospfv3Prefix begin
    prefix_length :: U8 = 0
        check(Base.length(address) == measure_prefix_bytes(prefix_length))
    options       :: Ospfv3PrefixOptions = Ospfv3PrefixOptions()
    reserved      :: U16 = 0
    address       :: Octets = UInt8[]
        length(Bytes(measure_prefix_bytes(prefix_length)))
        check(Base.length(address) == measure_prefix_bytes(prefix_length))
end

"""
    Ospfv3PrefixMetric(; prefix_length, options, metric, address)

One address prefix with a metric — RFC 5340 appendix A.4.10. It is the prefix of
appendix A.4.1 with the two reserved octets spent on the cost of the prefix,
and it is what an intra-area prefix LSA carries.
"""
@header Ospfv3PrefixMetric begin
    prefix_length :: U8 = 0
        check(Base.length(address) == measure_prefix_bytes(prefix_length))
    options       :: Ospfv3PrefixOptions = Ospfv3PrefixOptions()
    metric        :: U16 = 0
    address       :: Octets = UInt8[]
        length(Bytes(measure_prefix_bytes(prefix_length)))
        check(Base.length(address) == measure_prefix_bytes(prefix_length))
end

# ---------- the link state advertisements ------------------------------------

"The version 3 LSAs — one header, and the function code says which body."
abstract type Ospfv3Lsa <: Fields end

"""
    Ospfv3LsaHeader(; function_code, scope, link_state_id, advertising_router, …)

The twenty octets every version 3 LSA starts with — RFC 5340 appendix A.4.2.

The LS type is sixteen bits with three parts — appendix A.4.2.1. `unknown` is
the U bit and says what a router must do with an LSA whose code it does not
know: flood it at the stated scope, or treat it as link local. `scope` is the
S2 and S1 pair.

INET computes the scope from the function code on the way out and drops the U
bit, so an LSA with that bit set does not survive its serializer.
"""
@header Ospfv3LsaHeader begin
    ls_age             :: U16 = 0
    unknown            :: Bool = false
    scope              :: U2  = OSPFV3_SCOPE_AREA
    function_code      :: U13 = OSPFV3_ROUTER_LSA
    link_state_id      :: Ipv4Address = Ipv4Address(0)
    advertising_router :: Ipv4Address = Ipv4Address(0)
    ls_sequence_number :: U32 = 0
    ls_checksum        :: Checksum16 = 0
    ls_checksum_mode   :: Model{ChecksumMode} = CHECKSUM_DECLARED
    lsa_length         :: U16 = OSPFV3_LSA_HEADER_BYTES
end

"The length a version 3 LSA header carries, measured from the LSA that holds it."
measure_v3_lsa_length(h) = measure_header(h) ÷ 8

"""
    Ospfv3RouterLink(; type, metric, interface_id, neighbor_interface_id, …)

One link of a router LSA — RFC 5340 appendix A.4.3. Sixteen octets, and every
link is the same width, which is what version 2 could not say.

Version 2 names a neighbour by address and version 3 names it by interface
identifier and router identifier, so a version 3 router LSA carries no address
at all — RFC 5340 clause 2.
"""
@header Ospfv3RouterLink begin
    type                  :: U8  = OSPFV3_LINK_POINT_TO_POINT
    reserved              :: U8  = 0
    metric                :: U16 = 0
    interface_id          :: U32 = 0
    neighbor_interface_id :: U32 = 0
    neighbor_router_id    :: Ipv4Address = Ipv4Address(0)
end

"""
    Ospfv3RouterLsa(; links, area_border_router, as_boundary_router, …)

A router LSA, function code 1 — RFC 5340 appendix A.4.3.

`nssa_translation` is the Nt bit and says this router always translates type 7
into type 5. Nothing counts the links: they run to the end of the LSA, and
`lsa_length` says where that is.
"""
@header Ospfv3RouterLsa <: Ospfv3Lsa begin
    base                  :: Ospfv3LsaHeader =
        Ospfv3LsaHeader(function_code = OSPFV3_ROUTER_LSA)
        derive(set_field(base, :lsa_length, measure_v3_lsa_length(h)))
    reserved              :: U3   = 0
    nssa_translation      :: Bool = false
    reserved2             :: Bool = false
    virtual_link_endpoint :: Bool = false
    as_boundary_router    :: Bool = false
    area_border_router    :: Bool = false
    options               :: Ospfv3Options = Ospfv3Options()
    links                 :: Repeated{Ospfv3RouterLink} = Ospfv3RouterLink[]
        until(Bytes(base.lsa_length))
end

"""
    Ospfv3NetworkLsa(; attached_routers, options)

A network LSA, function code 2 — RFC 5340 appendix A.4.4. The designated router
lists every router on the link, itself included. It carries no network mask,
which is what version 2 spends its first four octets on.
"""
@header Ospfv3NetworkLsa <: Ospfv3Lsa begin
    base             :: Ospfv3LsaHeader =
        Ospfv3LsaHeader(function_code = OSPFV3_NETWORK_LSA)
        derive(set_field(base, :lsa_length, measure_v3_lsa_length(h)))
    reserved         :: U8 = 0
    options          :: Ospfv3Options = Ospfv3Options()
    attached_routers :: Repeated{Ipv4Address} = Ipv4Address[]
        until(Bytes(base.lsa_length))
end

"""
    Ospfv3InterAreaPrefixLsa(; metric, prefix)

An inter-area prefix LSA, function code 3 — RFC 5340 appendix A.4.5. An area
border router advertises one prefix from another area, with the cost of
reaching it.
"""
@header Ospfv3InterAreaPrefixLsa <: Ospfv3Lsa begin
    base     :: Ospfv3LsaHeader =
        Ospfv3LsaHeader(function_code = OSPFV3_INTER_AREA_PREFIX_LSA)
        derive(set_field(base, :lsa_length, measure_v3_lsa_length(h)))
    reserved :: U8  = 0
    metric   :: U24 = 0
    prefix   :: Ospfv3Prefix = Ospfv3Prefix()
end

"""
    Ospfv3InterAreaRouterLsa(; destination_router_id, metric, options)

An inter-area router LSA, function code 4 — RFC 5340 appendix A.4.6. An area
border router advertises the cost of reaching an autonomous system boundary
router in another area.

INET declares this LSA and its serializer throws on it.
"""
@header Ospfv3InterAreaRouterLsa <: Ospfv3Lsa begin
    base                  :: Ospfv3LsaHeader =
        Ospfv3LsaHeader(function_code = OSPFV3_INTER_AREA_ROUTER_LSA)
        derive(set_field(base, :lsa_length, measure_v3_lsa_length(h)))
    reserved              :: U8  = 0
    options               :: Ospfv3Options = Ospfv3Options()
    reserved2             :: U8  = 0
    metric                :: U24 = 0
    destination_router_id :: Ipv4Address = Ipv4Address(0)
end

"""
    Ospfv3AsExternalLsa(; metric, prefix_length, address, forwarding_address, …)

An AS external LSA, function code 5 — RFC 5340 appendix A.4.7. It describes a
route to a destination outside the autonomous system.

Three of its fields are there only when a bit says so, and RFC 5340 gives each
bit its own meaning:

* `forwarding_address` is there when the F bit is set, and traffic for the
  prefix goes to that address instead of to the advertising router.
* `external_route_tag` is there when the T bit is set. OSPF does not read it;
  it carries information between autonomous system boundary routers.
* `referenced_link_state_id` is there when `referenced_ls_type` is not zero.

`external_metric_type` is the E bit: a type 2 metric is larger than any path
inside the autonomous system, and a type 1 metric is comparable with one.

An NSSA LSA, function code 7, has the same body — RFC 5340 clause 4.4.3.9 — so
this member reads both. INET throws on either.
"""
@header Ospfv3AsExternalLsa <: Ospfv3Lsa begin
    base                     :: Ospfv3LsaHeader =
        Ospfv3LsaHeader(function_code = OSPFV3_AS_EXTERNAL_LSA,
                        scope = OSPFV3_SCOPE_AS)
        derive(set_field(base, :lsa_length, measure_v3_lsa_length(h)))
    reserved                 :: U5   = 0
    external_metric_type     :: Bool = false
    has_forwarding_address   :: Bool = false
    has_external_route_tag   :: Bool = false
    metric                   :: U24  = 0
    prefix_length            :: U8   = 0
        check(Base.length(address) == measure_prefix_bytes(prefix_length))
    prefix_options           :: Ospfv3PrefixOptions = Ospfv3PrefixOptions()
    referenced_ls_type       :: U16  = 0
    address                  :: Octets = UInt8[]
        length(Bytes(measure_prefix_bytes(prefix_length)))
        check(Base.length(address) == measure_prefix_bytes(prefix_length))
    forwarding_address       :: Optional{Ipv6Address} = nothing
        when(has_forwarding_address)
    external_route_tag       :: Optional{U32} = nothing
        when(has_external_route_tag)
    referenced_link_state_id :: Optional{Ipv4Address} = nothing
        when(referenced_ls_type != 0)
end

"""
    Ospfv3LinkLsa(; router_priority, link_local_address, prefixes, options)

A link LSA, function code 8 — RFC 5340 appendix A.4.9. A router tells every
other router on a link its link-local address and the prefixes on that link.
Its scope is the link, so it never leaves it.
"""
@header Ospfv3LinkLsa <: Ospfv3Lsa begin
    base                :: Ospfv3LsaHeader =
        Ospfv3LsaHeader(function_code = OSPFV3_LINK_LSA,
                        scope = OSPFV3_SCOPE_LINK_LOCAL)
        derive(set_field(base, :lsa_length, measure_v3_lsa_length(h)))
    router_priority     :: U8 = 1
    options             :: Ospfv3Options = Ospfv3Options()
    link_local_address  :: Ipv6Address = Ipv6Address("::")
    number_of_prefixes  :: U32 = 0
        derive(Base.length(prefixes))
    prefixes            :: Repeated{Ospfv3Prefix} = Ospfv3Prefix[]
        until(Bytes(base.lsa_length))
end

"""
    Ospfv3IntraAreaPrefixLsa(; prefixes, referenced_ls_type, …)

An intra-area prefix LSA, function code 9 — RFC 5340 appendix A.4.10. It
carries the prefixes that a router or a network LSA no longer does: version 3
took the addresses out of the topology, and this is where they went.

The three referenced fields name the LSA the prefixes belong to.
"""
@header Ospfv3IntraAreaPrefixLsa <: Ospfv3Lsa begin
    base                         :: Ospfv3LsaHeader =
        Ospfv3LsaHeader(function_code = OSPFV3_INTRA_AREA_PREFIX_LSA)
        derive(set_field(base, :lsa_length, measure_v3_lsa_length(h)))
    number_of_prefixes           :: U16 = 0
        derive(Base.length(prefixes))
    referenced_ls_type           :: U16 = 0
    referenced_link_state_id     :: Ipv4Address = Ipv4Address(0)
    referenced_advertising_router :: Ipv4Address = Ipv4Address(0)
    prefixes                     :: Repeated{Ospfv3PrefixMetric} =
        Ospfv3PrefixMetric[]
        until(Bytes(base.lsa_length))
end

"""
    Ospfv3RawLsa(; base, data)

An LSA of a function code this library does not model. It keeps its header and
its octets, and it reads exactly as many as `lsa_length` says — so the LSA after
it in the same update still starts where it should.
"""
@header Ospfv3RawLsa <: Ospfv3Lsa begin
    base :: Ospfv3LsaHeader = Ospfv3LsaHeader()
        derive(set_field(base, :lsa_length, measure_v3_lsa_length(h)))
    data :: Octets = UInt8[]
        until(Bytes(base.lsa_length))
end

list_variants(::Type{Ospfv3Lsa}) =
    (Ospfv3RouterLsa, Ospfv3NetworkLsa, Ospfv3InterAreaPrefixLsa,
     Ospfv3InterAreaRouterLsa, Ospfv3AsExternalLsa, Ospfv3LinkLsa,
     Ospfv3IntraAreaPrefixLsa, Ospfv3RawLsa)
variant_base(::Type{Ospfv3Lsa}) = Ospfv3LsaHeader

matches_variant(::Type{Ospfv3RouterLsa}, base) =
    base.function_code == OSPFV3_ROUTER_LSA
matches_variant(::Type{Ospfv3NetworkLsa}, base) =
    base.function_code == OSPFV3_NETWORK_LSA
matches_variant(::Type{Ospfv3InterAreaPrefixLsa}, base) =
    base.function_code == OSPFV3_INTER_AREA_PREFIX_LSA
matches_variant(::Type{Ospfv3InterAreaRouterLsa}, base) =
    base.function_code == OSPFV3_INTER_AREA_ROUTER_LSA
matches_variant(::Type{Ospfv3AsExternalLsa}, base) =
    base.function_code == OSPFV3_AS_EXTERNAL_LSA ||
    base.function_code == OSPFV3_NSSA_LSA
matches_variant(::Type{Ospfv3LinkLsa}, base) =
    base.function_code == OSPFV3_LINK_LSA
matches_variant(::Type{Ospfv3IntraAreaPrefixLsa}, base) =
    base.function_code == OSPFV3_INTRA_AREA_PREFIX_LSA

# An LSA of an unknown code is still an LSA: it says its own length, so a reader
# can step over it. The raw member claims what no other member does.
matches_variant(::Type{Ospfv3RawLsa}, base) = true

# ---------- the packets ------------------------------------------------------

"The OSPFv3 packets — one wire format, and the type octet says which."
abstract type Ospfv3Packet <: Fields end

"""
    Ospfv3Common(; type, router_id, area_id, instance_id, …)

The sixteen octets every version 3 packet starts with — RFC 5340 appendix A.3.1.

`instance_id` lets several OSPF instances share one link — RFC 5340 clause 2.4.
A router drops a packet whose instance is not one of its own, which is what
replaces version 2's authentication field.

The router and area identifiers stay thirty-two bits wide in version 3, and they
are numbers rather than addresses even on a network that has no IPv4.
"""
@header Ospfv3Common begin
    version       :: U8  = OSPF_VERSION_3
    type          :: U8  = OSPF_HELLO_PACKET
    packet_length :: U16 = OSPFV3_HEADER_BYTES
    router_id     :: Ipv4Address = Ipv4Address(0)
    area_id       :: Ipv4Address = Ipv4Address(0)
    checksum      :: Checksum16 = 0
    checksum_mode :: Model{ChecksumMode} = CHECKSUM_DECLARED
    instance_id   :: U8 = 0
    reserved      :: U8 = 0
end

"The length a version 3 common header carries, measured from its packet."
measure_v3_packet_length(h) = measure_header(h) ÷ 8

"""
    Ospfv3Header(; base, data)

A version 3 packet of a type this library does not model. It comes back marked
misrepresented, with its octets intact.
"""
@header Ospfv3Header <: Ospfv3Packet begin
    base :: Ospfv3Common = Ospfv3Common()
        derive(set_field(base, :packet_length, measure_v3_packet_length(h)))
    data :: Octets = UInt8[]
        until(Bytes(base.packet_length))
end

"""
    Ospfv3Hello(; interface_id, hello_interval, dead_interval, neighbors, …)

A hello packet — RFC 5340 appendix A.3.2.

`interface_id` is the sender's own identifier for the interface it sent this on,
and it is what version 3 names an interface by. The neighbours are router
identifiers, and nothing counts them: they run to the end of the packet.
"""
@header Ospfv3Hello <: Ospfv3Packet begin
    base                     :: Ospfv3Common =
        Ospfv3Common(type = OSPF_HELLO_PACKET)
        derive(set_field(base, :packet_length, measure_v3_packet_length(h)))
    interface_id             :: U32 = 0
    router_priority          :: U8  = 1
    options                  :: Ospfv3Options = Ospfv3Options()
    hello_interval           :: U16 = 10
    dead_interval            :: U16 = 40
    designated_router        :: Ipv4Address = Ipv4Address(0)
    backup_designated_router :: Ipv4Address = Ipv4Address(0)
    neighbors                :: Repeated{Ipv4Address} = Ipv4Address[]
        until(Bytes(base.packet_length))
end

"""
    Ospfv3DatabaseDescription(; interface_mtu, lsa_headers, initial, more, master, …)

A database description packet — RFC 5340 appendix A.3.3. It is version 2's
packet with the options widened to twenty-four bits and moved in front of the
interface MTU.
"""
@header Ospfv3DatabaseDescription <: Ospfv3Packet begin
    base               :: Ospfv3Common =
        Ospfv3Common(type = OSPF_DATABASE_DESCRIPTION_PACKET)
        derive(set_field(base, :packet_length, measure_v3_packet_length(h)))
    reserved           :: U8 = 0
    options            :: Ospfv3Options = Ospfv3Options()
    interface_mtu      :: U16 = 1500
    reserved2          :: U8  = 0
    reserved3          :: U5  = 0
    initial            :: Bool = false
    more               :: Bool = false
    master             :: Bool = false
    dd_sequence_number :: U32 = 0
    lsa_headers        :: Repeated{Ospfv3LsaHeader} = Ospfv3LsaHeader[]
        until(Bytes(base.packet_length))
end

"""
    Ospfv3LsaRequest(; function_code, scope, link_state_id, advertising_router)

One request of a link state request packet — RFC 5340 appendix A.3.4. Twelve
octets: two reserved, then the LS type, and the two identifiers that name one
LSA.
"""
@header Ospfv3LsaRequest begin
    reserved           :: U16 = 0
    unknown            :: Bool = false
    scope              :: U2  = OSPFV3_SCOPE_AREA
    function_code      :: U13 = OSPFV3_ROUTER_LSA
    link_state_id      :: Ipv4Address = Ipv4Address(0)
    advertising_router :: Ipv4Address = Ipv4Address(0)
end

"""
    Ospfv3LinkStateRequest(; requests)

A link state request packet — RFC 5340 appendix A.3.4.
"""
@header Ospfv3LinkStateRequest <: Ospfv3Packet begin
    base     :: Ospfv3Common =
        Ospfv3Common(type = OSPF_LINK_STATE_REQUEST_PACKET)
        derive(set_field(base, :packet_length, measure_v3_packet_length(h)))
    requests :: Repeated{Ospfv3LsaRequest} = Ospfv3LsaRequest[]
        until(Bytes(base.packet_length))
end

"""
    Ospfv3LinkStateUpdate(; lsas)

A link state update packet — RFC 5340 appendix A.3.5. It carries whole LSAs and
counts them, and the writer derives the count from the list.
"""
@header Ospfv3LinkStateUpdate <: Ospfv3Packet begin
    base           :: Ospfv3Common =
        Ospfv3Common(type = OSPF_LINK_STATE_UPDATE_PACKET)
        derive(set_field(base, :packet_length, measure_v3_packet_length(h)))
    number_of_lsas :: U32 = 0
        derive(Base.length(lsas))
    lsas           :: Repeated{Ospfv3Lsa} = Ospfv3Lsa[]
        until(Bytes(base.packet_length))
end

"""
    Ospfv3LinkStateAcknowledgement(; lsa_headers)

A link state acknowledgement packet — RFC 5340 appendix A.3.6.
"""
@header Ospfv3LinkStateAcknowledgement <: Ospfv3Packet begin
    base        :: Ospfv3Common =
        Ospfv3Common(type = OSPF_LINK_STATE_ACKNOWLEDGEMENT_PACKET)
        derive(set_field(base, :packet_length, measure_v3_packet_length(h)))
    lsa_headers :: Repeated{Ospfv3LsaHeader} = Ospfv3LsaHeader[]
        until(Bytes(base.packet_length))
end

list_variants(::Type{Ospfv3Packet}) =
    (Ospfv3Hello, Ospfv3DatabaseDescription, Ospfv3LinkStateRequest,
     Ospfv3LinkStateUpdate, Ospfv3LinkStateAcknowledgement)
variant_base(::Type{Ospfv3Packet}) = Ospfv3Common
variant_fallback(::Type{Ospfv3Packet}) = Ospfv3Header

matches_variant(::Type{Ospfv3Hello}, base) = base.type == OSPF_HELLO_PACKET
matches_variant(::Type{Ospfv3DatabaseDescription}, base) =
    base.type == OSPF_DATABASE_DESCRIPTION_PACKET
matches_variant(::Type{Ospfv3LinkStateRequest}, base) =
    base.type == OSPF_LINK_STATE_REQUEST_PACKET
matches_variant(::Type{Ospfv3LinkStateUpdate}, base) =
    base.type == OSPF_LINK_STATE_UPDATE_PACKET
matches_variant(::Type{Ospfv3LinkStateAcknowledgement}, base) =
    base.type == OSPF_LINK_STATE_ACKNOWLEDGEMENT_PACKET
