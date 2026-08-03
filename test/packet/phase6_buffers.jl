# ============================================================================
# Phase 6 conformance — ChunkQueue + ChunkBuffer with overlap policy.
#
# Ports: testChunkQueue, testChunkBuffer, testReassemblyBuffer,
# testReorderBuffer, testFragmentation, testAggregation.
# Verify: a conflicting overlap under each policy — INET has no test
# because it has no policy (defect 3).
#
# Streaming (R13) and full reassembly/reorder helpers deferred to a
# follow-up; the primitives here are enough to build both.
# ============================================================================
using Test
using Inet.PacketModule

# --- testChunkQueue ---------------------------------------------------------
@testset "ChunkQueue — FIFO, straddling pop, merge on push" begin
    q = ChunkQueue()
    @test isempty(q)
    push!(q, Raw(UInt8[1,2,3,4]))
    push!(q, Filler(Bytes(4); fill = 0x00))
    push!(q, Raw(UInt8[9,10,11,12]))
    @test total_length(q) == Bytes(12)

    # Non-straddling pop.
    got = popfirst!(q, Bytes(4))
    @test peek(got, Raw).data == UInt8[1,2,3,4]
    @test total_length(q) == Bytes(8)

    # Straddling pop across (Filler, Raw) boundary.
    got2 = popfirst!(q, Bytes(6))
    @test chunk_length(got2) == Bytes(6)
    # First 4 bytes are zero (from Filler), last 2 are 9,10.
    got2_raw = peek(got2, Raw)
    @test got2_raw.data == UInt8[0,0,0,0,9,10]
    @test total_length(q) == Bytes(2)

    # Peekfirst is non-destructive.
    p = peekfirst(q, Bytes(2))
    @test peek(p, Raw).data == UInt8[11, 12]
    @test total_length(q) == Bytes(2)
end

@testset "ChunkQueue — two adjacent byte-Raws MERGE on push" begin
    q = ChunkQueue()
    push!(q, Raw(UInt8[1,2]))
    push!(q, Raw(UInt8[3,4,5]))
    @test Base.length(q.chunks) == 1              # merged
    @test q.chunks[1] isa Raw
    @test q.chunks[1].data == UInt8[1,2,3,4,5]
end

# --- testChunkBuffer + testFragmentation ------------------------------------
@testset "ChunkBuffer — sparse writes, gap enumeration" begin
    b = ChunkBuffer()
    @test isempty(b)
    write!(b, Bytes(10), Raw(UInt8[1,2,3,4]))
    write!(b, Bytes(20), Raw(UInt8[5,6,7,8]))
    @test Base.length(b) == 2

    # A gap at [14, 19] bytes = [112, 159] bits.
    g = gaps(b, Int64(0):Int64(239))
    @test Base.length(g) == 3
    @test g[1] == Int64(0):Int64(79)              # gap before first region
    @test g[2] == Int64(112):Int64(159)           # the middle gap
    @test g[3] == Int64(192):Int64(239)           # gap after last region

    # region_at inside a filled region
    r = region_at(b, Bytes(10))
    @test r !== nothing
    @test r[1] == Int64(80):Int64(111)

    # region_at inside a gap
    @test region_at(b, Bytes(15)) === nothing

    # Fill the gap.
    write!(b, Bytes(14), Raw(UInt8[0xa, 0xb, 0xc, 0xd, 0xe, 0xf]))
    # Now [80, 191] is complete (contiguous merge).
    @test is_complete_range(b, Int64(80):Int64(191))
    @test !is_complete_range(b, Int64(0):Int64(191))
    # Assembly picks up the merged region.
    got = assembled_chunk(b, Int64(80):Int64(191))
    @test chunk_length(got) == Bytes(14)
    raw = peek(got, Raw)
    @test raw.data == UInt8[1,2,3,4,0xa,0xb,0xc,0xd,0xe,0xf,5,6,7,8]
end

# --- Overlap policy — INET has NO test for this (defect 3) ------------------
@testset "ChunkBuffer — REFUSE policy" begin
    b = ChunkBuffer()
    write!(b, Bytes(0), Raw(UInt8[1,2,3,4]))
    @test_throws ErrorException write!(b, Bytes(2), Raw(UInt8[0xff, 0xff, 0xff]))
end

@testset "ChunkBuffer — KEEP_EXISTING (correct for TCP retransmit)" begin
    b = ChunkBuffer()
    write!(b, Bytes(0), Raw(UInt8[1, 2, 3, 4]))
    write!(b, Bytes(2), Raw(UInt8[0xff, 0xff, 0xff, 0xff]); overlap = KEEP_EXISTING)
    # Bytes 2..3 stay 3,4; bytes 4..5 are new 0xff, 0xff.
    got = assembled_chunk(b, Int64(0):Int64(47))
    @test peek(got, Raw).data == UInt8[1, 2, 3, 4, 0xff, 0xff]
end

@testset "ChunkBuffer — OVERWRITE" begin
    b = ChunkBuffer()
    write!(b, Bytes(0), Raw(UInt8[1, 2, 3, 4]))
    write!(b, Bytes(2), Raw(UInt8[0xff, 0xff, 0xff, 0xff]); overlap = OVERWRITE)
    got = assembled_chunk(b, Int64(0):Int64(47))
    @test peek(got, Raw).data == UInt8[1, 2, 0xff, 0xff, 0xff, 0xff]
end

# --- testReassemblyBuffer — out-of-order pieces assemble on completion ------
@testset "reassembly — feed out-of-order, ask for the whole window" begin
    b = ChunkBuffer()
    # Fragments arrive out of order: [0..2] then [8..11] then the middle.
    write!(b, Bytes(0),  Raw(UInt8[1, 2, 3]))
    write!(b, Bytes(8),  Raw(UInt8[9, 10, 11, 12]))
    @test !is_complete_range(b, Int64(0):Int64(95))
    @test gaps(b, Int64(0):Int64(95)) == [Int64(24):Int64(63)]
    write!(b, Bytes(3),  Raw(UInt8[4, 5, 6, 7, 8]))
    @test is_complete_range(b, Int64(0):Int64(95))
    all = assembled_chunk(b, Int64(0):Int64(95))
    @test peek(all, Raw).data == UInt8[1,2,3,4,5,6,7,8,9,10,11,12]
end

# --- testAggregation — pack multiple pieces into one queue --------------------
@testset "aggregation — enqueue payloads, dequeue as one merged run" begin
    q = ChunkQueue()
    for i in 1:5
        push!(q, Raw(UInt8[i, i, i]))
    end
    @test total_length(q) == Bytes(15)
    # All 5 payloads merged into one Raw (byte-aligned).
    @test Base.length(q.chunks) == 1
    got = popfirst!(q, Bytes(15))
    @test peek(got, Raw).data == UInt8[1,1,1, 2,2,2, 3,3,3, 4,4,4, 5,5,5]
end
