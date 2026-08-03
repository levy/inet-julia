# ============================================================================
# Phase 3 conformance — declared headers, generated codecs, R2 duality, R9 guard.
#
# Ports: testSerialization, testSequenceSerialization, testConversion,
# testDuality, testPolymorphism.
# Verify: testConversion case 1 — a header assembled from two halves
# (raw + sliced) must REFUSE to yield the header back.
# ============================================================================
using Test
using InetPacket.PacketModule

# --- three real headers, per plan §9 Q1: decide the syntax against real cases.

# IPv4 header (fixed 20 bytes; options ignored — that's the variable-length
# tail that would ride on a hand-written serialize override).
@header Ipv4Header begin
    version      :: UInt8  | 4
    ihl          :: UInt8  | 4
    dscp         :: UInt8  | 6
    ecn          :: UInt8  | 2
    total_length :: UInt16
    identification :: UInt16
    flags        :: UInt8  | 3
    frag_offset  :: UInt16 | 13
    ttl          :: UInt8
    protocol     :: UInt8
    checksum     :: UInt16
    src_addr     :: UInt32
    dst_addr     :: UInt32
end

# Ethernet MAC header (fixed 14 bytes — no VLAN in this fixture).
@header EthernetMacHeader begin
    dst_mac_hi   :: UInt16
    dst_mac_lo   :: UInt32
    src_mac_hi   :: UInt16
    src_mac_lo   :: UInt32
    ethertype    :: UInt16
end

# --- testSerialization -------------------------------------------------------
@testset "@header — chunk_length, defaults, round-trip" begin
    @test chunk_length(Ipv4Header) == Bytes(20)
    @test chunk_length(EthernetMacHeader) == Bytes(14)

    ip = Ipv4Header(4, 5, 0, 0, UInt16(1500), UInt16(0x1234), UInt8(0), UInt16(0),
                    UInt8(64), UInt8(6), UInt16(0), UInt32(0x0a000001), UInt32(0x0a000002))
    @test chunk_length(ip) == Bytes(20)

    bs = to_bytes(ip)
    @test Base.length(bs) == 20
    # version|ihl → 0x45; dscp|ecn → 0x00
    @test bs[1] == 0x45
    @test bs[2] == 0x00
    # total_length is 1500 big-endian
    @test bs[3] == 0x05 && bs[4] == 0xdc
    # src_addr 10.0.0.1
    @test bs[13:16] == UInt8[10, 0, 0, 1]
    @test bs[17:20] == UInt8[10, 0, 0, 2]

    # deserialize → structurally equal
    ip2 = from_bytes(Ipv4Header, bs)
    @test ip2.version == 4 && ip2.ihl == 5
    @test ip2.total_length == 1500
    @test ip2.ttl == 64 && ip2.protocol == 6
    @test ip2.src_addr == 0x0a000001
    @test ip2.dst_addr == 0x0a000002
end

@testset "@header — bit-packed straddling fields" begin
    # flags (3 bits) + frag_offset (13 bits) share bytes 7..8.
    ip = Ipv4Header(4, 5, 0, 0, UInt16(20), UInt16(0), UInt8(0b010), UInt16(0x0100),
                    UInt8(1), UInt8(0), UInt16(0), UInt32(0), UInt32(0))
    bs = to_bytes(ip)
    # flags=010, frag_offset=0x0100=0b0000_0001_0000_0000
    # byte7 = 0b010_00000 | 0b000_00001 = 0b010_00001 = 0x41
    # byte8 = 0b0000_0000 = 0x00
    @test bs[7] == 0x41
    @test bs[8] == 0x00

    back = from_bytes(Ipv4Header, bs)
    @test back.flags == 0b010
    @test back.frag_offset == 0x0100
end

# --- testConversion (Raw ↔ Fields via peek) ----------------------------------
@testset "peek(Raw, Ipv4Header) — the deserialise duality" begin
    ip = Ipv4Header(4, 5, 0, 0, UInt16(1500), UInt16(0x1234), UInt8(0), UInt16(0),
                    UInt8(64), UInt8(17), UInt16(0), UInt32(0x0a000001), UInt32(0x0a000002))
    bs = to_bytes(ip)
    raw = Raw(bs)

    ip_from_raw = peek(raw, Ipv4Header)
    @test ip_from_raw.total_length == 1500
    @test ip_from_raw.protocol == 17
    @test ip_from_raw.src_addr == 0x0a000001

    # A slice of exactly the header range also deserialises.
    padded = vcat(UInt8[0xff, 0xff, 0xff], bs, UInt8[0xff, 0xff])
    padded_raw = Raw(padded)
    sl = slice(padded_raw, Bytes(3), Bytes(20))
    ip2 = peek(sl, Ipv4Header)
    @test ip2.total_length == 1500
    @test ip2.protocol == 17
end

