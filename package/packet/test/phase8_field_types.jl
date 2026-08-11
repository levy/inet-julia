# ============================================================================
# Phase 8 — the values the standards name.
#
# A protocol field is rarely "a 16-bit number". RFC 768 calls it a Source Port
# and RFC 791 calls it a Protocol, so each is a type here. The type carries the
# width, and it prints itself — which is why no declaration anywhere states a
# display base.
# ============================================================================
using Test
using InetPacket.PacketModule

@testset "MacAddress — parse, print, round-trip" begin
    m = MacAddress("0a:00:00:00:00:01")
    @test list_mac_octets(m) == (0x0a, 0x00, 0x00, 0x00, 0x00, 0x01)
    @test string(m) == "0a:00:00:00:00:01"
    @test MacAddress(0x0a, 0x00, 0x00, 0x00, 0x00, 0x01) == m
    @test measure_field(MacAddress) == 48
    @test decode_field(MacAddress, encode_field(MacAddress, m)) == m
    @test is_broadcast(MAC_BROADCAST)
    @test !is_broadcast(m)
    @test is_multicast(MacAddress("01:00:5e:00:00:01"))
    @test !is_multicast(m)
    @test_throws ErrorException MacAddress("0a:00:00")
    @test classify_display(MacAddress) === :openable
end

@testset "Ipv4Address — parse, print, round-trip" begin
    a = Ipv4Address("10.0.0.1")
    @test list_ipv4_octets(a) == (0x0a, 0x00, 0x00, 0x01)
    @test string(a) == "10.0.0.1"
    @test Ipv4Address(10, 0, 0, 1) == a
    @test measure_field(Ipv4Address) == 32
    @test decode_field(Ipv4Address, encode_field(Ipv4Address, a)) == a
    @test_throws ErrorException Ipv4Address("10.0.0")
end

@testset "Ipv6Address — 128 bits, and RFC 5952 text" begin
    @test measure_field(Ipv6Address) == 128
    @test string(Ipv6Address("2001:db8::1")) == "2001:db8::1"
    @test string(IPV6_UNSPECIFIED) == "::"
    @test string(IPV6_LOOPBACK) == "::1"
    # The longest run of zero groups shortens, and only a run of two.
    @test string(Ipv6Address("fe80:0:0:0:1:2:3:4")) == "fe80::1:2:3:4"
    @test string(Ipv6Address("1:0:2:0:0:3:0:4")) == "1:0:2::3:0:4"
    @test Ipv6Address("2001:db8:0:0:0:0:0:1") == Ipv6Address("2001:db8::1")
    @test list_ipv6_groups(Ipv6Address("2001:db8::1"))[1] == 0x2001
    @test_throws ErrorException Ipv6Address("1:2:3")
    # No `UInt64` carries it, so it writes and reads itself.
    writer = BitWriter()
    write_field(writer, Ipv6Address, Ipv6Address("2001:db8::1"), 128, :be)
    @test read_field(BitReader(writer.bytes), Ipv6Address, 128, :be) ==
          Ipv6Address("2001:db8::1")
    @test !has_field_bits(Ipv6Address)
end

@testset "EtherTypeOrLength — one field, two readings" begin
    @test measure_field(EtherTypeOrLength) == 16
    @test find_ether_type_name(EtherTypeOrLength(0x0800)) == "IPv4"
    @test find_ether_type_name(EtherTypeOrLength(0x88b5)) === nothing
    @test string(EtherTypeOrLength(0x88b5)) == "0x88b5"
    @test MAX_ETHERNET_LENGTH_FIELD == 1500
    @test MIN_ETHERNET_TYPE_FIELD == 1536
end

@testset "IpProtocol — the number, and the name when there is one" begin
    @test measure_field(IpProtocol) == 8
    @test find_ip_protocol_name(IP_PROTOCOL_UDP) == "UDP"
    @test find_ip_protocol_name(IpProtocol(200)) === nothing
    @test string(IP_PROTOCOL_TCP) == "TCP (6)"
    @test string(IpProtocol(200)) == "200"
end

@testset "Port and Checksum16 print without being told how" begin
    @test measure_field(Port) == 16
    @test string(Port(1000)) == "1000"
    @test Int(Port(1000)) == 1000
    @test Port(1000) == 1000

    @test measure_field(Checksum16) == 16
    @test string(Checksum16(0x1234)) == "0x1234"     # hex, because it is a checksum
    @test is_absent(Checksum16(0))                   # RFC 768 gives zero a meaning
    @test !is_absent(Checksum16(1))
    @test classify_display(Checksum16) === :scalar
end

@testset "Constant — on the wire, and nothing in the struct" begin
    signature = Constant{U8, 0x4E}()
    @test measure_field(typeof(signature)) == 8
    @test sizeof(typeof(signature)) == 0             # a singleton stores nothing
    writer = BitWriter()
    write_field(writer, typeof(signature), signature, 8, :be)
    @test writer.bytes == UInt8[0x4E]
    # A constant discards what it reads: a sender that wrote the wrong value
    # still gives a header, and what it wrote is gone.
    @test read_field(BitReader(UInt8[0xff]), typeof(signature), 8, :be) == signature
end

@testset "Model — in the struct, and never on the wire" begin
    mode = Model{ChecksumMode}(CHECKSUM_COMPUTED)
    @test measure_field(typeof(mode)) == 0
    @test mode.value == CHECKSUM_COMPUTED
    @test string(mode) == "CHECKSUM_COMPUTED"
    @test default_field(ChecksumMode) == CHECKSUM_DECLARED
end

@testset "the checksum machinery" begin
    # The worked example of RFC 1071 §3.
    @test compute_ones_complement(UInt8[0x00, 0x01, 0xf2, 0x03, 0xf4, 0xf5, 0xf6, 0xf7]) ==
          0x220d
    # An odd length pads with a zero on the right, so a trailing zero is free.
    @test compute_ones_complement(UInt8[0x12]) == compute_ones_complement(UInt8[0x12, 0x00])
    @test compute_ones_complement(UInt8[]) == 0xffff
end
