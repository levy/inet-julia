# ============================================================================
# Phase 7 conformance — inspection.
#
# No INET test to port (plan says the acceptance case is inspecting a packet
# built by RoutingModel — Phase 8 territory). This suite verifies the
# building blocks: `dissect` returns a structured tree, `describe` renders
# it, and both cover the leaf-shape × composite matrix.
# ============================================================================
using Test
using Inet.PacketModule

@header InspHdr begin
    a :: UInt8
    b :: UInt16
end

@testset "dissect — leaves" begin
    d = dissect(Filler(Bytes(4)))
    @test Base.length(d) == 1
    @test d[1].kind == :filler
    @test d[1].length == Bytes(4)

    d = dissect(Raw(UInt8[0x01, 0x02, 0x03]))
    @test d[1].kind == :raw
    @test d[1].length == Bytes(3)
end

@testset "dissect — Sequence descends" begin
    s = sequence(Chunk[Raw(UInt8[1,2]), Filler(Bytes(2); fill=0xff), Raw(UInt8[9,10])])
    d = dissect(s)
    @test d[1].kind == :sequence
    @test Base.length(d[1].children) == 3
    @test d[1].children[2].kind == :filler
end

@testset "dissect — Fields emits per-field entries" begin
    h = InspHdr(UInt8(0x42), UInt16(0x1337))
    d = dissect(h)
    @test d[1].kind == :fields
    @test d[1].label == "InspHdr"
    @test Base.length(d[1].fields) == 2
    @test d[1].fields[1] == (:a => UInt8(0x42))
    @test d[1].fields[2] == (:b => UInt16(0x1337))
end

@testset "dissect — Packet wraps in an envelope entry with metadata" begin
    pk = Packet(Filler(Bytes(500)))
    pushfirst!(pk, InspHdr(UInt8(1), UInt16(2)))
    set_tag!(pk, "hello")
    d = dissect(pk)
    @test d[1].kind == :envelope
    @test occursin("ptags=1", d[1].label)
    # Inner tree includes the header + filler under a sequence.
    root = d[1].children[1]
    @test root.kind == :sequence
    @test root.children[1].kind == :fields
end

@testset "describe renders a stable text tree" begin
    pk = Packet(Filler(Bytes(100)))
    pushfirst!(pk, InspHdr(UInt8(9), UInt16(99)))
    text = describe(pk)
    @test occursin("InspHdr", text)
    @test occursin("a = 9", text)
    @test occursin("b = 99", text)
    @test occursin("Filler", text)
end
