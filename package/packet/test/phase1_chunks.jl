# ============================================================================
# Phase 1 conformance tests — lengths and representations.
#
# Names mirror INET's `tests/packet/UnitTest.cc` where the mapping is direct:
#   testEmpty, testSequence, testSlicing, testMerging, testPeeking,
#   testNesting, testIteration.
# ============================================================================
using Test
using InetPacket.PacketModule
import Random

# --- lengths ------------------------------------------------------------------
@testset "BitLength" begin
    @test bits(Bits(5))    == 5
    @test bits(Bytes(3))   == 24
    @test bytes(Bytes(3))  == 3
    @test isbyte(Bytes(3))
    @test !isbyte(Bits(3))
    @test Bits(3) + Bits(5)          == Bits(8)
    @test Bytes(2) - Bytes(1)        == Bytes(1)
    @test Bits(2) * 4                == Bytes(1)
    @test Bits(3) < Bits(5)
    @test Bits(5) == Bytes(0) + Bits(5)
    @test zero(BitLength)            == Bits(0)
    @test iszero(ZERO_LENGTH)
    @test min(Bits(2), Bits(9))      == Bits(2)
    @test max(Bytes(1), Bits(5))     == Bytes(1)
    # a bare Int is not a BitLength — the confusion INET's `b`/`B` types
    # prevent is caught here at the construction site.
    @test !(5 isa BitLength)
end

# --- testEmpty ---------------------------------------------------------------
@testset "empty" begin
    e = Filler(ZERO_LENGTH)
    @test isempty(e)                              # fixes INET defect 5
    @test chunk_length(e) == Bits(0)
    @test quality(e) == Q_COMPLETE

    # A sequence with only empty parts collapses to a zero-Filler.
    s = sequence(Chunk[Filler(ZERO_LENGTH), Filler(ZERO_LENGTH)])
    @test s isa Filler
    @test isempty(s)
end

# --- testSequence ------------------------------------------------------------
@testset "sequence — smart-constructor normalisation" begin
    a = Filler(Bytes(4); fill = 0x00)
    b = Raw(UInt8[1,2,3,4])
    c = Filler(Bytes(2); fill = 0xff)

    s = sequence(Chunk[a, b, c])
    @test s isa Sequence
    @test chunk_length(s) == Bytes(10)
    # cumulative offsets by construction (fixes defect 1: O(1) length)
    @test s.offsets == Int64[0, 32, 64, 80]

    # singleton collapses to the leaf
    @test sequence(Chunk[a]) === a

    # nested Sequences flatten — no sequence-in-sequence
    inner = sequence(Chunk[b, c])
    outer = sequence(Chunk[a, inner])
    @test outer isa Sequence
    @test all(!(x isa Sequence) for x in outer.chunks)
    @test chunk_length(outer) == chunk_length(s)
    @test outer.offsets == s.offsets

    # empty parts drop
    with_empty = sequence(Chunk[a, Filler(ZERO_LENGTH), b])
    @test length(with_empty.chunks) == 2
end

# --- testMerging -------------------------------------------------------------
@testset "merging — adjacency rules" begin
    # Same fill → merge
    m1 = sequence(Chunk[Filler(Bytes(2); fill = 0xaa), Filler(Bytes(3); fill = 0xaa)])
    @test m1 isa Filler
    @test chunk_length(m1) == Bytes(5)

    # Different fill → NO merge (fixes defect 7)
    m2 = sequence(Chunk[Filler(Bytes(2); fill = 0xaa), Filler(Bytes(3); fill = 0xbb)])
    @test m2 isa Sequence
    @test Base.length(m2.chunks) == 2

    # Two byte-aligned Raws → merge
    r = sequence(Chunk[Raw(UInt8[1,2]), Raw(UInt8[3,4,5])])
    @test r isa Raw
    @test r.data == UInt8[1,2,3,4,5]

    # Different-type leaves → NO merge
    x = sequence(Chunk[Filler(Bytes(2)), Raw(UInt8[9,9])])
    @test x isa Sequence
end

# --- testSlicing -------------------------------------------------------------
@testset "slicing — no-op collapse, slice-of-slice flatten" begin
    r = Raw(UInt8[10, 20, 30, 40, 50])       # 40 bits

    # full-cover slice → the leaf itself (no wrapper)
    @test slice(r, ZERO_LENGTH, Bytes(5)) === r

    # partial slice → a Slice
    s = slice(r, Bytes(1), Bytes(3))
    @test s isa Slice
    @test chunk_length(s) == Bytes(3)

    # slice-of-slice → single Slice with combined offset (no nesting)
    s2 = slice(s, Bytes(1), Bytes(1))
    @test s2 isa Slice
    @test !(s2.chunk isa Slice)             # flattened
    @test s2.chunk === r
    @test s2.offset == Bytes(2)
    @test s2.length == Bytes(1)

    # out-of-bounds refuses loudly, not silently
    @test_throws ErrorException slice(r, Bytes(4), Bytes(2))
    @test_throws ErrorException slice(r, Bits(-1), Bytes(1))
end

