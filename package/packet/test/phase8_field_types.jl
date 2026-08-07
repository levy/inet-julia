# ============================================================================
# Phase 8 — field types, and the layout descriptor `@header` emits beside the
# codec.
#
# What the phase must prove: a header field may be a `MacAddress`; a
# declaration may fix a display base and a default; and the description of the
# layout agrees with the codec that was generated from the same declaration.
# ============================================================================
using Test
using InetPacket.PacketModule

# --- the value types ---------------------------------------------------------

@testset "value types — parse, print, round-trip" begin
    m = MacAddress("0a:00:00:00:00:01")
    @test m.value == 0x0a0000000001
    @test string(m) == "0a:00:00:00:00:01"
    @test mac_octets(m) == (0x0a, 0x00, 0x00, 0x00, 0x00, 0x01)
    @test MacAddress(0x0a, 0x00, 0x00, 0x00, 0x00, 0x01) == m
    # The 48-bit mask holds: the top two octets of a UInt64 never reach a field.
    @test MacAddress(0xffff_ffff_ffff_ffff).value == 0x0000_ffff_ffff_ffff
    @test is_broadcast(MAC_BROADCAST)
    @test is_multicast(MacAddress("01:00:5e:00:00:01"))
    @test !is_multicast(m)

    a = Ipv4Address("10.0.0.1")
    @test a.value == 0x0a000001
    @test string(a) == "10.0.0.1"
    @test ipv4_octets(a) == (0x0a, 0x00, 0x00, 0x01)
    @test Ipv4Address(10, 0, 0, 1) == a

    @test string(EtherType(0x0800)) == "IPv4 (0x0800)"
    @test ethertype_name(EtherType(0x88b5)) === nothing
    @test string(EtherType(0x88b5)) == "0x88b5"

    @test string(IpProtocol(17)) == "UDP (17)"
    @test ip_protocol_name(IpProtocol(253)) === nothing
    @test string(IpProtocol(253)) == "253"

    @test string(PortNumber(1000)) == "1000"
end

@testset "the four generic functions" begin
    @test field_width(UInt16) == 16
    @test field_width(MacAddress) == 48
    @test field_width(Ipv4Address) == 32
    @test field_width(Bool) == 1

    @test field_encode(MacAddress, MacAddress("aa:bb:cc:dd:ee:ff")) == 0xaabbccddeeff
    @test field_decode(MacAddress, UInt64(0xaabbccddeeff)) == MacAddress("aa:bb:cc:dd:ee:ff")
    @test field_decode(Bool, UInt64(1))
    @test !field_decode(Bool, UInt64(0))

    # A field that is not a whole number of bytes reads as bits.
    @test field_base(UInt8, 4) === :bin
    @test field_base(UInt8, 8) === :dec
    @test field_base(UInt16, 13) === :bin
    @test field_base(MacAddress, 48) === :mac
    @test field_base(Ipv4Address, 32) === :ipv4
    @test field_base(EtherType, 16) === :enum
end

# --- a header that uses every new form ---------------------------------------

@header FieldFormsHeader begin
    version :: UInt8      | 4
    ihl     :: UInt8      | 4
    dst     :: MacAddress                 # width from the type
    kind    :: EtherType
    csum    :: UInt16     | 16 | hex      # a display override
    sfd     :: UInt8      | 8 = 0xD5      # a default
end

@testset "@header — field types, override, default" begin
    h = FieldFormsHeader(4, 5, MacAddress("0a:00:00:00:00:01"),
                         EtherType(0x0800), 0x1234, 0xD5)
    @test chunk_length(FieldFormsHeader) == Bytes(12)
    @test chunk_length(h) == Bytes(12)

    bs = to_bytes(h)
    @test bs == UInt8[0x45, 0x0a, 0x00, 0x00, 0x00, 0x00, 0x01,
                      0x08, 0x00, 0x12, 0x34, 0xd5]
    @test from_bytes(FieldFormsHeader, bs) == h

    # The keyword form fills the field that carries a default.
    k = FieldFormsHeader(version = 4, ihl = 5, dst = MacAddress("0a:00:00:00:00:01"),
                         kind = EtherType(0x0800), csum = 0x1234)
    @test k == h

    # An integer converts into a field type, so a call site stays readable.
    @test FieldFormsHeader(4, 5, 0x0a0000000001, 0x0800, 0x1234, 0xD5) == h
end

@testset "header_layout — the description agrees with the codec" begin
    layout = header_layout(FieldFormsHeader)
    @test layout === header_layout(FieldFormsHeader)     # a constant, not rebuilt
    @test layout.name === :FieldFormsHeader
    @test layout.length == chunk_length(FieldFormsHeader)
    @test [s.name for s in layout.fields] ==
          [:version, :ihl, :dst, :kind, :csum, :sfd]
    @test [s.width for s in layout.fields] == [4, 4, 48, 16, 16, 8]
    @test [s.offset for s in layout.fields] == [0, 4, 8, 56, 72, 88]
    @test [s.base for s in layout.fields] ==
          [:bin, :bin, :mac, :enum, :hex, :dec]

    # The two invariants every declared header must keep: the widths sum to the
    # length the codec writes, and the offsets run without a gap.
    for T in (FieldFormsHeader, )
        l = header_layout(T)
        @test sum(s.width for s in l.fields) == chunk_length(T).bits
        offset = 0
        for s in l.fields
            @test s.offset == offset
            offset += s.width
        end
    end
end

@testset "field_bits / field_text" begin
    h = FieldFormsHeader(4, 5, MacAddress("0a:00:00:00:00:01"),
                         EtherType(0x0800), 0x1234, 0xD5)
    layout = header_layout(FieldFormsHeader)
    spec(name) = layout.fields[findfirst(s -> s.name === name, layout.fields)]

    @test field_bits(h, spec(:version)) == 0x4
    @test field_bits(h, spec(:dst)) == 0x0a0000000001

    @test field_text(h, spec(:version)) == "0100"        # four bits, padded
    @test field_text(h, spec(:dst)) == "0a:00:00:00:00:01"
    @test field_text(h, spec(:kind)) == "IPv4 (0x0800)"
    @test field_text(h, spec(:csum)) == "0x1234"
    @test field_text(h, spec(:sfd)) == "213"

    # A forced base is how a view shortens a value that does not fit.
    @test field_text(field_bits(h, spec(:kind)), spec(:kind), :hex) == "0x0800"
    @test field_text(field_bits(h, spec(:csum)), spec(:csum), :dec) == "4660"
end

@testset "@header — a bad display base is a macro error" begin
    @test_throws LoadError @eval @header BadBaseHeader begin
        value :: UInt8 | 8 | octal
    end
end
