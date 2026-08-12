# ============================================================================
# Open shortest path first, version 2 — RFC 2328.
#
# Two variant families, one inside the other.
#
# The outer one is the packet. Every OSPF packet starts with the same
# twenty-four octets — RFC 2328 appendix A.3.1 — and the type octet says which
# of the five packets follows.
#
# The inner one is the link state advertisement. Every LSA starts with the same
# twenty octets — appendix A.4.1 — and the LS type octet says which of the five
# bodies follows. An LSA is not a whole chunk, so its header carries the length
# and the body ends where that length says.
#
# Both lengths are measurements, so both are derived. The direction that matters
# is the one that cannot be wrong: a length the writer computes can never
# disagree with the octets beside it, and a length a model sets by hand can.
# The field belongs to the shared header, so each member derives the whole
# header with the measured length written into it.
#
# Three places where this departs from INET, all reported:
#
#   * `Ospfv2PacketSerializer` reads an LSA of an unknown type, marks the packet
#     incorrect and reads no body. The stream is then in the middle of that LSA,
#     so every later LSA in the same update is garbage. Here an unknown type is
#     `Ospfv2RawLsa`, which keeps the octets and leaves the stream where the
#     next LSA starts.
#   * INET throws on LS type 7. RFC 3101 clause 2.2 gives the NSSA external LSA
#     the same body as the type 5 AS external LSA, so one member reads both.
#   * INET serialises the router LSA's TOS entry and the summary LSA's TOS entry
#     from one `Ospfv2TosData` struct, and writes them differently. They are two
#     formats — appendix A.4.2 puts a zero octet and a sixteen-bit metric where
#     appendix A.4.4 puts a twenty-four-bit one — so they are two headers here.
# ============================================================================

const OSPF_VERSION_2 = 2

"The packet types — RFC 2328 appendix A.3.1."
const OSPF_HELLO_PACKET                      = 1
const OSPF_DATABASE_DESCRIPTION_PACKET       = 2
const OSPF_LINK_STATE_REQUEST_PACKET         = 3
const OSPF_LINK_STATE_UPDATE_PACKET          = 4
const OSPF_LINK_STATE_ACKNOWLEDGEMENT_PACKET = 5

"The authentication types — RFC 2328 appendix D."
const OSPF_AUTHENTICATION_NULL          = 0
const OSPF_AUTHENTICATION_SIMPLE        = 1
const OSPF_AUTHENTICATION_CRYPTOGRAPHIC = 2

"The LSA types — RFC 2328 appendix A.4.1, and RFC 3101 clause 2.2 for type 7."
const OSPF_ROUTER_LSA         = 1
const OSPF_NETWORK_LSA        = 2
const OSPF_SUMMARY_LSA        = 3
const OSPF_ASBR_SUMMARY_LSA   = 4
const OSPF_AS_EXTERNAL_LSA    = 5
const OSPF_NSSA_EXTERNAL_LSA  = 7

"The router link types — RFC 2328 appendix A.4.2."
const OSPF_LINK_POINT_TO_POINT = 1
const OSPF_LINK_TRANSIT        = 2
const OSPF_LINK_STUB           = 3
const OSPF_LINK_VIRTUAL        = 4

"The width of each fixed part, in octets."
const OSPFV2_HEADER_BYTES                = 24
const OSPFV2_HELLO_BODY_BYTES            = 20
const OSPFV2_DATABASE_DESCRIPTION_BYTES  = 8
const OSPFV2_LSA_HEADER_BYTES            = 20
const OSPFV2_REQUEST_BYTES               = 12

# ---------- the options octet ------------------------------------------------

"""
    Ospfv2Options(; external_routing, multicast, …)

The one options octet — RFC 2328 appendix A.2. A hello carries it, a database
description carries it, and so does every LSA header.

RFC 2328 leaves the top two bits and the bottom bit unassigned. Later work took
all three: bit 6 is the opaque-LSA bit of RFC 5250, bit 0 is the multi-topology
bit of RFC 4915, and bit 7 is the DN bit of RFC 4576. They are named here for
what they are now. INET calls the same three bits `unused_1`, `unused_2` and
`unused_3`, which is RFC 2328 as it was written.
"""
@header Ospfv2Options begin
    down                :: Bool = false
    opaque              :: Bool = false
    demand_circuits     :: Bool = false
    external_attributes :: Bool = false
    not_so_stubby       :: Bool = false
    multicast           :: Bool = false
    external_routing    :: Bool = false
    multi_topology      :: Bool = false
