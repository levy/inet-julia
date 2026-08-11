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
    @test fieldnames(PimGraft) == fieldnames(PimJoinPrune)
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
