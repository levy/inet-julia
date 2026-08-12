# ============================================================================
# Phase 22 — Wave 4: the routing protocols and the applications.
# ============================================================================
using Test
using InetPacket.PacketModule

hex22(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

@testset "RIP — the entries fill the datagram, and nothing counts them" begin
    @test chunk_length(RipEntry) == Bytes(RIP_ENTRY_BYTES)

    packet = RipPacket(command = RIP_RESPONSE,
                       entries = [RipEntry(address = Ipv4Address("10.0.0.0"),
                                           netmask = Ipv4Address("255.255.255.0"),
                                           next_hop = Ipv4Address("0.0.0.0"),
                                           metric = UInt32(1)),
                                  RipEntry(address = Ipv4Address("10.1.0.0"),
                                           netmask = Ipv4Address("255.255.0.0"),
                                           next_hop = Ipv4Address("10.0.0.1"),
                                           metric = UInt32(2))])
    @test chunk_length(packet) == Bytes(4 + 2 * RIP_ENTRY_BYTES)
    bytes = encode_header(packet)
    @test hex22(bytes[1:4]) == "02 02 00 00"
    @test hex22(bytes[5:6]) == "00 02"          # the address family, RFC 2453

    back = decode_header(RipPacket, bytes)
    @test back == packet
    @test Base.length(back.entries) == 2
    @test back.entries[2].metric == 2
    @test back.entries[2].next_hop == Ipv4Address("10.0.0.1")
end

@testset "AODV — four control packets, and an IPv6 form of each" begin
    for (T, bytes) in ((AodvRreq, 24), (AodvRreqIpv6, 48), (AodvRrep, 20),
                       (AodvRrepIpv6, 44), (AodvRrepAck, 2), (AodvRrepAckIpv6, 2),
                       (AodvUnreachableNode, 8), (AodvUnreachableNodeIpv6, 20))
        @test chunk_length(T) == Bytes(bytes)
    end

    request = AodvRreq(destination = Ipv4Address("10.0.0.9"),
                       originator = Ipv4Address("10.0.0.1"),
                       rreq_id = UInt32(7), hop_count = 2,
                       unknown_sequence_number = true)
    bytes = encode_header(request)
    @test bytes[1] == AODV_RREQ
    # The U flag is the fifth of the five, so it is bit 3 of the second octet.
    @test bytes[2] == 0x08
    @test bytes[4] == 0x02
    got = decode_header(AodvControlPacket, bytes)
    @test got isa AodvRreq
    @test got == request

    # A route error carries at least one destination, and the count derives.
    error_packet = AodvRerr(unreachable_nodes =
        [AodvUnreachableNode(address = Ipv4Address("10.0.0.9"),
                             sequence_number = UInt32(5)),
         AodvUnreachableNode(address = Ipv4Address("10.0.0.8"),
                             sequence_number = UInt32(6))])
    @test chunk_length(error_packet) == Bytes(4 + 2 * 8)
    read_back = decode_header(AodvControlPacket, encode_header(error_packet))
    @test read_back isa AodvRerr
    @test read_back.destination_count == 2
    # RFC 3561 clause 5.3 draws the list in order. INET writes it backwards.
    @test read_back.unreachable_nodes[1].address == Ipv4Address("10.0.0.9")

    # Each of the eight packets comes back as itself.
    # `error_packet` is compared by bytes above: its destination count is
    # derived, so the struct that was built keeps the one it was given.
    @test encode_header(read_back) == encode_header(error_packet)
    for header in (request, AodvRrep(destination = Ipv4Address(0), originator = Ipv4Address(0)),
                   AodvRrepAck(), AodvRrepAckIpv6(),
                   AodvRreqIpv6(destination = IPV6_UNSPECIFIED, originator = IPV6_UNSPECIFIED),
                   AodvRrepIpv6(destination = IPV6_UNSPECIFIED, originator = IPV6_UNSPECIFIED))
        back = decode_header(AodvControlPacket, encode_header(header))
        @test !(back isa MarkedFields)
        @test back == header
    end
end

@testset "DSDV — INET's own hello, sixteen octets" begin
    hello = DsdvHello(source = Ipv4Address("10.0.0.1"),
                      next_hop = Ipv4Address("10.0.0.2"),
                      sequence_number = UInt32(3), hop_distance = UInt32(1))
    @test chunk_length(DsdvHello) == Bytes(16)
    @test hex22(encode_header(hello)) ==
          "0a 00 00 01 00 00 00 03 0a 00 00 02 00 00 00 01"
    @test decode_header(DsdvHello, encode_header(hello)) == hello
end

@testset "PIM — three encoded address forms, and every message reuses them" begin
    # RFC 7761 clause 4.9.1 defines the three forms once, so each is a header.
    @test chunk_length(PimUnicastAddress) == Bytes(6)
    @test chunk_length(PimGroupAddress) == Bytes(8)
    @test chunk_length(PimSourceAddress) == Bytes(8)
    @test chunk_length(PimCommon) == Bytes(4)
    for (T, bytes) in ((PimRegister, 8), (PimRegisterStop, 18), (PimAssert, 26),
                       (PimStateRefresh, 36))
        @test chunk_length(T) == Bytes(bytes)
    end

    # A Hello's options run to the end of the message, so nothing counts them.
    hello = PimHello(options = [PimHoldTime(hold_time = UInt16(105)),
                                PimGenerationId(generation_id = UInt32(7))])
    @test chunk_length(hello) == Bytes(4 + 6 + 8)
    bytes = encode_header(hello)
    # Version 2 over type 0 is the first octet.
    @test bytes[1] == 0x20
    @test hex22(bytes[5:10]) == "00 01 00 02 00 69"

    back = decode_header(PimPacket, bytes)
    @test back isa PimHello
    @test back == hello
    @test Base.length(back.options) == 2
    @test back.options[1] isa PimHoldTime
    @test back.options[1].hold_time == 105
    @test back.options[2].generation_id == 7

    # A Join/Prune group carries source lists of its own, so no two groups are
    # the same width and the group list fills the message.
    join_prune = PimJoinPrune(
        upstream_neighbor = PimUnicastAddress(address = Ipv4Address("10.0.0.1")),
        groups = [PimJoinPruneGroup(
            group = PimGroupAddress(address = Ipv4Address("239.1.1.1")),
            joined_sources = [PimSourceAddress(address = Ipv4Address("10.0.0.5"))])])
    @test chunk_length(join_prune) == Bytes(4 + 6 + 1 + 1 + 2 + (8 + 2 + 2 + 8))
    read_back = decode_header(PimPacket, encode_header(join_prune))
    @test read_back isa PimJoinPrune
    @test encode_header(read_back) == encode_header(join_prune)
    @test read_back.group_count == 1
    @test Base.length(read_back.groups[1].joined_sources) == 1
    @test read_back.groups[1].joined_sources[1].address == Ipv4Address("10.0.0.5")

    # A Graft carries the Join/Prune body, which is what RFC 3973 draws.
    @test header_fields(PimGraft) == header_fields(PimJoinPrune)
    @test decode_header(PimPacket, encode_header(PimGraft(
        upstream_neighbor = PimUnicastAddress(address = Ipv4Address(0))))) isa PimGraft

    # A Hello option nobody models keeps its octets.
    raw = decode_header(PimHello, vcat(encode_header(PimCommon(type = PIM_HELLO)),
                                       UInt8[0x00, 0x63, 0x00, 0x02, 0xde, 0xad]))
    @test raw.options[1] isa PimOptionRaw
    @test raw.options[1].type == 0x63
    @test raw.options[1].data == Octets(UInt8[0xde, 0xad])
end

@testset "BGP — nineteen shared octets, and the type says which message" begin
    @test chunk_length(BgpCommon) == Bytes(BGP_HEADER_BYTES)
    @test chunk_length(BgpKeepAlive) == Bytes(BGP_HEADER_BYTES)
    @test chunk_length(BgpCapabilityMultiprotocol) == Bytes(6)

    open_message = BgpOpen(my_as = UInt16(65001), hold_time = UInt16(90),
                           identifier = Ipv4Address("10.0.0.1"))
    @test chunk_length(open_message) == Bytes(BGP_OPEN_BYTES)
    bytes = encode_header(open_message)
    # The marker is all ones — RFC 4271 clause 4.1.
    @test all(byte == 0xff for byte in bytes[1:16])
    @test hex22(bytes[17:19]) == "00 1d 01"      # length 29, type OPEN
    @test bytes[20] == BGP_VERSION
    @test hex22(bytes[21:22]) == "fd e9"          # AS 65001
    @test hex22(bytes[23:24]) == "00 5a"          # hold time 90 seconds
    @test bytes[29] == 0x00                       # no optional parameters

    # A capability parameter, and the parameter length derives from it.
    with_capability = BgpOpen(
        my_as = UInt16(65001), hold_time = UInt16(90),
        identifier = Ipv4Address("10.0.0.1"),
        parameters = [BgpParameterCapabilities(
            capabilities = [BgpCapabilityMultiprotocol()])])
    @test chunk_length(with_capability) == Bytes(BGP_OPEN_BYTES + 2 + 6)
    back = decode_header(BgpOpen, encode_header(with_capability))
    @test back.parameters_length == 8
    @test Base.length(back.parameters) == 1
    @test back.parameters[1] isa BgpParameterCapabilities
    @test back.parameters[1].capabilities[1].address_family == 1

    # A version other than four fails the check. The writer refuses to emit
    # one, so the octets have to arrive that way — which is what a check is
    # for: a packet that arrived wrong is data, and a header built wrong is a
    # bug.
    wrong = copy(bytes)
    wrong[20] = 0x03
    @test decode_header(BgpOpen, wrong) isa MarkedFields
    @test_throws ErrorException encode_header(BgpOpen(version = 3,
                                                      identifier = Ipv4Address(0)))

    # RFC 4271 clause 4.5 defines NOTIFICATION. INET's serializer throws on it.
    notification = BgpNotification(error_code = BGP_ERROR_CEASE)
    @test chunk_length(notification) == Bytes(21)
    for header in (notification, BgpKeepAlive())
        got = decode_header(BgpMessage, encode_header(header))
        @test !(got isa MarkedFields)
        @test got == header
    end
end

@testset "RTP and RTCP — RFC 3550" begin
    @test chunk_length(RtcpCommon) == Bytes(4)
    @test chunk_length(RtcpReceptionReport) == Bytes(24)
    @test chunk_length(RtcpBye) == Bytes(8)
    @test chunk_length(RtpMpegHeader) == Bytes(4)

    header = RtpHeader(payload_type = 96, sequence_number = UInt16(1),
                       timestamp = UInt32(160), ssrc = UInt32(0x11223344))
    @test chunk_length(header) == Bytes(RTP_HEADER_BYTES)
    # Version 2 with no flags is 0x80; payload type 96 is 0x60.
    @test hex22(encode_header(header)) == "80 60 00 01 00 00 00 a0 11 22 33 44"
    @test decode_header(RtpHeader, encode_header(header)) == header

    # A contributing source list adds four octets each, and the count derives.
    mixed = RtpHeader(payload_type = 96, ssrc = UInt32(1),
                      contributing_sources = UInt32[2, 3])
    @test chunk_length(mixed) == Bytes(RTP_HEADER_BYTES + 8)
    back = decode_header(RtpHeader, encode_header(mixed))
    @test back.contributing_count == 2
    @test back.contributing_sources[2] == 3

    # A version other than two comes back marked.
    wrong = copy(encode_header(header))
    wrong[1] = 0x40
    @test decode_header(RtpHeader, wrong) isa MarkedFields

    # Each RTCP packet comes back as itself.
    report = RtcpSenderReport(ssrc = UInt32(1),
                              reports = [RtcpReceptionReport(ssrc = UInt32(2))])
    @test chunk_length(report) == Bytes(4 + 24 + 24)
    for header2 in (report, RtcpReceiverReport(ssrc = UInt32(1)), RtcpBye(ssrc = UInt32(1)))
        got = decode_header(RtcpPacket, encode_header(header2))
        @test !(got isa MarkedFields)
        @test got == header2
    end

    # A source description's items end at the zero octet, and the chunk pads to
    # a multiple of four.
    description = RtcpSourceDescription(ssrc = UInt32(1),
        items = [RtcpSdesCname(content = Vector{UInt8}("me"))])
    @test bits(chunk_length(description)) % 32 == 0
    read_back = decode_header(RtcpPacket, encode_header(description))
    @test read_back isa RtcpSourceDescription
    @test encode_header(read_back) == encode_header(description)
end

@testset "every declared wire format still round-trips" begin
    for T in filter(H -> parentmodule(H) === PacketModule, list_headers())
        @test check_round_trip(T)
    end
end

@testset "Mobile IPv6 — every message is a multiple of eight octets" begin
    @test chunk_length(MobilityCommon) == Bytes(6)
    for (T, bytes) in ((Mipv6BindingRefreshRequest, 8), (Mipv6HomeTestInit, 16),
                       (Mipv6CareOfTestInit, 16), (Mipv6HomeTest, 24),
                       (Mipv6CareOfTest, 24), (Mipv6BindingUpdate, 16),
                       (Mipv6BindingAcknowledgement, 16), (Mipv6BindingError, 24))
        @test chunk_length(T) == Bytes(bytes)
        # RFC 6275 clause 6.1 makes the whole header a multiple of eight.
        @test bits(chunk_length(T)) % 64 == 0
    end

    # A lifetime counts four-second units, so an hour is 900.
    update = Mipv6BindingUpdate(sequence_number = UInt16(1),
                                lifetime = build_binding_lifetime(3600),
                                home_registration = true, acknowledge = true)
    @test update.lifetime == 900
    @test measure_binding_seconds(update.lifetime) == 3600
    bytes = encode_header(update)
    @test bytes[1] == MIPV6_NO_NEXT_HEADER
    @test bytes[3] == MIPV6_BINDING_UPDATE
    # Acknowledge is the top bit of the flags, home registration the next.
    @test bytes[9] == 0xc0

    for header in (update, Mipv6BindingRefreshRequest(),
                   Mipv6HomeTestInit(cookie = UInt64(7)),
                   Mipv6HomeTest(cookie = UInt64(7), key_generation_token = UInt64(9)),
                   Mipv6BindingAcknowledgement(status = 0),
                   Mipv6BindingError(home_address = Ipv6Address("2001:db8::1")))
        got = decode_header(MobilityHeader, encode_header(header))
        @test !(got isa MarkedFields)
        @test got == header
    end
end

@testset "OSPFv2 — two variant families, one inside the other" begin
    @test chunk_length(Ospfv2Common) == Bytes(OSPFV2_HEADER_BYTES)
    @test chunk_length(Ospfv2Options) == Bytes(1)
    @test chunk_length(Ospfv2LsaHeader) == Bytes(OSPFV2_LSA_HEADER_BYTES)
    @test chunk_length(Ospfv2LsaRequest) == Bytes(OSPFV2_REQUEST_BYTES)
    # RFC 2328 appendix A.4.2 spends four octets on a router TOS entry and
    # appendix A.4.4 four on a summary one. Same width, different shape.
    @test chunk_length(Ospfv2RouterTos) == Bytes(4)
    @test chunk_length(Ospfv2SummaryTos) == Bytes(4)
    @test chunk_length(Ospfv2ExternalTos) == Bytes(12)

    common(type) = Ospfv2Common(type = type, router_id = Ipv4Address("10.0.0.1"),
                                area_id = Ipv4Address("0.0.0.0"))

    # ---------- the hello, RFC 2328 appendix A.3.2 --------------------------
    hello = Ospfv2Hello(base = common(OSPF_HELLO_PACKET),
                        network_mask = Ipv4Address("255.255.255.0"),
                        neighbors = [Ipv4Address("10.0.0.2"),
                                     Ipv4Address("10.0.0.3")])
    bytes = encode_header(hello)
    @test Base.length(bytes) == OSPFV2_HEADER_BYTES + OSPFV2_HELLO_BODY_BYTES + 8
    @test hex22(bytes[1:4]) == "02 01 00 34"     # version, type, and the length
    @test hex22(bytes[5:8]) == "0a 00 00 01"     # the router identifier
    @test hex22(bytes[25:28]) == "ff ff ff 00"   # the network mask
    @test hex22(bytes[29:30]) == "00 0a"         # ten seconds between hellos
    # The options octet sits between the hello interval and the priority, which
    # is the octet INET writes through a helper.
    @test bytes[31] == 0x00
    @test bytes[32] == 0x01                      # the router priority
    @test hex22(bytes[33:36]) == "00 00 00 28"   # forty seconds to declare dead

    # A length nobody set by hand: the writer measured the packet.
    @test hello.base.packet_length == OSPFV2_HEADER_BYTES
    back = decode_header(Ospfv2Packet, bytes)
    @test back isa Ospfv2Hello
    @test back.base.packet_length == 52
    @test Base.length(back.neighbors) == 2
    @test back.neighbors[2] == Ipv4Address("10.0.0.3")
    @test encode_header(back) == bytes

    # ---------- the options octet, RFC 2328 appendix A.2 --------------------
    # The external routing bit is bit 1 and the demand circuits bit is bit 5.
    lit = Ospfv2Hello(base = common(OSPF_HELLO_PACKET),
                      options = Ospfv2Options(external_routing = true,
                                              demand_circuits = true))
    @test encode_header(lit)[31] == 0x22

    # ---------- the router LSA, RFC 2328 appendix A.4.2 ---------------------
    link = Ospfv2Link(link_id = Ipv4Address("10.0.0.0"),
                      link_data = UInt32(0xffffff00), type = OSPF_LINK_STUB,
                      link_cost = UInt16(10),
                      tos_data = [Ospfv2RouterTos(tos = 4, tos_metric = 20)])
    @test chunk_length(link) == Bytes(12 + 4)
    router = Ospfv2RouterLsa(links = [link], area_border_router = true)
    router_bytes = encode_header(router)
    # Twenty octets of header, four of flags and count, and sixteen of link.
    @test Base.length(router_bytes) == 40
    # The LS type is the fourth octet, after the age and the options.
    @test router_bytes[4] == UInt8(OSPF_ROUTER_LSA)
    # The LSA length is the last field of the header, and it is derived.
    @test hex22(router_bytes[19:20]) == "00 28"
    @test router_bytes[21] == 0x01               # five zero bits, then V, E, B
    @test hex22(router_bytes[23:24]) == "00 01"  # one link
    @test router_bytes[33] == UInt8(OSPF_LINK_STUB)
    @test router_bytes[34] == 0x01               # one TOS entry on that link

    got = decode_header(Ospfv2Lsa, router_bytes)
    @test got isa Ospfv2RouterLsa
    @test got.area_border_router
    @test Base.length(got.links) == 1
    @test got.links[1].number_of_tos == 1
    @test got.links[1].tos_data[1].tos_metric == 20

    # ---------- the network LSA, RFC 2328 appendix A.4.3 --------------------
    network = Ospfv2NetworkLsa(network_mask = Ipv4Address("255.255.255.0"),
                               attached_routers = [Ipv4Address("10.0.0.1"),
                                                   Ipv4Address("10.0.0.2")])
    @test chunk_length(network) == Bytes(OSPFV2_LSA_HEADER_BYTES + 4 + 8)

    # ---------- one body for LS types 3 and 4, appendix A.4.4 ---------------
    summary = Ospfv2SummaryLsa(base = Ospfv2LsaHeader(ls_type = OSPF_ASBR_SUMMARY_LSA),
                               route_cost = UInt32(30))
    @test decode_header(Ospfv2Lsa, encode_header(summary)) isa Ospfv2SummaryLsa

    # ---------- RFC 3101 clause 2.2: LS type 7 has the type 5 body ----------
    # INET throws on this type.
    nssa = Ospfv2AsExternalLsa(base = Ospfv2LsaHeader(ls_type = OSPF_NSSA_EXTERNAL_LSA),
                               network_mask = Ipv4Address("255.255.0.0"),
                               metrics = [Ospfv2ExternalTos(route_cost = UInt32(20),
                                                            external_metric_type = true)])
    nssa_back = decode_header(Ospfv2Lsa, encode_header(nssa))
    @test nssa_back isa Ospfv2AsExternalLsa
    @test nssa_back.base.ls_type == OSPF_NSSA_EXTERNAL_LSA
    @test nssa_back.metrics[1].external_metric_type

    # ---------- the update, RFC 2328 appendix A.3.5 -------------------------
    update = Ospfv2LinkStateUpdate(base = common(OSPF_LINK_STATE_UPDATE_PACKET),
                                   lsas = [router, network])
    update_bytes = encode_header(update)
    @test hex22(update_bytes[25:28]) == "00 00 00 02"    # the writer counted them
    update_back = decode_header(Ospfv2Packet, update_bytes)
    @test update_back isa Ospfv2LinkStateUpdate
    @test map(typeof, update_back.lsas.values) == [Ospfv2RouterLsa, Ospfv2NetworkLsa]
    @test encode_header(update_back) == update_bytes

    # An LSA of a type nothing models keeps its octets AND its place, so the
    # LSA after it still starts where it should. INET reads no body for an
    # unknown type, and every later LSA in the same update is then garbage.
    raw = Ospfv2RawLsa(base = Ospfv2LsaHeader(ls_type = 9), data = UInt8[1, 2, 3, 4])
    mixed = Ospfv2LinkStateUpdate(base = common(OSPF_LINK_STATE_UPDATE_PACKET),
                                  lsas = [raw, network])
    mixed_bytes = encode_header(mixed)
    mixed_back = decode_header(Ospfv2Packet, mixed_bytes)
    @test map(typeof, mixed_back.lsas.values) == [Ospfv2RawLsa, Ospfv2NetworkLsa]
    @test mixed_back.lsas[1].data == Octets(UInt8[1, 2, 3, 4])
    @test mixed_back.lsas[2].attached_routers[2] == Ipv4Address("10.0.0.2")
    @test encode_header(mixed_back) == mixed_bytes

    # ---------- the database description, appendix A.3.3 --------------------
    description = Ospfv2DatabaseDescription(
        base = common(OSPF_DATABASE_DESCRIPTION_PACKET),
        interface_mtu = UInt16(1500), initial = true, more = true, master = true,
        dd_sequence_number = UInt32(1000),
        lsa_headers = [Ospfv2LsaHeader(ls_type = OSPF_ROUTER_LSA)])
    description_bytes = encode_header(description)
    @test Base.length(description_bytes) ==
          OSPFV2_HEADER_BYTES + OSPFV2_DATABASE_DESCRIPTION_BYTES +
          OSPFV2_LSA_HEADER_BYTES
    @test hex22(description_bytes[25:26]) == "05 dc"     # the interface MTU
    @test description_bytes[28] == 0x07                  # five zeros, I, M, MS
    description_back = decode_header(Ospfv2Packet, description_bytes)
    @test description_back isa Ospfv2DatabaseDescription
    @test description_back.master
    @test Base.length(description_back.lsa_headers) == 1

    # ---------- the request and the acknowledgement -------------------------
    request = Ospfv2LinkStateRequest(
        base = common(OSPF_LINK_STATE_REQUEST_PACKET),
        requests = [Ospfv2LsaRequest(link_state_id = Ipv4Address("10.0.0.0"),
                                     advertising_router = Ipv4Address("10.0.0.2"))])
    @test chunk_length(request) == Bytes(OSPFV2_HEADER_BYTES + OSPFV2_REQUEST_BYTES)
    request_back = decode_header(Ospfv2Packet, encode_header(request))
    @test request_back isa Ospfv2LinkStateRequest
    @test request_back.requests[1].advertising_router == Ipv4Address("10.0.0.2")

    acknowledgement = Ospfv2LinkStateAcknowledgement(
        base = common(OSPF_LINK_STATE_ACKNOWLEDGEMENT_PACKET),
        lsa_headers = [Ospfv2LsaHeader(ls_type = OSPF_NETWORK_LSA),
                       Ospfv2LsaHeader(ls_type = OSPF_ROUTER_LSA)])
    acknowledgement_back =
        decode_header(Ospfv2Packet, encode_header(acknowledgement))
    @test acknowledgement_back isa Ospfv2LinkStateAcknowledgement
    @test Base.length(acknowledgement_back.lsa_headers) == 2

    # ---------- a packet type nothing models -------------------------------
    unknown = decode_header(Ospfv2Packet,
                            encode_header(Ospfv2Header(base = common(99),
                                                       data = UInt8[7, 7])))
    @test unknown isa MarkedFields
    @test unknown.header isa Ospfv2Header
    @test unknown.header.data == Octets(UInt8[7, 7])
end

@testset "OSPFv3 — sixteen octets of header, and a prefix that says its width" begin
    # Version 3 authenticates with the IPv6 authentication header, so it spends
    # no octets on authentication — RFC 5340 clause 2.5.
    @test chunk_length(Ospfv3Common) == Bytes(OSPFV3_HEADER_BYTES)
    @test chunk_length(Ospfv3Common) < chunk_length(Ospfv2Common)
    @test chunk_length(Ospfv3Options) == Bytes(3)
    @test chunk_length(Ospfv3PrefixOptions) == Bytes(1)
    @test chunk_length(Ospfv3LsaHeader) == Bytes(OSPFV3_LSA_HEADER_BYTES)
    @test chunk_length(Ospfv3LsaRequest) == Bytes(OSPFV3_REQUEST_BYTES)
    @test chunk_length(Ospfv3RouterLink) == Bytes(OSPFV3_ROUTER_LINK_BYTES)

    common(type) = Ospfv3Common(type = type, router_id = Ipv4Address("10.0.0.1"))

    # ---------- the hello, RFC 5340 appendix A.3.2 --------------------------
    hello = Ospfv3Hello(base = common(OSPF_HELLO_PACKET),
                        interface_id = UInt32(5),
                        neighbors = [Ipv4Address("10.0.0.2")])
    bytes = encode_header(hello)
    @test Base.length(bytes) == OSPFV3_HEADER_BYTES + OSPFV3_HELLO_BODY_BYTES + 4
    @test hex22(bytes[1:4]) == "03 01 00 28"     # version three, and the length
    @test hex22(bytes[17:20]) == "00 00 00 05"   # the interface identifier
    @test bytes[21] == 0x01                      # the router priority
    # The options are three octets, and the R and V6 bits are on by default.
    @test hex22(bytes[22:24]) == "00 00 11"
    @test hex22(bytes[25:26]) == "00 0a"         # ten seconds between hellos
    @test hex22(bytes[27:28]) == "00 28"         # forty seconds to declare dead

    back = decode_header(Ospfv3Packet, bytes)
    @test back isa Ospfv3Hello
    @test back.options.router
    @test back.options.ipv6
    @test back.interface_id == 5
    @test Base.length(back.neighbors) == 1
    @test encode_header(back) == bytes

    # ---------- an address prefix, RFC 5340 appendix A.4.1 ------------------
    # The prefix is a whole number of thirty-two-bit words, so a prefix of one
    # bit takes four octets and a prefix of thirty-three takes eight.
    for (prefix_length, octets) in ((0, 0), (1, 4), (32, 4), (33, 8), (64, 8),
                                    (128, 16))
        @test measure_prefix_bytes(prefix_length) == octets
        prefix = Ospfv3Prefix(prefix_length = UInt8(prefix_length),
                              address = zeros(UInt8, octets))
        @test chunk_length(prefix) == Bytes(4 + octets)
        prefix_bytes = encode_header(prefix)
        read_back = decode_header(Ospfv3Prefix, prefix_bytes)
        @test Base.length(read_back.address) == octets
        @test encode_header(read_back) == prefix_bytes
    end

    # A prefix whose length and address disagree is a header the model built
    # wrong, and the writer says so rather than emitting octets nothing reads.
    @test_throws Exception encode_header(Ospfv3Prefix(prefix_length = UInt8(64),
                                                      address = UInt8[1]))

    # ---------- the LS type keeps all sixteen bits, appendix A.4.2.1 --------
    # INET computes the scope from the function code and drops the U bit, so an
    # LSA with that bit set does not survive its serializer.
    header = Ospfv3LsaHeader(unknown = true, scope = OSPFV3_SCOPE_AS,
                             function_code = OSPFV3_LINK_LSA)
    header_bytes = encode_header(header)
    @test hex22(header_bytes[3:4]) == "c0 08"    # U set, S2 S1 = 10, code 8
    header_back = decode_header(Ospfv3LsaHeader, header_bytes)
    @test header_back.unknown
    @test header_back.scope == OSPFV3_SCOPE_AS
    @test header_back.function_code == OSPFV3_LINK_LSA

    # ---------- the link LSA, RFC 5340 appendix A.4.9 -----------------------
    link_lsa = Ospfv3LinkLsa(link_local_address = Ipv6Address("fe80::1"),
                             prefixes = [Ospfv3Prefix(prefix_length = UInt8(64),
                                                      address = zeros(UInt8, 8)),
                                         Ospfv3Prefix(prefix_length = UInt8(0))])
    link_bytes = encode_header(link_lsa)
    @test Base.length(link_bytes) == OSPFV3_LSA_HEADER_BYTES + 24 + 12 + 4
    link_back = decode_header(Ospfv3Lsa, link_bytes)
    @test link_back isa Ospfv3LinkLsa
    @test link_back.number_of_prefixes == 2       # the writer counted them
    @test Base.length(link_back.prefixes) == 2
    @test link_back.prefixes[1].prefix_length == 64
    @test Base.length(link_back.prefixes[2].address) == 0
    @test link_back.link_local_address == Ipv6Address("fe80::1")

    # ---------- the AS external LSA, appendix A.4.7 -------------------------
    # Three fields are there only when a bit says so. INET throws on this LSA.
    external = Ospfv3AsExternalLsa(metric = UInt32(20), prefix_length = UInt8(64),
                                   address = zeros(UInt8, 8),
                                   has_forwarding_address = true,
                                   forwarding_address = Ipv6Address("2001:db8::1"),
                                   has_external_route_tag = true,
                                   external_route_tag = UInt32(7))
    @test chunk_length(external) == Bytes(20 + 4 + 4 + 8 + 16 + 4)
    external_back = decode_header(Ospfv3Lsa, encode_header(external))
    @test external_back isa Ospfv3AsExternalLsa
    @test external_back.forwarding_address == Ipv6Address("2001:db8::1")
    @test external_back.external_route_tag == 7
    @test external_back.referenced_link_state_id === nothing

    # With both bits clear the two fields take no octets at all.
    bare = Ospfv3AsExternalLsa(metric = UInt32(20))
    @test chunk_length(bare) == Bytes(20 + 4 + 4)
    bare_back = decode_header(Ospfv3Lsa, encode_header(bare))
    @test bare_back.forwarding_address === nothing
    @test bare_back.external_route_tag === nothing

    # A referenced LS type that is not zero brings its link state identifier.
    referenced = Ospfv3AsExternalLsa(metric = UInt32(20),
                                     referenced_ls_type = UInt16(9),
                                     referenced_link_state_id = Ipv4Address("10.0.0.9"))
    referenced_back = decode_header(Ospfv3Lsa, encode_header(referenced))
    @test referenced_back.referenced_link_state_id == Ipv4Address("10.0.0.9")

    # An NSSA LSA has the same body — RFC 5340 clause 4.4.3.9.
    nssa = Ospfv3AsExternalLsa(base = Ospfv3LsaHeader(function_code = OSPFV3_NSSA_LSA))
    nssa_back = decode_header(Ospfv3Lsa, encode_header(nssa))
    @test nssa_back isa Ospfv3AsExternalLsa
    @test nssa_back.base.function_code == OSPFV3_NSSA_LSA

    # ---------- the inter-area router LSA, appendix A.4.6 -------------------
    # INET declares this LSA and its serializer throws on it.
    inter_area = Ospfv3InterAreaRouterLsa(metric = UInt32(5),
                                          destination_router_id = Ipv4Address("10.0.0.7"))
    @test chunk_length(inter_area) == Bytes(OSPFV3_LSA_HEADER_BYTES + 12)
    inter_area_back = decode_header(Ospfv3Lsa, encode_header(inter_area))
    @test inter_area_back isa Ospfv3InterAreaRouterLsa
    @test inter_area_back.destination_router_id == Ipv4Address("10.0.0.7")

    # ---------- the router LSA carries no address, appendix A.4.3 -----------
    router = Ospfv3RouterLsa(area_border_router = true,
                             links = [Ospfv3RouterLink(type = OSPFV3_LINK_TRANSIT,
                                                       metric = UInt16(10),
                                                       interface_id = UInt32(1),
                                                       neighbor_interface_id = UInt32(2))])
    @test chunk_length(router) ==
          Bytes(OSPFV3_LSA_HEADER_BYTES + 4 + OSPFV3_ROUTER_LINK_BYTES)
    router_back = decode_header(Ospfv3Lsa, encode_header(router))
    @test router_back isa Ospfv3RouterLsa
    @test router_back.area_border_router
    @test router_back.links[1].neighbor_interface_id == 2

    # ---------- an update carries all three, and one it does not model ------
    update = Ospfv3LinkStateUpdate(
        base = common(OSPF_LINK_STATE_UPDATE_PACKET),
        lsas = [link_lsa, external,
                Ospfv3RawLsa(base = Ospfv3LsaHeader(function_code = 99),
                             data = UInt8[9, 9])])
    update_bytes = encode_header(update)
    @test hex22(update_bytes[17:20]) == "00 00 00 03"
    update_back = decode_header(Ospfv3Packet, update_bytes)
    @test map(typeof, update_back.lsas.values) ==
          [Ospfv3LinkLsa, Ospfv3AsExternalLsa, Ospfv3RawLsa]
    @test update_back.lsas[3].data == Octets(UInt8[9, 9])
    @test encode_header(update_back) == update_bytes

    # ---------- the database description, appendix A.3.3 --------------------
    description = Ospfv3DatabaseDescription(
        base = common(OSPF_DATABASE_DESCRIPTION_PACKET),
        interface_mtu = UInt16(1500), initial = true, more = true, master = true,
        dd_sequence_number = UInt32(1000),
        lsa_headers = [Ospfv3LsaHeader(function_code = OSPFV3_ROUTER_LSA)])
    description_bytes = encode_header(description)
    @test Base.length(description_bytes) ==
          OSPFV3_HEADER_BYTES + OSPFV3_DATABASE_DESCRIPTION_BYTES +
          OSPFV3_LSA_HEADER_BYTES
    @test hex22(description_bytes[21:22]) == "05 dc"     # the interface MTU
    @test description_bytes[24] == 0x07                  # five zeros, I, M, MS
    description_back = decode_header(Ospfv3Packet, description_bytes)
    @test description_back isa Ospfv3DatabaseDescription
    @test description_back.master
    @test Base.length(description_back.lsa_headers) == 1

    # ---------- the intra-area prefix LSA, appendix A.4.10 ------------------
    # Version 3 took the addresses out of the topology, and this is where they
    # went. Its prefixes spend the two reserved octets on a metric.
    intra_area = Ospfv3IntraAreaPrefixLsa(
        referenced_ls_type = UInt16(OSPFV3_ROUTER_LSA),
        prefixes = [Ospfv3PrefixMetric(prefix_length = UInt8(64),
                                       metric = UInt16(10),
                                       address = zeros(UInt8, 8))])
    intra_area_back = decode_header(Ospfv3Lsa, encode_header(intra_area))
    @test intra_area_back isa Ospfv3IntraAreaPrefixLsa
    @test intra_area_back.number_of_prefixes == 1
    @test intra_area_back.prefixes[1].metric == 10

    # ---------- the request and the acknowledgement -------------------------
    request = Ospfv3LinkStateRequest(
        base = common(OSPF_LINK_STATE_REQUEST_PACKET),
        requests = [Ospfv3LsaRequest(function_code = OSPFV3_LINK_LSA,
                                     advertising_router = Ipv4Address("10.0.0.2"))])
    @test chunk_length(request) == Bytes(OSPFV3_HEADER_BYTES + OSPFV3_REQUEST_BYTES)
    request_back = decode_header(Ospfv3Packet, encode_header(request))
    @test request_back isa Ospfv3LinkStateRequest
    @test request_back.requests[1].function_code == OSPFV3_LINK_LSA

    acknowledgement = Ospfv3LinkStateAcknowledgement(
        base = common(OSPF_LINK_STATE_ACKNOWLEDGEMENT_PACKET),
        lsa_headers = [Ospfv3LsaHeader(function_code = OSPFV3_NETWORK_LSA)])
    acknowledgement_back =
        decode_header(Ospfv3Packet, encode_header(acknowledgement))
    @test acknowledgement_back isa Ospfv3LinkStateAcknowledgement
    @test Base.length(acknowledgement_back.lsa_headers) == 1

    # ---------- a packet type nothing models -------------------------------
    unknown = decode_header(Ospfv3Packet,
                            encode_header(Ospfv3Header(base = common(99),
                                                       data = UInt8[7, 7])))
    @test unknown isa MarkedFields
    @test unknown.header isa Ospfv3Header
    @test unknown.header.data == Octets(UInt8[7, 7])
end

@testset "BGP UPDATE — a prefix in bits, and a length field that changes width" begin
    # ---------- a prefix whose length counts bits, RFC 4271 clause 4.3 ------
    for (prefix_length, octets) in ((0, 0), (1, 1), (8, 1), (24, 3), (25, 4),
                                    (32, 4), (64, 8))
        @test measure_prefix_octets(prefix_length) == octets
        prefix = BgpPrefix(prefix_length = UInt8(prefix_length),
                           prefix = zeros(UInt8, octets))
        @test chunk_length(prefix) == Bytes(1 + octets)
        prefix_bytes = encode_header(prefix)
        read_back = decode_header(BgpPrefix, prefix_bytes)
        @test Base.length(read_back.prefix) == octets
        @test encode_header(read_back) == prefix_bytes
    end
    # A /24 is three octets of prefix, not four.
    @test hex22(encode_header(BgpPrefix(prefix_length = UInt8(24),
                                        prefix = UInt8[10, 0, 1]))) == "18 0a 00 01"
    @test_throws Exception encode_header(BgpPrefix(prefix_length = UInt8(24),
                                                   prefix = UInt8[10]))

    # ---------- the attributes, RFC 4271 clause 5 ---------------------------
    origin = BgpAttributeOrigin(value = BGP_ORIGIN_EGP)
    # Flags 0x40 is transitive and nothing else, then the type, the length, the
    # value — RFC 4271 clause 4.3.
    @test hex22(encode_header(origin)) == "40 01 01 01"

    as_path = BgpAttributeAsPath(
        segments = [BgpAsPathSegment(as_numbers = UInt16[65001, 65002])])
    # The segment length counts AS numbers, and the attribute length octets.
    @test hex22(encode_header(as_path)) == "40 02 06 02 02 fd e9 fd ea"
    as_path_back = decode_header(BgpAttribute, encode_header(as_path))
    @test as_path_back isa BgpAttributeAsPath
    @test as_path_back.segments[1].length == 2
    @test as_path_back.segments[1].as_numbers.values == UInt16[65001, 65002]

    # ATOMIC_AGGREGATE has no value at all: its presence is the message.
    @test chunk_length(BgpAttributeAtomicAggregate()) == Bytes(3)
    @test hex22(encode_header(BgpAttributeAtomicAggregate())) == "40 06 00"

    # ---------- the Extended Length bit, RFC 4271 clause 4.3 ----------------
    # It is the one length field in the inventory whose own width changes.
    narrow = BgpAttributeRaw(base = BgpAttributeHeader(type_code = 99),
                             value = UInt8[1, 2])
    @test hex22(encode_header(narrow)) == "40 63 02 01 02"
    @test measure_attribute_header_bytes(narrow.base) == 3

    wide = BgpAttributeRaw(base = BgpAttributeHeader(type_code = 99,
                                                     optional = true,
                                                     extended_length = true),
                           value = zeros(UInt8, 300))
    wide_bytes = encode_header(wide)
    @test Base.length(wide_bytes) == 4 + 300
    # Optional, transitive, not partial, extended: 1101 0000.
    @test hex22(wide_bytes[1:4]) == "d0 63 01 2c"
    wide_back = decode_header(BgpAttribute, wide_bytes)
    @test wide_back isa BgpAttributeRaw
    @test measure_attribute_length(wide_back.base) == 300
    @test Base.length(wide_back.value) == 300
    @test encode_header(wide_back) == wide_bytes

    # With the bit clear the high octet was never on the wire, so it reads back
    # absent; with the bit set it is there.
    @test decode_header(BgpAttribute, encode_header(narrow)).base.length_high === nothing
    @test wide_back.base.length_high == 1

    # ---------- MP_REACH_NLRI, RFC 4760 clause 3 ---------------------------
    # One prefix header serves IPv4 and IPv6; INET declares two structs.
    reach = BgpAttributeMpReachNlri(next_hop = collect(UInt8, 1:16),
                                    prefixes = [BgpPrefix(prefix_length = UInt8(64),
                                                          prefix = zeros(UInt8, 8))])
    @test chunk_length(reach) == Bytes(3 + 2 + 1 + 1 + 16 + 1 + 9)
    reach_back = decode_header(BgpAttribute, encode_header(reach))
    @test reach_back isa BgpAttributeMpReachNlri
    @test reach_back.next_hop_length == 16       # the writer measured it
    @test Base.length(reach_back.prefixes) == 1
    @test reach_back.prefixes[1].prefix_length == 64

    unreach = BgpAttributeMpUnreachNlri(
        withdrawn_routes = [BgpPrefix(prefix_length = UInt8(48),
                                      prefix = zeros(UInt8, 6))])
    unreach_back = decode_header(BgpAttribute, encode_header(unreach))
    @test unreach_back isa BgpAttributeMpUnreachNlri
    @test Base.length(unreach_back.withdrawn_routes) == 1

    # ---------- the whole message, RFC 4271 clause 4.3 ---------------------
    update = BgpUpdate(
        withdrawn_routes = [BgpPrefix(prefix_length = UInt8(24),
                                      prefix = UInt8[10, 0, 1])],
        path_attributes = [origin, as_path,
                           BgpAttributeNextHop(value = Ipv4Address("10.0.0.1"))],
        nlri = [BgpPrefix(prefix_length = UInt8(16), prefix = UInt8[10, 1])])
    update_bytes = encode_header(update)
    @test Base.length(update_bytes) == 50
    # Both length fields are measurements, so the writer takes them.
    @test hex22(update_bytes[20:21]) == "00 04"     # one /24 is four octets
    @test hex22(update_bytes[26:27]) == "00 14"     # four, nine and seven

    update_back = decode_header(BgpMessage, update_bytes)
    @test update_back isa BgpUpdate
    @test update_back.base.total_length == 50
    @test map(typeof, update_back.path_attributes.values) ==
          [BgpAttributeOrigin, BgpAttributeAsPath, BgpAttributeNextHop]
    @test Base.length(update_back.withdrawn_routes) == 1
    @test update_back.withdrawn_routes[1].prefix == Octets(UInt8[10, 0, 1])
    @test Base.length(update_back.nlri) == 1
    @test update_back.nlri[1].prefix_length == 16
    @test encode_header(update_back) == update_bytes

    # An UPDATE with nothing in it is twenty-three octets.
    empty = BgpUpdate()
    @test chunk_length(empty) == Bytes(BGP_UPDATE_BYTES)
    @test decode_header(BgpMessage, encode_header(empty)) isa BgpUpdate

    # An attribute of a code nothing models keeps its octets AND its place.
    mixed = BgpUpdate(path_attributes = [narrow, origin])
    mixed_back = decode_header(BgpMessage, encode_header(mixed))
    @test map(typeof, mixed_back.path_attributes.values) ==
          [BgpAttributeRaw, BgpAttributeOrigin]
    @test mixed_back.path_attributes[2].value == BGP_ORIGIN_EGP

    # ---------- every message now measures itself, RFC 4271 clause 4.1 -----
    with_parameters = BgpOpen(my_as = UInt16(65001), identifier = Ipv4Address(0),
                              parameters = [BgpParameterCapabilities(
                                  capabilities = [BgpCapabilityMultiprotocol()])])
    @test encode_header(with_parameters)[17] == 0x00
    # The default said twenty-nine; the writer measured thirty-seven.
    @test with_parameters.base.total_length == BGP_OPEN_BYTES
    @test decode_header(BgpMessage, encode_header(with_parameters)).base.total_length ==
          bytes(chunk_length(with_parameters))
end