end

# ---------- the link state advertisements ------------------------------------

"The link state advertisements — one header, and the LS type says which body."
abstract type Ospfv2Lsa <: Fields end

"""
    Ospfv2LsaHeader(; ls_type, link_state_id, advertising_router, …)

The twenty octets every LSA starts with — RFC 2328 appendix A.4.1.

`lsa_length` counts the whole LSA, this header included, and the body ends where
it says. `ls_age` is in seconds since the LSA was originated.

The three fields `link_state_id`, `advertising_router` and `ls_sequence_number`
are what identify an LSA and what say which of two copies is newer.
"""
@header Ospfv2LsaHeader begin
    ls_age             :: U16 = 0
    options            :: Ospfv2Options = Ospfv2Options()
    ls_type            :: U8  = OSPF_ROUTER_LSA
    link_state_id      :: Ipv4Address = Ipv4Address(0)
    advertising_router :: Ipv4Address = Ipv4Address(0)
    ls_sequence_number :: U32 = 0
    ls_checksum        :: Checksum16 = 0
    ls_checksum_mode   :: Model{ChecksumMode} = CHECKSUM_DECLARED
    lsa_length         :: U16 = OSPFV2_LSA_HEADER_BYTES
end

"The length an LSA header carries, measured from the LSA that holds it."
measure_lsa_length(h) = measure_header(h) ÷ 8

"""
    Ospfv2RouterTos(; tos, tos_metric)

One TOS entry of a router link — RFC 2328 appendix A.4.2. Four octets: the TOS
value, a zero octet, and a sixteen-bit metric.
"""
@header Ospfv2RouterTos begin
    tos        :: U8  = 0
    reserved   :: U8  = 0
    tos_metric :: U16 = 0
end

"""
    Ospfv2Link(; link_id, link_data, type, link_cost, tos_data)

One link of a router LSA — RFC 2328 appendix A.4.2. Twelve octets and four more
for each TOS entry.

What `link_id` and `link_data` mean depends on `type`: for a transit link the
identifier is the designated router and the data is the router's own interface
address, and for a stub link the identifier is the network and the data is the
mask.
"""
@header Ospfv2Link begin
    link_id       :: Ipv4Address = Ipv4Address(0)
    link_data     :: U32 = 0
    type          :: U8  = OSPF_LINK_POINT_TO_POINT
    number_of_tos :: U8  = 0
        derive(Base.length(tos_data))
    link_cost     :: U16 = 0
    tos_data      :: Repeated{Ospfv2RouterTos} = Ospfv2RouterTos[]
        count(number_of_tos)
end

"""
    Ospfv2RouterLsa(; links, area_border_router, as_boundary_router, …)

A router LSA, LS type 1 — RFC 2328 appendix A.4.2. One router describes every
link it has to the area.

No two links are the same width, so the list fills what `lsa_length` leaves and
`number_of_links` is what the writer derives from it.
"""
@header Ospfv2RouterLsa <: Ospfv2Lsa begin
    base                  :: Ospfv2LsaHeader =
        Ospfv2LsaHeader(ls_type = OSPF_ROUTER_LSA)
        derive(set_field(base, :lsa_length, measure_lsa_length(h)))
    reserved1             :: U5   = 0
    virtual_link_endpoint :: Bool = false
    as_boundary_router    :: Bool = false
    area_border_router    :: Bool = false
    reserved2             :: U8   = 0
    number_of_links       :: U16  = 0
        derive(Base.length(links))
    links                 :: Repeated{Ospfv2Link} = Ospfv2Link[]
        until(Bytes(base.lsa_length))
end

"""
    Ospfv2NetworkLsa(; network_mask, attached_routers)

A network LSA, LS type 2 — RFC 2328 appendix A.4.3. The designated router of a
broadcast or non-broadcast network lists every router attached to it, itself
included.
"""
@header Ospfv2NetworkLsa <: Ospfv2Lsa begin
    base             :: Ospfv2LsaHeader =
        Ospfv2LsaHeader(ls_type = OSPF_NETWORK_LSA)
        derive(set_field(base, :lsa_length, measure_lsa_length(h)))
    network_mask     :: Ipv4Address = Ipv4Address(0)
    attached_routers :: Repeated{Ipv4Address} = Ipv4Address[]
        until(Bytes(base.lsa_length))
