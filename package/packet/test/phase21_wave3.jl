# ============================================================================
# Phase 21 — Wave 3: the link layer and the physical layer.
#
# The formats INET invented, the IEEE 802.1D bridge messages, 802.15.4, the
# wireless MAC protocols, gPTP and MRP.
# ============================================================================
using Test
using InetPacket.PacketModule

hex21(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

@testset "a header that states its own length, and fills the rest" begin
    # Five of INET's own headers share this shape, and it is the one thing the
    # language could not say until now. `until` says it: the filler runs to the
    # offset the length field names.
    header = AckingMacHeader(source = MacAddress("0a:00:00:00:00:01"),
                             destination = MacAddress("0a:00:00:00:00:02"),
                             network_protocol = 0x0800,
                             filler = build_filler(Bytes(40),
                                                   Bytes(ACKING_MAC_HEADER_BYTES)))
    @test chunk_length(header) == Bytes(40)
    bytes = encode_header(header)
    # 0x28 is forty: the length field counts octets in this one header.
    @test bytes[1] == 0x28
    # The source comes first, which is the opposite of IEEE 802.3.
    @test hex21(bytes[2:7]) == "0a 00 00 00 00 01"
    @test hex21(bytes[8:13]) == "0a 00 00 00 00 02"
    @test all(byte == SIMULATION_FILLER for byte in bytes[24:40])

    back = decode_header(AckingMacHeader, bytes)
    @test back.header_length == 40
    @test Base.length(back.filler.data) == 17
    @test back.destination == MacAddress("0a:00:00:00:00:02")
    @test encode_header(back) == bytes

    # The other four count bits, not octets.
    generic = GenericPhyHeader(payload_protocol = 0x0001,
                               filler = build_filler(Bytes(8), Bytes(4)))
    @test hex21(encode_header(generic)) == "00 40 00 01 3f 3f 3f 3f"
    @test decode_header(GenericPhyHeader, encode_header(generic)).header_length == 64

    for T in (ShortcutMacHeader, GenericPhyHeader, ShortcutPhyHeader)
        @test minimum_chunk_length(T) == Bytes(4)
    end
    @test minimum_chunk_length(ApskPhyHeader) == Bytes(8)

    # A filler that does not fit says so, rather than writing a short header.
    @test_throws ErrorException build_filler(Bytes(4), Bytes(23))
end
