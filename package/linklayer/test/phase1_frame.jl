# ============================================================================
# Phase 1 conformance — Ethernet frame chunks + build_ethernet_frame.
# ============================================================================
using Test
using InetPacket.PacketModule
using InetLinkLayer.T1sModule

# The chunks are `InetPacket`'s, and its own suite checks their codecs. What
# this file checks is that a frame this model builds carries them correctly.

@testset "EthernetMacHeader / EthernetFcs — the chunks a frame carries" begin
    @test chunk_length(EthernetMacHeader) == Bytes(14)
    @test chunk_length(EthernetFcs) == Bytes(4)

    hdr = EthernetMacHeader(MacAddress(0x010203040506),
                            MacAddress(0x0A0B0C0D0E0F),
                            ETHERTYPE_IPV4)
    @test chunk_length(hdr) == Bytes(14)

    # Round-trip: to_bytes ↔ from_bytes preserves fields exactly.
    bs = encode_header(hdr)
    @test Base.length(bs) == 14
    @test bs[1:6]   == UInt8[0x01, 0x02, 0x03, 0x04, 0x05, 0x06]  # dst MAC
    @test bs[7:12]  == UInt8[0x0A, 0x0B, 0x0C, 0x0D, 0x0E, 0x0F]  # src MAC
    @test bs[13:14] == UInt8[0x08, 0x00]                           # ethertype big-endian

    back = decode_header(EthernetMacHeader, bs)
    @test back == hdr

    # FCS round-trip.
    fcs = EthernetFcs(0xDEADBEEF)
    @test encode_header(fcs) == UInt8[0xDE, 0xAD, 0xBE, 0xEF]
    @test decode_header(EthernetFcs, [0x11, 0x22, 0x33, 0x44]).fcs == 0x11223344
end

@testset "a model address is a UInt64, and converts both ways" begin
    # The MAC and PLCA machines compare addresses as integers; the header field
    # is a `MacAddress`. One conversion, no split into halves.
    m = MacAddress(0xAABBCCDDEEFF)
    @test m.value == 0xAABBCCDDEEFF
    @test MacAddress(m.value) == m
    @test MacAddress(0xFFFFFFFFFFFF) == MAC_BROADCAST
end

@testset "build_ethernet_frame — minimum-size padding" begin
    # Tiny payload: header (14) + payload (4) + FCS (4) = 22 → pad to 64.
    payload = Filler(Bytes(4); fill = 0xAA)
    pk = build_ethernet_frame(UInt64(0x010203040506), UInt64(0x0A0B0C0D0E0F),
                              ETHERTYPE_IPV4, payload)
    @test data_length(pk) == Bytes(64)                # padded to minimum

    # Structure: header at front, FCS at back.
    # build_ethernet_frame(src, dst, …), so dst is the SECOND arg.
    hdr = peek(pk, EthernetMacHeader)
    @test hdr.source == MacAddress(0x010203040506)
    @test hdr.destination == MacAddress(0x0A0B0C0D0E0F)
    @test hdr.type_or_length == ETHERTYPE_IPV4

    # FCS is placeholder (zero) in declared mode.
    fcs = peek(pk, EthernetFcs; from = :back)
    @test fcs.fcs == 0
end

@testset "build_ethernet_frame — payload at natural size (no padding)" begin
    # Header 14 + payload 46 + FCS 4 = 64 exactly. No padding needed.
    payload = Filler(Bytes(46); fill = 0x00)
    pk = build_ethernet_frame(UInt64(1), UInt64(2), ETHERTYPE_IPV4, payload)
    @test data_length(pk) == Bytes(64)

    payload_big = Filler(Bytes(1500))
    pk_big = build_ethernet_frame(UInt64(1), UInt64(2), ETHERTYPE_IPV4, payload_big)
    @test data_length(pk_big) == Bytes(14 + 1500 + 4)  # no padding above 46
end

@testset "constants match INET's Ethernet.h / EthernetPhyConstants.h" begin
    @test MIN_ETHERNET_FRAME_BYTES     == 64
    @test MAX_ETHERNET_FRAME_BYTES     == 1526
    @test INTERFRAME_GAP_BITS          == 96
    @test JAM_SIGNAL_BYTES             == 4
    @test ETHERNET_PHY_HEADER_LEN_BYTES == 8
    @test ETHERNET_PHY_ESD_LEN_BYTES    == 1
    @test ETHERNET_TXRATE_10MB          == 10_000_000
end
