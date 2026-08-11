# ============================================================================
# Phase 19 — Wave 2: the internet core.
#
# ARP and ICMP, checked against byte strings. IPv4, IPv6, UDP and TCP already
# have their own file; what is new here is the first real variant family in the
# library's own wire formats.
# ============================================================================
using Test
using InetPacket.PacketModule

hex19(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

@testset "ARP — RFC 826 over Ethernet and IPv4" begin
    request = ArpPacket(opcode = ARP_REQUEST,
                        source_mac = "0a:00:00:00:00:01", source_ip = "10.0.0.1",
                        destination_mac = MacAddress(0), destination_ip = "10.0.0.2")
    @test chunk_length(ArpPacket) == Bytes(28)
    @test hex19(encode_header(request)) ==
          "00 01 08 00 06 04 00 01 0a 00 00 00 00 01 0a 00 00 01 " *
          "00 00 00 00 00 00 0a 00 00 02"
    @test decode_header(ArpPacket, encode_header(request)) == request

    # The four fields that say what kind of addresses follow are fixed for
    # Ethernet over IPv4, so they are on the wire and not in the struct.
    @test fieldnames(ArpPacket) ==
          (:hardware_type, :protocol_type, :hardware_address_size,
           :protocol_address_size, :opcode, :source_mac, :source_ip,
           :destination_mac, :destination_ip)
    @test request.hardware_type == ARP_HARDWARE_ETHERNET
    @test request.protocol_address_size == 4
end

@testset "ICMP — RFC 792's eight bytes, as a variant family" begin
    @test chunk_length(IcmpCommon) == Bytes(4)
    @test chunk_length(IcmpHeader) == Bytes(8)
    @test chunk_length(IcmpEchoRequest) == Bytes(8)
    @test chunk_length(IcmpPtb) == Bytes(8)

    request = IcmpEchoRequest(identifier = 0x1234, sequence_number = 1)
    @test hex19(encode_header(request)) == "08 00 00 00 12 34 00 01"
    decoded = decode_header(IcmpMessage, encode_header(request))
    @test decoded isa IcmpEchoRequest
    @test decoded.identifier == 0x1234
    @test decoded.base.type == ICMP_ECHO_REQUEST
    @test encode_header(decoded) == encode_header(request)

    reply = IcmpEchoReply(identifier = 0x1234, sequence_number = 1)
    @test hex19(encode_header(reply)) == "00 00 00 00 12 34 00 01"
    @test decode_header(IcmpMessage, encode_header(reply)) isa IcmpEchoReply
end

@testset "ICMP — a member may need the code as well as the type" begin
    # Destination Unreachable is one type and many codes; only the
    # Fragmentation Needed code carries an MTU.
    ptb = IcmpPtb(mtu = 1500)
    @test hex19(encode_header(ptb)) == "03 04 00 00 00 00 05 dc"
    decoded = decode_header(IcmpMessage, encode_header(ptb))
    @test decoded isa IcmpPtb
    @test decoded.mtu == 1500

    # The same type with another code is not a Path MTU message.
    other = IcmpHeader(base = IcmpCommon(type = ICMP_DESTINATION_UNREACHABLE, code = 0))
    @test decode_header(IcmpMessage, encode_header(other)) isa MarkedFields{IcmpHeader}
end

@testset "ICMP — a type nobody models keeps its bytes" begin
    # The discriminator is four bytes and the message is eight, so what the
    # reader looks at and what it falls back to are two different types.
    @test variant_base(IcmpMessage) === IcmpCommon
    @test variant_fallback(IcmpMessage) === IcmpHeader

    wire = UInt8[ICMP_TIME_EXCEEDED, 0x00, 0x00, 0x00, 0xde, 0xad, 0xbe, 0xef]
    marked = decode_header(IcmpMessage, wire)
    @test marked isa MarkedFields{IcmpHeader}
    @test quality(marked) == Q_MISREPRESENTED
    @test marked.header.base.type == ICMP_TIME_EXCEEDED
    @test marked.header.unused == 0xdeadbeef
    @test encode_header(marked.header) == wire        # byte for byte
end

@testset "Wave 2 is in the corpus" begin
    corpus = Set(filter(H -> parentmodule(H) === PacketModule, list_headers()))
    for H in (ArpPacket, IcmpCommon, IcmpHeader, IcmpEchoRequest, IcmpEchoReply,
              IcmpPtb, Ipv4Header, Ipv6Header, UdpHeader, TcpHeader)
        @test H in corpus
        @test check_round_trip(H)
    end
end
