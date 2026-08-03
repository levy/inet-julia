# ============================================================================
# Phase 2 conformance — the Packet envelope.
#
# Ports: testHeader, testTrailer, testEncapsulation, testFrontPopOffset,
# testBackPopOffset, testDuplication.
# Verify: `dup` shares content — assert object identity, not equality.
# ============================================================================
using Test
using Inet.PacketModule

@testset "envelope — empty packet" begin
    pk = Packet()
    @test isempty(pk)
    @test data_length(pk) == Bits(0)
    @test front_length(pk) == Bits(0)
    @test back_length(pk) == Bits(0)
end

@testset "envelope — from a payload chunk" begin
    payload = Filler(Bytes(1500); fill = 0x00)
    pk = Packet(payload)
    @test !isempty(pk)
    @test data_length(pk) == Bytes(1500)
    @test data_chunk(pk) === payload    # no wrapper when front/back are zero
    # The dominant simulation case: a 1500-byte payload nobody inspects.
    # `payload` is a 16-byte isbits struct — no per-hop allocation (§6.1).
end

# --- testHeader --------------------------------------------------------------
@testset "pushfirst! / popfirst! — header" begin
    payload = Filler(Bytes(1000); fill = 0x00)
    hdr = Raw(collect(UInt8, 1:20))

    pk = Packet(payload)
    pushfirst!(pk, hdr)
    @test data_length(pk) == Bytes(1020)

    # popfirst! consumes but retains — front advances, content is unchanged
    orig_content = pk.content
    popped = popfirst!(pk, Bytes(20))
    @test chunk_length(popped) == Bytes(20)
    @test front_length(pk) == Bytes(20)
    @test data_length(pk) == Bytes(1000)
    @test pk.content === orig_content   # RETAINED, not discarded (plan §2.2)
end

# --- testTrailer -------------------------------------------------------------
@testset "push! / pop! — trailer" begin
    payload = Filler(Bytes(64))
    trailer = Raw(UInt8[0xff, 0xee, 0xdd, 0xcc])   # 4-byte "FCS"

    pk = Packet(payload)
    push!(pk, trailer)
    @test data_length(pk) == Bytes(68)

    got = pop!(pk, Bytes(4))
    @test chunk_length(got) == Bytes(4)
    @test back_length(pk) == Bytes(4)
    @test data_length(pk) == Bytes(64)

    # peeking the retained trailer via from = :back returns the same bytes
    peek_back = peek(pk, Raw; length = Bytes(4), from = :back)
    # The trailer is in the retained region — data_length excludes it, so
    # peek with from = :back reads from the tail of the ACTIVE window.
    # (Back-region peeks need the reader API from Phase 3; here we assert
    # the window advanced correctly.)
    @test chunk_length(peek_back) == Bytes(4)
end

# --- testEncapsulation -------------------------------------------------------
@testset "encapsulation — layered push/pop preserves order" begin
    payload = Filler(Bytes(1000); fill = 0x00)
    ip_hdr  = Raw(collect(UInt8, 1:20))    # 20-byte "IP header"
    eth_hdr = Raw(collect(UInt8, 100:113)) # 14-byte "Ethernet header"
    fcs     = Raw(UInt8[0xaa, 0xbb, 0xcc, 0xdd])

    pk = Packet(payload)
    pushfirst!(pk, ip_hdr)
    pushfirst!(pk, eth_hdr)
    push!(pk, fcs)
    @test data_length(pk) == Bytes(14 + 20 + 1000 + 4)

    # decapsulate: eth → ip → payload → fcs
    got_eth = popfirst!(pk, Bytes(14))
    @test peek(got_eth, Raw).data == collect(UInt8, 100:113)
    got_ip  = popfirst!(pk, Bytes(20))
    @test peek(got_ip, Raw).data == collect(UInt8, 1:20)
    got_pl  = popfirst!(pk, Bytes(1000))
    @test chunk_length(got_pl) == Bytes(1000)
    got_fcs = popfirst!(pk, Bytes(4))
    @test peek(got_fcs, Raw).data == UInt8[0xaa, 0xbb, 0xcc, 0xdd]

    # Everything consumed → data window empty, but content retained.
    @test isempty(pk)
    @test front_length(pk) == Bytes(1038)
    @test content_length(pk) == Bytes(1038)