end

"""
    Ospfv2SummaryTos(; tos, tos_metric)

One TOS entry of a summary LSA — RFC 2328 appendix A.4.4. Four octets: the TOS
value and a twenty-four-bit metric. A router link states the same two numbers
in a different shape, which is why this is its own header.
"""
@header Ospfv2SummaryTos begin
    tos        :: U8  = 0
    tos_metric :: U24 = 0
end

"""
    Ospfv2SummaryLsa(; network_mask, route_cost, tos_data)

A summary LSA — RFC 2328 appendix A.4.4. LS type 3 summarises a network into
another area and LS type 4 summarises the route to an autonomous system
boundary router. One body serves both, and `base.ls_type` says which it is.

For LS type 4 the network mask is not meaningful and RFC 2328 sends zero.
"""
@header Ospfv2SummaryLsa <: Ospfv2Lsa begin
    base         :: Ospfv2LsaHeader =
        Ospfv2LsaHeader(ls_type = OSPF_SUMMARY_LSA)
        derive(set_field(base, :lsa_length, measure_lsa_length(h)))
    network_mask :: Ipv4Address = Ipv4Address(0)
    reserved     :: U8  = 0
    route_cost   :: U24 = 0
    tos_data     :: Repeated{Ospfv2SummaryTos} = Ospfv2SummaryTos[]
        until(Bytes(base.lsa_length))
end

"""
    Ospfv2ExternalTos(; external_metric_type, tos, route_cost, …)

One metric of an AS external LSA — RFC 2328 appendix A.5. Twelve octets.

`external_metric_type` is the E bit: a type 2 metric is larger than any link
state path, and a type 1 metric is comparable with one. `forwarding_address` of
zero means the traffic goes to the advertising router itself.
"""
@header Ospfv2ExternalTos begin
    external_metric_type :: Bool = false
    tos                  :: U7   = 0
    route_cost           :: U24  = 0
    forwarding_address   :: Ipv4Address = Ipv4Address(0)
    external_route_tag   :: U32  = 0
end

"""
    Ospfv2AsExternalLsa(; network_mask, metrics)

An AS external LSA — RFC 2328 appendix A.5, LS type 5. It describes a route to
a destination outside the autonomous system.

RFC 3101 clause 2.2 gives the NSSA external LSA, LS type 7, the same body, so
this member reads both and `base.ls_type` says which arrived. INET throws on
LS type 7.
"""
@header Ospfv2AsExternalLsa <: Ospfv2Lsa begin
    base         :: Ospfv2LsaHeader =
        Ospfv2LsaHeader(ls_type = OSPF_AS_EXTERNAL_LSA)
        derive(set_field(base, :lsa_length, measure_lsa_length(h)))
    network_mask :: Ipv4Address = Ipv4Address(0)
    metrics      :: Repeated{Ospfv2ExternalTos} = Ospfv2ExternalTos[]
        until(Bytes(base.lsa_length))
end

"""
    Ospfv2RawLsa(; base, data)

An LSA of a type this library does not model. It keeps its header and its
octets, and it reads exactly as many as `lsa_length` says — so the LSA after it
in the same update still starts where it should.
"""
@header Ospfv2RawLsa <: Ospfv2Lsa begin
    base :: Ospfv2LsaHeader = Ospfv2LsaHeader()
        derive(set_field(base, :lsa_length, measure_lsa_length(h)))
    data :: Octets = UInt8[]
        until(Bytes(base.lsa_length))
end

list_variants(::Type{Ospfv2Lsa}) =
    (Ospfv2RouterLsa, Ospfv2NetworkLsa, Ospfv2SummaryLsa, Ospfv2AsExternalLsa,
     Ospfv2RawLsa)
variant_base(::Type{Ospfv2Lsa}) = Ospfv2LsaHeader

matches_variant(::Type{Ospfv2RouterLsa}, base)  = base.ls_type == OSPF_ROUTER_LSA
matches_variant(::Type{Ospfv2NetworkLsa}, base) = base.ls_type == OSPF_NETWORK_LSA
matches_variant(::Type{Ospfv2SummaryLsa}, base) =
    base.ls_type == OSPF_SUMMARY_LSA || base.ls_type == OSPF_ASBR_SUMMARY_LSA