@testset "slicing a Sequence descends to leaves" begin
    parts = Chunk[Raw(UInt8[1,2,3,4]), Filler(Bytes(4); fill = 0xff), Raw(UInt8[5,6,7,8])]
    s = sequence(parts)
    @test chunk_length(s) == Bytes(12)

    # window across the Filler / Raw boundary
    w = slice(s, Bytes(3), Bytes(6))
    @test chunk_length(w) == Bytes(6)
    # descent: no slice-of-sequence, no sequence-in-sequence
    if w isa Sequence
        for child in w.chunks
            @test !(child isa Sequence)
        end
    end
end

# --- testPeeking -------------------------------------------------------------
@testset "peek — untyped and Slice target" begin
    r = Raw(UInt8[1,2,3,4,5,6])
    # untyped full peek == the leaf
    @test peek(r) === r
    # kwarg range → a Slice
    w = peek(r; at = Bytes(1), length = Bytes(3))
    @test w isa Slice
    @test chunk_length(w) == Bytes(3)
    @test w.offset == Bytes(1)

    # peek(_, Filler) is length-only (lossy by design, R1)
    f = peek(r, Filler; at = ZERO_LENGTH, length = Bytes(4))
    @test f isa Filler
    @test chunk_length(f) == Bytes(4)
end

@testset "peek — Raw conversion round-trips real bytes" begin
    # Raw source → byte copy
    r = Raw(UInt8[1,2,3,4,5,6,7,8])
    got = peek(r, Raw; at = Bytes(2), length = Bytes(3))
    @test got.data == UInt8[3,4,5]
    @test chunk_length(got) == Bytes(3)

    # Filler source → materialise
    f = Filler(Bytes(4); fill = 0xab)
    m = peek(f, Raw)
    @test m.data == fill(0xab, 4)

    # Sequence source → concatenate byte-aligned children
    s = sequence(Chunk[Raw(UInt8[1,2]), Filler(Bytes(2); fill = 0x00), Raw(UInt8[9,10])])
    all = peek(s, Raw)
    @test all.data == UInt8[1,2,0,0,9,10]

    # Slice source → descend
    sl = slice(s, Bytes(1), Bytes(4))
    @test peek(sl, Raw).data == UInt8[2,0,0,9]
end

# --- testNesting -------------------------------------------------------------
@testset "nesting — the tree is always flat after normalisation" begin
    # A caller can't build a Sequence-in-Sequence via the smart ctor.
    a = Raw(UInt8[1,2]); b = Raw(UInt8[3,4]); c = Filler(Bytes(2))
    ab = sequence(Chunk[a, b])                 # merges into one Raw
    @test ab isa Raw
    outer = sequence(Chunk[ab, c])
    @test outer isa Sequence
    @test all(x -> !(x isa Sequence), outer.chunks)

    # A caller can't build a Slice-of-Slice via `slice()`.
    r = Raw(UInt8[1,2,3,4,5,6])
    s1 = slice(r, Bytes(1), Bytes(4))
    s2 = slice(s1, Bytes(1), Bytes(2))
    @test s2 isa Slice
    @test !(s2.chunk isa Slice)
end

# --- testIteration -----------------------------------------------------------
@testset "iteration walks children" begin
    a = Raw(UInt8[1,2]); b = Filler(Bytes(2); fill=0xff); c = Raw(UInt8[3,4])
    s = sequence(Chunk[a, b, c])
    @test s isa Sequence

    kids = collect(s)
    @test Base.length(kids) == 3

    # A leaf iterates as itself (one element).
    @test collect(a) == [a]
    @test collect(b) == [b]

    # Total length equals sum of child lengths.
    @test sum(chunk_length(x).bits for x in s) == chunk_length(s).bits
end

# --- randomised invariant check — the plan's phase-1 "verify" ---------------
@testset "invariants hold under randomised insert/slice sequences" begin
    rng = Random.MersenneTwister(0x1234)
    for trial in 1:200
        n = rand(rng, 1:5)
        parts = Chunk[]
        for _ in 1:n
            k = rand(rng, 1:8)
            if rand(rng, Bool)
                push!(parts, Raw(rand(rng, UInt8, k)))
            else
                push!(parts, Filler(Bytes(k); fill = rand(rng, UInt8)))
            end
        end
        s = sequence(parts)
        # Invariant: never a Sequence-of-Sequence.
        if s isa Sequence
            for child in s.chunks
                @test !(child isa Sequence)
            end
            # Cumulative offsets consistent.
            @test s.offsets[1] == 0
            @test s.offsets[end] == chunk_length(s).bits
            for i in 1:Base.length(s.chunks)
                @test s.offsets[i+1] - s.offsets[i] == chunk_length(s.chunks[i]).bits
            end
        end
        # Random slice never nests.
        if chunk_length(s).bits > 0
            off = rand(rng, 0:chunk_length(s).bits - 1)
            ln  = rand(rng, 0:chunk_length(s).bits - off)
            w = slice(s, Bits(off), Bits(ln))
            if w isa Slice
                @test !(w.chunk isa Slice)
            end
            @test chunk_length(w) == Bits(ln)
        end
    end
end
