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

@testset "every declared wire format still round-trips" begin
    for T in filter(H -> parentmodule(H) === PacketModule, list_headers())
        @test check_round_trip(T)
    end
end