matches_variant(::Type{Ospfv2AsExternalLsa}, base) =
    base.ls_type == OSPF_AS_EXTERNAL_LSA || base.ls_type == OSPF_NSSA_EXTERNAL_LSA

# An LSA of an unknown type is still an LSA: it says its own length, so a reader
# can step over it. The raw member claims what no other member does, and it is
# last in the list, so nothing falls through to the base.
matches_variant(::Type{Ospfv2RawLsa}, base) = true

# ---------- the packets ------------------------------------------------------

"The OSPFv2 packets — one wire format, and the type octet says which."
abstract type Ospfv2Packet <: Fields end

"""
    Ospfv2Common(; type, router_id, area_id, packet_length, …)

The twenty-four octets every OSPF packet starts with — RFC 2328 appendix A.3.1.

`packet_length` counts the whole packet, this header included. Each member
derives it, so a model states the fields and the writer states the length.

`authentication` is eight octets whose meaning `authentication_type` decides:
nothing for type 0, a password for type 1, and a key identifier with a digest
length and a sequence number for type 2.
"""
@header Ospfv2Common begin
    version             :: U8  = OSPF_VERSION_2
    type                :: U8  = OSPF_HELLO_PACKET
    packet_length       :: U16 = OSPFV2_HEADER_BYTES
    router_id           :: Ipv4Address = Ipv4Address(0)
    area_id             :: Ipv4Address = Ipv4Address(0)
    checksum            :: Checksum16 = 0
    checksum_mode       :: Model{ChecksumMode} = CHECKSUM_DECLARED
    authentication_type :: U16 = OSPF_AUTHENTICATION_NULL
    authentication      :: FixedOctets{8} = zeros(UInt8, 8)
end

"The length a common header carries, measured from the packet that holds it."
measure_packet_length(h) = measure_header(h) ÷ 8

"""
    Ospfv2Header(; base, data)

An OSPF packet of a type this library does not model. It comes back marked
misrepresented, with its octets intact.
"""
@header Ospfv2Header <: Ospfv2Packet begin
    base :: Ospfv2Common = Ospfv2Common()
        derive(set_field(base, :packet_length, measure_packet_length(h)))
    data :: Octets = UInt8[]
        until(Bytes(base.packet_length))
end

"""
    Ospfv2Hello(; network_mask, hello_interval, router_dead_interval, neighbors, …)

A hello packet — RFC 2328 appendix A.3.2. A router sends it on every interface
to find its neighbours and to elect the designated router.

`neighbors` lists every router this one has heard a hello from lately. Nothing
counts them: the list runs to the end of the packet, and `packet_length` says
where that is.

`router_priority` of zero means this router will not become the designated
router. `designated_router` and `backup_designated_router` are interface
addresses, not router identifiers.
"""
@header Ospfv2Hello <: Ospfv2Packet begin
    base                     :: Ospfv2Common =
        Ospfv2Common(type = OSPF_HELLO_PACKET)
        derive(set_field(base, :packet_length, measure_packet_length(h)))
    network_mask             :: Ipv4Address = Ipv4Address(0)
    hello_interval           :: U16 = 10
    options                  :: Ospfv2Options = Ospfv2Options()
    router_priority          :: U8  = 1
    router_dead_interval     :: U32 = 40
    designated_router        :: Ipv4Address = Ipv4Address(0)
    backup_designated_router :: Ipv4Address = Ipv4Address(0)
    neighbors                :: Repeated{Ipv4Address} = Ipv4Address[]
        until(Bytes(base.packet_length))
end

"""
    Ospfv2DatabaseDescription(; interface_mtu, lsa_headers, initial, more, master, …)

A database description packet — RFC 2328 appendix A.3.3. Two routers that are
forming an adjacency send each other the headers of every LSA they hold.

`initial` is the I bit and starts the sequence, `more` is the M bit and says
another packet follows, and `master` is the MS bit and says the sender is the
master of the exchange.
"""
@header Ospfv2DatabaseDescription <: Ospfv2Packet begin
    base               :: Ospfv2Common =
        Ospfv2Common(type = OSPF_DATABASE_DESCRIPTION_PACKET)
        derive(set_field(base, :packet_length, measure_packet_length(h)))
    interface_mtu      :: U16 = 1500
    options            :: Ospfv2Options = Ospfv2Options()
    reserved           :: U5   = 0
    initial            :: Bool = false
    more               :: Bool = false
    master             :: Bool = false
    dd_sequence_number :: U32 = 0
    lsa_headers        :: Repeated{Ospfv2LsaHeader} = Ospfv2LsaHeader[]
        until(Bytes(base.packet_length))
