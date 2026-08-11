# ============================================================================
# Phase 4 conformance — the quality lattice + strict-by-default peek gate.
#
# Ports: testComplete, testIncomplete, testCorrect, testIncorrect,
# testProperlyRepresented, testImproperlyRepresented, testCorruption.
# ============================================================================
using Test
using InetPacket.PacketModule

struct PhaseFourHeader <: Fields
    a :: U8
    b :: U16
end

# --- testComplete / testIncomplete ------------------------------------------
@testset "quality lattice — complete by default, incomplete via mark" begin
    r = Raw(UInt8[1, 2, 3, 4])
    @test quality(r) == Q_COMPLETE
    @test is_complete(quality(r))

    r_inc = mark_incomplete(r)
    @test is_incomplete(quality(r_inc))
    @test !is_complete(quality(r_inc))
    # Idempotent: marking again doesn't lose the flag.
    @test quality(mark_incomplete(r_inc)) == Q_INCOMPLETE
end

# --- testCorrect / testIncorrect --------------------------------------------
@testset "correctness lattice" begin
    r = Raw(UInt8[9, 8, 7])
    @test is_correct(quality(r))
    bad = mark_incorrect(r)
    @test is_incorrect(quality(bad))
    @test !is_correct(quality(bad))
    # Flags COMPOSE via the lattice.
    both = mark_incomplete(bad)
    @test is_incorrect(quality(both))
    @test is_incomplete(quality(both))
end

# --- testProperlyRepresented / testImproperlyRepresented --------------------
@testset "representation lattice" begin
    r = Raw(UInt8[0xff])
    @test is_properly_represented(quality(r))
    mis = mark_misrepresented(r)
    @test is_improperly_represented(quality(mis))
end

# --- join over composites (the reason the lattice buys anything) -------------
@testset "Sequence quality is the JOIN of its children" begin
    a = Raw(UInt8[1])
    b = mark_incorrect(Raw(UInt8[2]))
    c = mark_incomplete(Raw(UInt8[3]))
    s = sequence(Chunk[a, b, c])
    @test s isa Sequence
    @test is_incorrect(quality(s))
    @test is_incomplete(quality(s))
    @test is_properly_represented(quality(s))    # nobody added this bit
end

# --- testCorruption + the strict-by-default peek gate -----------------------
@testset "peek REFUSES an incorrect source unless opted in" begin
    hdr = PhaseFourHeader(UInt8(0x11), UInt16(0x2233))
    bs = encode_header(hdr)
    # Simulate a bit error: flip a byte.
    bs_bad = copy(bs); bs_bad[1] = xor(bs_bad[1], UInt8(0xff))
    raw_bad = mark_incorrect(Raw(bs_bad))

    # Strict by default — no PF_ALLOW_INCORRECT means throw.
    @test_throws ErrorException peek(raw_bad, PhaseFourHeader)
    # Opt-in: works, and the returned header reflects the CORRUPTED bytes.
    got = peek(raw_bad, PhaseFourHeader; incorrect = true)
    @test got.a == UInt8(0x11) ⊻ UInt8(0xff)
    @test got.b == 0x2233
end

@testset "peek REFUSES an incomplete source unless opted in" begin
    # A window narrower than the header wire length is incomplete by
    # construction — the "have I received a full header yet?" case.
    r = Raw(UInt8[0xaa, 0xbb])   # 2 bytes, but PhaseFourHeader wants 3
    pk = Packet(r)
    @test data_length(pk) < chunk_length(PhaseFourHeader)

    @test_throws ErrorException peek(pk, PhaseFourHeader; length = Bytes(2))
    # `has` is the cheap check that doesn't fire the gate.
    @test !has(pk, PhaseFourHeader)
end

@testset "peek REFUSES a misrepresented source unless opted in" begin
    hdr = PhaseFourHeader(UInt8(1), UInt16(2))
    bs = encode_header(hdr)
    raw = mark_misrepresented(Raw(bs))
    @test_throws ErrorException peek(raw, PhaseFourHeader)
    got = peek(raw, PhaseFourHeader; misrepresented = true)
    @test got.a == 1 && got.b == 2
end

# --- multi-flag composition: one gate covers each --------------------------
@testset "an ALL-BAD source requires ALL opt-ins" begin
    hdr = PhaseFourHeader(UInt8(9), UInt16(9))
    bs = encode_header(hdr)
    src = mark_misrepresented(mark_incorrect(mark_incomplete(Raw(bs))))
    q = quality(src)
    @test is_incomplete(q) && is_incorrect(q) && is_improperly_represented(q)

    @test_throws ErrorException peek(src, PhaseFourHeader)
    @test_throws ErrorException peek(src, PhaseFourHeader; incorrect = true)
    @test_throws ErrorException peek(src, PhaseFourHeader; incorrect = true, misrepresented = true)
    got = peek(src, PhaseFourHeader;
               incomplete = true, incorrect = true, misrepresented = true)
    @test got.a == 9 && got.b == 9
end

# --- MarkedFields transports quality without touching the header struct ------
@testset "MarkedFields wraps a header with a mark" begin
    hdr = PhaseFourHeader(UInt8(0x42), UInt16(0x1337))
    marked = mark_incomplete(hdr)
    @test marked isa MarkedFields
    @test marked.header === hdr                   # header untouched
    @test is_incomplete(quality(marked))
    # peeking back the same type unwraps and returns the header.
    got = peek(marked, PhaseFourHeader; incomplete = true)
    @test got === hdr
end

# --- a marked header inside a packet, which is where one always sits ---------
@testset "a marked header reads through the packet it is in" begin
    # `MarkedFields` is a `Chunk` but not a `Fields`, so a marked header inside
    # a `Sequence` — a packet's header, always — is reached through a different
    # path from a marked header held directly. The gate refused correctly and
    # then named an opt-in that had no way through, which made the error
    # message a lie.
    hdr = PhaseFourHeader(UInt8(0x42), UInt16(0x1337))
    pk = Packet(Filler(Bytes(8); fill = 0x00))
    pushfirst!(pk, mark_incomplete(hdr))
    @test is_incomplete(quality(peek(pk, Chunk)))
    @test_throws ErrorException peek(pk, PhaseFourHeader)
    got = peek(pk, PhaseFourHeader; incomplete = true)
    @test got.a == 0x42 && got.b == 0x1337
end

# --- marking twice joins rather than nesting ---------------------------------
@testset "a second mark on a header joins into the first" begin
    hdr = PhaseFourHeader(UInt8(7), UInt16(7))
    both = mark_incorrect(mark_incomplete(hdr))
    @test both isa MarkedFields
    @test both.header === hdr             # one envelope, not two
    q = quality(both)
    @test is_incomplete(q) && is_incorrect(q)
    # The join is commutative, so the other order is the same chunk.
    @test quality(mark_incomplete(mark_incorrect(hdr))) == q

    # And both flags are still gated independently: opting into one leaves the
    # other refusing.
    pk = Packet(Filler(Bytes(8); fill = 0x00))
    pushfirst!(pk, both)
    @test_throws ErrorException peek(pk, PhaseFourHeader; incomplete = true)
    @test_throws ErrorException peek(pk, PhaseFourHeader; incorrect = true)
    got = peek(pk, PhaseFourHeader; incomplete = true, incorrect = true)
    @test got.a == 7
end
