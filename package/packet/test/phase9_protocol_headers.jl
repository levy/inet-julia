# ============================================================================
# Phase 9 — the protocol headers, against the octets a capture shows.
#
# Every header is checked three ways: the length it declares, the exact bytes
# it serialises to, and the value it comes back as. The byte vectors are what
# makes "accurate" a check rather than a claim — a field in the wrong order or
# one bit too wide changes them.
# ============================================================================
using Test
using InetPacket.PacketModule

hex(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

# --- lengths -----------------------------------------------------------------

@testset "declared lengths" begin
    @test chunk_length(EthernetPhyHeader) == Bytes(8)
    @test chunk_length(EthernetMacHeader) == Bytes(14)
    @test chunk_length(Ieee8021qTag)      == Bytes(4)
    @test chunk_length(EthernetFcs)       == Bytes(4)
    # IPv4 and TCP carry option lists now, so their length is a property of
    # the value. Without options they are the twenty bytes they always were.
    @test minimum_chunk_length(Ipv4Header) == Bytes(20)
    @test chunk_length(UdpHeader)         == Bytes(8)
    @test minimum_chunk_length(TcpHeader)  == Bytes(20)

    # The named constants agree with the declarations.
    @test chunk_length(EthernetPhyHeader) == Bytes(ETHERNET_PHY_HEADER_LEN_BYTES)
    @test minimum_chunk_length(Ipv4Header) == Bytes(IPV4_HEADER_BYTES)
    @test chunk_length(UdpHeader)  == Bytes(UDP_HEADER_BYTES)
    @test minimum_chunk_length(TcpHeader)  == Bytes(TCP_HEADER_BYTES)
end

# --- Ethernet ----------------------------------------------------------------

@testset "EthernetPhyHeader — seven 0x55 and the delimiter" begin
    phy = EthernetPhyHeader()
    @test hex(encode_header(phy)) == "55 55 55 55 55 55 55 d5"
    @test decode_header(EthernetPhyHeader, encode_header(phy)) == phy
    @test phy.preamble == ETHERNET_PREAMBLE
    @test phy.sfd == ETHERNET_SFD
end

@testset "EthernetMacHeader — destination first" begin
    eth = EthernetMacHeader(MacAddress("0a:00:00:00:00:02"),
                            MacAddress("0a:00:00:00:00:01"),
                            ETHERTYPE_IPV4)
    @test hex(encode_header(eth)) == "0a 00 00 00 00 02 0a 00 00 00 00 01 08 00"

    back = decode_header(EthernetMacHeader, encode_header(eth))
    @test back == eth
    @test back.destination == MacAddress("0a:00:00:00:00:02")
    @test back.type_or_length == ETHERTYPE_IPV4

    # Broadcast is six 0xff, and the header notices.
    bcast = EthernetMacHeader(MAC_BROADCAST, MacAddress("0a:00:00:00:00:01"), ETHERTYPE_ARP)
    @test hex(encode_header(bcast))[1:17] == "ff ff ff ff ff ff"
    @test is_broadcast(bcast.destination)
end

@testset "Ieee8021qTag — the tag protocol identifier is the default" begin
    tag = Ieee8021qTag(vid = UInt16(42))
    @test hex(encode_header(tag)) == "81 00 00 2a"
    @test decode_header(Ieee8021qTag, encode_header(tag)) == tag

    # Priority 3, drop eligible, VLAN 4095: pcp|dei|vid pack into two bytes.
    full = Ieee8021qTag(pcp = UInt8(3), dei = true, vid = UInt16(4095))
    @test hex(encode_header(full)) == "81 00 7f ff"
end

@testset "EthernetFcs" begin
    @test hex(encode_header(EthernetFcs(0xdeadbeef))) == "de ad be ef"
    @test decode_header(EthernetFcs, UInt8[0x11, 0x22, 0x33, 0x44]).fcs == 0x11223344
    @test EthernetFcs().fcs == 0x00000000
end

# --- IPv4 --------------------------------------------------------------------

@testset "Ipv4Header — RFC 791 byte for byte" begin
    ip = Ipv4Header(total_length = UInt16(60),
                    protocol = IP_PROTOCOL_UDP,
                    source = Ipv4Address("10.0.0.1"),
                    destination = Ipv4Address("10.0.0.2"))
    # The vector the demo page pins: 45 is version 4 and ihl 5 sharing a byte,
    # 00 3c is the total length, 40 is the TTL and 11 is UDP.
    @test hex(encode_header(ip)) ==
          "45 00 00 3c 00 00 00 00 40 11 00 00 0a 00 00 01 0a 00 00 02"

    back = decode_header(Ipv4Header, encode_header(ip))
    @test back == ip
    @test back.version == 4
    @test back.ihl == 5
    @test back.time_to_live == 64
    @test back.protocol == IP_PROTOCOL_UDP
    @test back.source == Ipv4Address(10, 0, 0, 1)

    # One byte changes when the TTL does, and only that one.
    hop = Ipv4Header(total_length = UInt16(60), time_to_live = UInt8(63),
                     protocol = IP_PROTOCOL_UDP,
                     source = Ipv4Address("10.0.0.1"),
                     destination = Ipv4Address("10.0.0.2"))
    @test encode_header(hop)[9] == 0x3f
    @test encode_header(hop)[[1:8; 10:20]] == encode_header(ip)[[1:8; 10:20]]
end

@testset "Ipv4Header — the flag bits and fragment_offset split a byte" begin
    # RFC 791 §3.1 names the flags one at a time; DF is bit 1 of the three.
    ip = Ipv4Header(total_length = UInt16(20), time_to_live = UInt8(1),
                    dont_fragment = true, fragment_offset = 0x0100,
                    protocol = IpProtocol(0),
                    source = Ipv4Address(0), destination = Ipv4Address(0))
    bytes = encode_header(ip)
    # byte 7 = 010_00001, byte 8 = 0000_0000
    @test bytes[7] == 0x41
    @test bytes[8] == 0x00

    back = decode_header(Ipv4Header, bytes)
    @test back.dont_fragment
    @test !back.more_fragments
    @test !back.reserved
    @test back.fragment_offset == 0x0100
end

# --- UDP ---------------------------------------------------------------------

@testset "UdpHeader — RFC 768" begin
    udp = UdpHeader(source_port = Port(1000), destination_port = Port(2000),
                    length = UInt16(40))
    @test hex(encode_header(udp)) == "03 e8 07 d0 00 28 00 00"

    back = decode_header(UdpHeader, encode_header(udp))
    @test back == udp
    @test back.source_port == Port(1000)
    @test back.length == 40

    # An integer converts, so a call site need not spell the wrapper.
    @test UdpHeader(source_port = 1000, destination_port = 2000, length = UInt16(40)) == udp
end

# --- TCP ---------------------------------------------------------------------

@testset "TcpHeader — RFC 9293, and the eight control bits" begin
    syn_ack = TcpHeader(source_port = 1000, destination_port = 80,
                        sequence_number = UInt32(1),
                        acknowledgment_number = UInt32(2),
                        syn = true, ack = true)
    bytes = encode_header(syn_ack)
    @test hex(bytes) ==
          "03 e8 00 50 00 00 00 01 00 00 00 02 50 12 ff ff 00 00 00 00"
    # Byte 13 is data_offset 5 and four reserved bits. Byte 14 is the eight
    # control bits, most significant first: CWR ECE URG ACK PSH RST SYN FIN.
    @test bytes[13] == 0x50
    @test bytes[14] == 0x12
    @test list_tcp_flags(syn_ack) == "ACK,SYN"

    back = decode_header(TcpHeader, bytes)
    @test back == syn_ack
    @test back.syn && back.ack
    @test !back.fin && !back.rst && !back.psh && !back.urg
    @test back.data_offset == TCP_MIN_DATA_OFFSET

    # Every bit on its own, in the order the standard draws them.
    for (name, mask) in ((:cwr, 0x80), (:ece, 0x40), (:urg, 0x20), (:ack, 0x10),
                         (:psh, 0x08), (:rst, 0x04), (:syn, 0x02), (:fin, 0x01))
        h = TcpHeader(; source_port = 1, destination_port = 1, sequence_number = UInt32(0),
                        (name => true,)...)
        @test encode_header(h)[14] == mask
    end
end

# --- the layout descriptor agrees with every codec ---------------------------

@testset "every declared header describes what it encodes" begin
    for T in (EthernetPhyHeader, EthernetMacHeader, Ieee8021qTag, EthernetFcs,
              Ipv4Header, UdpHeader, TcpHeader)
        layout = describe_layout(T)
        @test layout.name === nameof(T)
        # For a header with an option list the TYPE layout stops at the list,
        # which is exactly the fixed part.
        @test layout.length == minimum_chunk_length(T)
        @test sum(s.width for s in layout.fields) == minimum_chunk_length(T).bits
        # The layout describes the WIRE, so a model-only field is absent from it
        # and present in the struct — `Ipv4Header.checksum_mode` is the one here.
        # Every field the layout names is a field of the struct, in order.
        @test [s.name for s in layout.fields] ==
              [n for n in fieldnames(T)
               if !is_variable_field(fieldtype(T, n)) && measure_field(fieldtype(T, n)) > 0]
        offset = 0
        for s in layout.fields
            @test s.offset == offset
            offset += s.width
        end
    end
end

# --- the headers stack into a packet -----------------------------------------

@testset "a full stack, and each header read back by type" begin
    payload = Filler(Bytes(32))
    pk = Packet(payload)
    pushfirst!(pk, UdpHeader(source_port = 1000, destination_port = 2000, length = UInt16(40)))
    pushfirst!(pk, Ipv4Header(total_length = UInt16(60), protocol = IP_PROTOCOL_UDP,
                              source = Ipv4Address("10.0.0.1"),
                              destination = Ipv4Address("10.0.0.2")))
    pushfirst!(pk, EthernetMacHeader(MacAddress("0a:00:00:00:00:02"),
                                     MacAddress("0a:00:00:00:00:01"),
                                     ETHERTYPE_IPV4))
    push!(pk, EthernetFcs())

    @test data_length(pk) == Bytes(14 + 20 + 8 + 32 + 4)
    @test peek(pk, EthernetMacHeader).type_or_length == ETHERTYPE_IPV4
    @test peek(pk, EthernetFcs; from = :back).fcs == 0x00000000

    # Decapsulate, and the next header is where it should be.
    popfirst!(pk, chunk_length(EthernetMacHeader))
    @test peek(pk, Ipv4Header).protocol == IP_PROTOCOL_UDP
    popfirst!(pk, minimum_chunk_length(Ipv4Header))
    @test peek(pk, UdpHeader).destination_port == Port(2000)

    # Reading one header as another stays refused: here the front really is a
    # single MAC header chunk, so the guard has one type to compare against.
    eth_only = Packet(EthernetMacHeader(MacAddress(0), MacAddress(0), ETHERTYPE_IPV4))
    @test_throws ErrorException peek(eth_only, EthernetFcs)
end
