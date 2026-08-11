# ============================================================================
# Phase 17 — the round-trip corpus.
#
# The C++ branch's central finding: a `FieldsChunk` built by deserialization
# cached the original wire bytes, and the serializer replayed the cache instead
# of re-encoding from the parsed fields. Every asymmetry between the reader and
# the writer was invisible. With the cache cleared, its pcap corpus went from
# 1219 differing frames to 30.
#
# This library keeps no such cache and does not want one. What it has instead
# is this test: build a header whose every field is distinct, then check that
# encode → decode → encode gives the same bytes and the same length.
# ============================================================================
using Test
using InetPacket.PacketModule

# The corpus is the library's own wire formats. A probe header declared in a
# test file is registered too — `@header` registers every header — but its
# clauses want values a generic fill cannot invent, so it is not a round-trip
# subject. The module it was declared in is the honest way to tell them apart.
corpus() = filter(H -> parentmodule(H) === PacketModule, list_headers())

@testset "every wire format survives encode, decode and encode" begin
    @test !isempty(corpus())
    for H in corpus()
        @test check_round_trip(H)
    end
end

@testset "the corpus covers every wire format the library declares" begin
    # A format added to `protocol/` and forgotten is the thing this catches.
    declared = Set(corpus())
    for H in (EthernetPhyHeader, EthernetMacHeader, Ieee8021qTag, EthernetFcs,
              Ipv4Header, Ipv6Header, UdpHeader, TcpHeader)
        @test H in declared
    end
end

@testset "fill_asymmetric makes every field distinct" begin
    # Two fields of the same type must not hold the same value, or a swap
    # between them would pass.
    ip = fill_asymmetric(Ipv4Header)
    @test ip.source != ip.destination
    @test ip.dscp != ip.ecn

    mac = fill_asymmetric(EthernetMacHeader)
    @test mac.destination != mac.source

    tcp = fill_asymmetric(TcpHeader)
    @test tcp.source_port != tcp.destination_port
    @test tcp.sequence_number != tcp.acknowledgment_number
end

@testset "fill_asymmetric leaves a checked field at its declared value" begin
    # A header that fails its own check tests the check, not the round trip.
    @test fill_asymmetric(Ipv4Header).version == 4
    @test fill_asymmetric(Ipv6Header).version == 6
    @test list_checked(Ipv4Header) == (:version, :header)
end

@testset "the corpus catches a reader that disagrees with its writer" begin
    # Two headers of the same width and a different field order encode the same
    # values to different bytes, which is what the round trip is sensitive to.
    ip = fill_asymmetric(Ipv4Header)
    bytes = encode_header(ip)
    @test encode_header(decode_header(Ipv4Header, bytes)) == bytes

    # And a byte flipped anywhere changes what comes back.
    for index in eachindex(bytes)
        index in (1,) && continue                  # the version is checked
        flipped = copy(bytes)
        flipped[index] ⊻= 0xff
        @test encode_header(decode_header(Ipv4Header, flipped)) == flipped
    end
end