end

# --- testFrontPopOffset ------------------------------------------------------
@testset "front pop offset — retained region reachable" begin
    payload = Raw(collect(UInt8, 1:40))
    pk = Packet(payload)

    popfirst!(pk, Bytes(10))
    @test front_length(pk) == Bytes(10)
    @test data_length(pk) == Bytes(30)

    # The data window starts at byte 10 of the ORIGINAL payload.
    win = peek(pk, Raw; at = ZERO_LENGTH, length = Bytes(5))
    @test win.data == collect(UInt8, 11:15)

    # A follow-on popfirst! advances by another 10 bytes.
    popfirst!(pk, Bytes(10))
    @test front_length(pk) == Bytes(20)
    @test data_length(pk) == Bytes(20)
    win2 = peek(pk, Raw; at = ZERO_LENGTH, length = Bytes(3))
    @test win2.data == UInt8[21, 22, 23]
end

# --- testBackPopOffset -------------------------------------------------------
@testset "back pop offset — from = :back peeks from the tail" begin
    payload = Raw(collect(UInt8, 1:40))
    pk = Packet(payload)

    pop!(pk, Bytes(5))
    @test back_length(pk) == Bytes(5)
    @test data_length(pk) == Bytes(35)

    # Last 3 bytes of the active window: bytes 33..35 of the original payload
    # (the retained 5 = bytes 36..40).
    tail = peek(pk, Raw; length = Bytes(3), from = :back)
    @test tail.data == UInt8[33, 34, 35]

    # Head is untouched.
    head = peek(pk, Raw; length = Bytes(3), from = :front)
    @test head.data == UInt8[1, 2, 3]
end

# --- testDuplication ---------------------------------------------------------
@testset "dup — envelope duplicated, content SHARED (===)" begin
    payload = Filler(Bytes(1500))
    pk = Packet(payload)
    pushfirst!(pk, Raw(collect(UInt8, 1:20)))

    d = dup(pk)
    # Envelope is a fresh mutable — mutating the copy must not touch the original.
    @test d !== pk
    # Content is SHARED — object identity is load-bearing here (plan §4.1,
    # exactly what the parallel kernel relies on: per-thread envelopes,
    # frozen shared payload).
    @test d.content === pk.content
    @test d.front == pk.front && d.back == pk.back
    @test data_length(d) == data_length(pk)

    # Mutating the copy's envelope leaves the original alone (immutable content).
    pushfirst!(d, Raw(UInt8[99]))
    @test d.content !== pk.content              # d's content is a NEW node...
    @test data_length(d) == data_length(pk) + Bytes(1)
    @test data_length(pk) == Bytes(1520)        # ...pk is unchanged
end

# --- trim! ----------------------------------------------------------------
@testset "trim! drops the retained popped regions" begin
    payload = Raw(collect(UInt8, 1:40))
    pk = Packet(payload)
    popfirst!(pk, Bytes(10))
    pop!(pk, Bytes(5))
    @test front_length(pk) == Bytes(10)
    @test back_length(pk) == Bytes(5)
    @test content_length(pk) == Bytes(40)

    trim!(pk)
    @test front_length(pk) == Bytes(0)
    @test back_length(pk) == Bytes(0)
    @test content_length(pk) == Bytes(25)   # exactly the active window
    @test data_length(pk) == Bytes(25)
    # bytes preserved: 11..35
    @test peek(pk, Raw).data == collect(UInt8, 11:35)
end

# --- envelope-level peek untyped ---------------------------------------------
@testset "peek(pk) returns a Slice over the active window" begin
    payload = Raw(collect(UInt8, 1:20))
    pk = Packet(payload)
    popfirst!(pk, Bytes(4))
    pop!(pk, Bytes(3))
    got = peek(pk)
    @test chunk_length(got) == Bytes(13)
    @test peek(got, Raw).data == collect(UInt8, 5:17)
end