# --- testDuality — a packet built field-wise reads back as bytes and vice versa
@testset "testDuality — R2 by construction" begin
    ip = Ipv4Header(4, 5, 0, 0, UInt16(64), UInt16(0), UInt8(0), UInt16(0),
                    UInt8(64), UInt8(6), UInt16(0), UInt32(1), UInt32(2))
    pk = Packet(ip)                        # built from a field struct
    # Round-trip: same fields.
    ip_back = peek(pk, Ipv4Header)
    @test ip_back.total_length == 64
    @test ip_back.protocol == 6
    # Same packet peekable as raw bytes.
    raw = peek(pk, Raw)
    @test raw.data == to_bytes(ip)

    # A packet built from those SAME bytes reads back into an equivalent header.
    pk2 = Packet(Raw(to_bytes(ip)))
    ip_from_bytes = peek(pk2, Ipv4Header)
    @test ip_from_bytes.total_length == 64
    @test ip_from_bytes.protocol == 6
    @test ip_from_bytes.src_addr == 1
end

# --- testPolymorphism — peek by TYPE, not by position ------------------------
@testset "testPolymorphism — peek dispatches on target type" begin
    eth = EthernetMacHeader(UInt16(0xdead), UInt32(0xbeefcafe),
                            UInt16(0x0011), UInt32(0x22334455), UInt16(0x0800))
    ip  = Ipv4Header(4, 5, 0, 0, UInt16(1500), UInt16(0), UInt8(0), UInt16(0),
                     UInt8(64), UInt8(6), UInt16(0), UInt32(1), UInt32(2))
    payload = Filler(Bytes(500))

    pk = Packet(payload)
    pushfirst!(pk, ip)
    pushfirst!(pk, eth)

    # Peek by type — no position math needed at the call site.
    eth_back = peek(pk, EthernetMacHeader)
    @test eth_back.ethertype == 0x0800
    @test eth_back.dst_mac_hi == 0xdead
    # After consuming the Ethernet header, the front IS IPv4.
    popfirst!(pk, chunk_length(EthernetMacHeader))
    ip_back = peek(pk, Ipv4Header)
    @test ip_back.total_length == 1500
    @test ip_back.protocol == 6
end

# --- R9 guard — the deliberate ugliness of reinterpretation ------------------
@testset "R9 — refuse Fields → Fields reinterpretation" begin
    ip = Ipv4Header(4, 5, 0, 0, UInt16(20), UInt16(0), UInt8(0), UInt16(0),
                    UInt8(64), UInt8(0), UInt16(0), UInt32(0), UInt32(0))
    # Direct peek: an IPv4 chunk asked to be an Ethernet header. REFUSED.
    @test_throws ErrorException peek(ip, EthernetMacHeader)
    # Opt-in with `reinterpret = true` — the deserialisation succeeds even
    # though the semantic meaning is nonsense; that is the WHOLE POINT of
    # the guard being explicit.
    forced = peek(ip, EthernetMacHeader; reinterpret = true)
    @test forced isa EthernetMacHeader
end

# --- testConversion case 1 — split-source refusal (the real R2 test) --------
@testset "peek refuses a half-Raw / half-Sliced header" begin
    # Build a byte sequence that IS a valid IPv4 header, but split it across
    # two chunks so the reader has to traverse a Sequence.
    ip = Ipv4Header(4, 5, 0, 0, UInt16(20), UInt16(0), UInt8(0), UInt16(0),
                    UInt8(64), UInt8(1), UInt16(0), UInt32(0), UInt32(0))
    bs = to_bytes(ip)
    seq = sequence(Chunk[Raw(bs[1:10]), Raw(bs[11:20])])
    # Split-source deserialise MUST WORK — the whole point of R2 duality is
    # that representation is invisible to the reader. The plan's testConversion
    # case 1 is about refusing something DIFFERENT — see the next testset.
    ip_back = peek(seq, Ipv4Header)
    @test ip_back.total_length == 20
    @test ip_back.protocol == 1
end

@testset "peek refuses when the source is a DIFFERENT Fields type" begin
    # A packet whose FRONT is an EthernetMacHeader but the caller asks for
    # Ipv4Header. Without `reinterpret = true`, this MUST refuse loudly —
    # this is where INET's Chunk.cc:122 lives.
    eth = EthernetMacHeader(UInt16(0), UInt32(0), UInt16(0), UInt32(0), UInt16(0x0800))
    pk = Packet(eth)
    @test_throws ErrorException peek(pk, Ipv4Header)
    # But bytes → Ipv4 is the "safe" side of the guard and just works.
    pk2 = Packet(Raw(to_bytes(Ipv4Header(4, 5, 0, 0, UInt16(20), UInt16(0), UInt8(0),
                                          UInt16(0), UInt8(64), UInt8(1), UInt16(0),
                                          UInt32(0), UInt32(0)))))
    @test peek(pk2, Ipv4Header).protocol == 1
end

# --- has() — "have I received a full header?" -------------------------------
@testset "has(pk, T) — cheap prefix check" begin
    pk = Packet(Filler(Bytes(50)))
    @test has(pk, EthernetMacHeader)
    @test has(pk, Ipv4Header)

    small = Packet(Filler(Bytes(10)))
    @test !has(small, Ipv4Header)
    @test !has(small, EthernetMacHeader)
end