end

"""
    Ospfv2LsaRequest(; ls_type, link_state_id, advertising_router)

One request of a link state request packet — RFC 2328 appendix A.3.4. Twelve
octets, and the three fields together name one LSA.

The type is four octets here where an LSA header spends one on it, which is
what the standard draws.
"""
@header Ospfv2LsaRequest begin
    ls_type            :: U32 = OSPF_ROUTER_LSA
    link_state_id      :: Ipv4Address = Ipv4Address(0)
    advertising_router :: Ipv4Address = Ipv4Address(0)
end

"""
    Ospfv2LinkStateRequest(; requests)

A link state request packet — RFC 2328 appendix A.3.4. A router asks for the
LSAs it found were newer in its neighbour's database description.
"""
@header Ospfv2LinkStateRequest <: Ospfv2Packet begin
    base     :: Ospfv2Common =
        Ospfv2Common(type = OSPF_LINK_STATE_REQUEST_PACKET)
        derive(set_field(base, :packet_length, measure_packet_length(h)))
    requests :: Repeated{Ospfv2LsaRequest} = Ospfv2LsaRequest[]
        until(Bytes(base.packet_length))
end

"""
    Ospfv2LinkStateUpdate(; lsas)

A link state update packet — RFC 2328 appendix A.3.5. It carries whole LSAs,
and this is the only OSPF packet that counts what it carries.

No two LSAs are the same width, so the list fills what `packet_length` leaves
and `number_of_lsas` is what the writer derives from it.
"""
@header Ospfv2LinkStateUpdate <: Ospfv2Packet begin
    base           :: Ospfv2Common =
        Ospfv2Common(type = OSPF_LINK_STATE_UPDATE_PACKET)
        derive(set_field(base, :packet_length, measure_packet_length(h)))
    number_of_lsas :: U32 = 0
        derive(Base.length(lsas))
    lsas           :: Repeated{Ospfv2Lsa} = Ospfv2Lsa[]
        until(Bytes(base.packet_length))
end

"""
    Ospfv2LinkStateAcknowledgement(; lsa_headers)

A link state acknowledgement packet — RFC 2328 appendix A.3.6. It answers an
update with the headers of the LSAs it accepted.
"""
@header Ospfv2LinkStateAcknowledgement <: Ospfv2Packet begin
    base        :: Ospfv2Common =
        Ospfv2Common(type = OSPF_LINK_STATE_ACKNOWLEDGEMENT_PACKET)
        derive(set_field(base, :packet_length, measure_packet_length(h)))
    lsa_headers :: Repeated{Ospfv2LsaHeader} = Ospfv2LsaHeader[]
        until(Bytes(base.packet_length))
end

list_variants(::Type{Ospfv2Packet}) =
    (Ospfv2Hello, Ospfv2DatabaseDescription, Ospfv2LinkStateRequest,
     Ospfv2LinkStateUpdate, Ospfv2LinkStateAcknowledgement)
variant_base(::Type{Ospfv2Packet}) = Ospfv2Common
variant_fallback(::Type{Ospfv2Packet}) = Ospfv2Header

matches_variant(::Type{Ospfv2Hello}, base) = base.type == OSPF_HELLO_PACKET
matches_variant(::Type{Ospfv2DatabaseDescription}, base) =
    base.type == OSPF_DATABASE_DESCRIPTION_PACKET
matches_variant(::Type{Ospfv2LinkStateRequest}, base) =
    base.type == OSPF_LINK_STATE_REQUEST_PACKET
matches_variant(::Type{Ospfv2LinkStateUpdate}, base) =
    base.type == OSPF_LINK_STATE_UPDATE_PACKET
matches_variant(::Type{Ospfv2LinkStateAcknowledgement}, base) =
    base.type == OSPF_LINK_STATE_ACKNOWLEDGEMENT_PACKET
