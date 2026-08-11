# ============================================================================
# Phase 3 — a header is a struct, and the codec is generic.
#
# `fieldnames` and `fieldtypes` are the layout, so nothing below declares a
# codec. `EthernetMacHeader` is the plainest case: three fields, three types,
# no default, no macro. Everything the codec does, it does from the struct.
# ============================================================================
using Test
using InetPacket.PacketModule

hex3(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

# --- the value types ---------------------------------------------------------

@testset "U{N} — a width the value cannot exceed" begin
    @test measure_field(U4) == 4
    @test measure_field(U13) == 13
    @test measure_field(U16) == 16
    @test typemax(U4) == U4(15)
    @test typemin(U4) == U4(0)

    # The check the old width segment could not make: a 4-bit field refuses a
    # value the wire would truncate to something else.
    @test_throws InexactError U4(16)
    @test_throws InexactError U13(8192)
    @test U4(15) * 4 == 60          # a U is a number
    @test U4(5) + U4(2) == 7
    @test U4(5) < U4(6)

    # The storage is the smallest standard unsigned that holds the width.
    @test store_unsigned(4) === UInt8
    @test store_unsigned(13) === UInt16
    @test store_unsigned(20) === UInt32
    @test store_unsigned(56) === UInt64
end

@testset "I{N} — two's complement over the declared width" begin
    @test measure_field(I12) == 12
    @test typemax(I12) == I12(2047)
    @test typemin(I12) == I12(-2048)
    @test_throws InexactError I12(2048)
    @test extend_sign(UInt64(0xfff), 12) == -1
    @test extend_sign(UInt64(0x7ff), 12) == 2047
    @test extend_sign(UInt64(0x800), 12) == -2048
end

@testset "a flag is a Bool, because Bool already measures one bit" begin
    @test measure_field(Bool) == 1
    @test encode_field(Bool, true) == 1
    @test decode_field(Bool, UInt64(0)) === false
end

# --- the plainest header there is --------------------------------------------

@testset "EthernetMacHeader — a struct, and nothing else" begin
    mac = EthernetMacHeader("0a:00:00:00:00:02", "0a:00:00:00:00:01", ETHERTYPE_IPV4)

    @test chunk_length(EthernetMacHeader) == Bytes(14)
    @test chunk_length(mac) == Bytes(14)
    @test hex3(encode_header(mac)) == "0a 00 00 00 00 02 0a 00 00 00 00 01 08 00"
    @test decode_header(EthernetMacHeader, encode_header(mac)) == mac

    # A string, an integer or a built value all reach the field type.
    @test EthernetMacHeader(MAC_BROADCAST, MacAddress(1), 0x0800).destination ==
          MAC_BROADCAST
    @test mac.destination == MacAddress("0a:00:00:00:00:02")
    @test is_type(mac.type_or_length)
    @test !is_length(mac.type_or_length)
end

@testset "EtherTypeOrLength — one field, two readings" begin
    # IEEE 802.3 clause 3.2.6, which INET splits into two chunk classes.
    @test is_length(EtherTypeOrLength(1500))
    @test !is_type(EtherTypeOrLength(1500))
    @test is_type(EtherTypeOrLength(0x0800))
    @test string(EtherTypeOrLength(1500)) == "1500 B"
    @test string(EtherTypeOrLength(0x0800)) == "IPv4 (0x0800)"
    @test string(EtherTypeOrLength(0x9999)) == "0x9999"
    @test find_ether_type_name(ETHERTYPE_ARP) == "ARP"
end

# --- the layout the struct already is ----------------------------------------

@testset "describe_layout reads the same field types the codec does" begin
    layout = describe_layout(EthernetMacHeader)
    @test layout.name === :EthernetMacHeader
    @test [f.name for f in layout.fields] == [:destination, :source, :type_or_length]
    @test [f.offset for f in layout.fields] == [0, 48, 96]
    @test [f.width for f in layout.fields] == [48, 48, 16]
    @test layout.length == Bytes(14)
    @test describe_layout(EthernetMacHeader).length ==
          describe_layout(EthernetMacHeader(MAC_BROADCAST, MAC_BROADCAST, 0)).length

    ipv4 = describe_layout(Ipv4Header)
    @test [f.offset for f in ipv4.fields[1:5]] == [0, 4, 8, 14, 16]
    @test ipv4.length == Bytes(20)
    @test sum(f.width for f in ipv4.fields) == 160
end

@testset "a view reads the value, and the value prints itself" begin
    mac = EthernetMacHeader("0a:00:00:00:00:02", "0a:00:00:00:00:01", ETHERTYPE_IPV4)
    layout = describe_layout(EthernetMacHeader)
    destination = layout.fields[1]

    @test get_field(mac, destination) == MacAddress("0a:00:00:00:00:02")
    @test format_field(mac, destination) == "0a:00:00:00:00:02"
    @test encode_field(mac, destination) == 0x0a0000000002
    @test !is_constant(destination)
    @test has_bits(destination)
    @test classify_display(destination) === :openable
    @test classify_display(layout.fields[3]) === :openable
end

# --- what every header gets for free -----------------------------------------

@testset "equality, hash and show come from the struct" begin
    a = EthernetMacHeader("0a:00:00:00:00:02", "0a:00:00:00:00:01", ETHERTYPE_IPV4)
    b = EthernetMacHeader("0a:00:00:00:00:02", "0a:00:00:00:00:01", ETHERTYPE_IPV4)
    @test a == b
    @test hash(a) == hash(b)
    @test a != EthernetMacHeader(MAC_BROADCAST, a.source, a.type_or_length)
    @test occursin("EthernetMacHeader(destination=", string(a))
    @test quality(a) == Q_COMPLETE
end

@testset "set_field returns a new header" begin
    ip = Ipv4Header(total_length = 48, protocol = IP_PROTOCOL_UDP,
                    source = "10.0.0.1", destination = "10.0.0.2")
    forwarded = set_field(ip, :time_to_live, ip.time_to_live - 1)
    @test forwarded.time_to_live == 63
    @test ip.time_to_live == 64            # the original is untouched
    @test forwarded.source == ip.source
    @test_throws ErrorException set_field(ip, :nonesuch, 1)
end

# --- byte order --------------------------------------------------------------

@testset "byte order belongs to the header, not to a field" begin
    @test byte_order(EthernetMacHeader) === :be
    @test byte_order(Ipv4Header) === :be

    # The writer and the reader still take it per call, which is what a
    # little-endian protocol will use.
    writer = BitWriter()
    write_bits!(writer, UInt16(0x1234), 16, :le)
    @test writer.bytes == UInt8[0x34, 0x12]
    @test read_bits!(BitReader(writer.bytes), 16, :le) == 0x1234
    # The byte is the unit the order applies to, so a 12-bit field has none.
    @test_throws ErrorException write_bits!(BitWriter(), UInt16(1), 12, :le)
end
