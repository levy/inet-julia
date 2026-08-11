# ============================================================================
# Phase 13 — a length the data decides.
#
# Three field kinds, and none of them needs a new clause except `Octets`:
#
#   Octets   a run of bytes the header does not model; a `length(…)` clause
#            says how long it is this time
#   Rest     the remainder of the window; the type says everything
#   Pad{B,F} up to a boundary; both facts are type parameters, so no clause
#
# A header with any of them is variable-length, which is what makes
# `chunk_length` a property of the value rather than of the type.
# ============================================================================
using Test
using InetPacket.PacketModule

hex13(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

@header TailProbe begin
    kind  :: U8
    count :: U16
        derive(Base.length(body))
    body  :: Octets
        length(Bytes(count))
end

@testset "a byte run takes its length from another field" begin
    probe = TailProbe(kind = 1, count = 0, body = UInt8[0xaa, 0xbb, 0xcc])
    @test !is_fixed_length(TailProbe)
    @test minimum_chunk_length(TailProbe) == Bytes(3)
    @test chunk_length(probe) == Bytes(6)
    @test hex13(encode_header(probe)) == "01 00 03 aa bb cc"

    # `count` is derived, so the struct's 0 never reaches the wire and the
    # reader keeps the 3 that did.
    read_back = decode_header(TailProbe, encode_header(probe))
    @test read_back.body == Octets(UInt8[0xaa, 0xbb, 0xcc])
    @test read_back.count == 3
    @test encode_header(read_back) == encode_header(probe)

    # A different length is a different header, from the same declaration.
    empty = TailProbe(kind = 1, count = 0, body = UInt8[])
    @test chunk_length(empty) == Bytes(3)
    @test hex13(encode_header(empty)) == "01 00 00"
    @test decode_header(TailProbe, encode_header(empty)).body == Octets(UInt8[])
end

@testset "a variable header has no length until it has a value" begin
    # Asking the TYPE is a question with no answer, and the error says which
    # two questions do have one.
    message = try
        chunk_length(TailProbe)
        ""
    catch exception
        sprint(showerror, exception)
    end
    @test occursin("depends on the instance", message)
    @test occursin("minimum_chunk_length", message)

    # A fixed header is unaffected.
    @test is_fixed_length(UdpHeader)
    @test chunk_length(UdpHeader) == Bytes(8)
    @test minimum_chunk_length(UdpHeader) == Bytes(8)
end

@testset "peek finds a variable header without being told its size" begin
    probe = TailProbe(kind = 2, count = 0, body = UInt8[0x01, 0x02, 0x03, 0x04])
    source = Raw(encode_header(probe))
    found = peek(source, TailProbe)
    @test found.body == probe.body
    @test chunk_length(found) == Bytes(7)
    # A window too short for even the fixed part is incomplete.
    @test_throws ErrorException peek(Raw(UInt8[0x02, 0x00]), TailProbe)
end

# --- Rest --------------------------------------------------------------------

@header RestProbe begin
    kind :: U8
    tail :: Rest
end

@testset "Rest takes the remainder, and needs no clause" begin
    @test !is_fixed_length(RestProbe)
    @test hex13(encode_header(RestProbe(kind = 9, tail = UInt8[0xde, 0xad]))) == "09 de ad"
    @test decode_header(RestProbe, UInt8[0x09, 0xde, 0xad, 0xbe, 0xef]).tail ==
          Rest(UInt8[0xde, 0xad, 0xbe, 0xef])
    @test decode_header(RestProbe, UInt8[0x09]).tail == Rest(UInt8[])
    @test chunk_length(RestProbe(kind = 9, tail = UInt8[0xde, 0xad])) == Bytes(3)
end

# --- padding -----------------------------------------------------------------

@header PadProbe begin
    kind    :: U8
    body    :: Octets
        length(Bytes(3))
    padding :: Pad{Bytes(4), 0xff}
end

@testset "padding takes the header up to a boundary" begin
    # 1 fixed byte plus the body, rounded up to four. A `Pad` field is a
    # singleton the type describes, so a caller never names it.
    @test hex13(encode_header(PadProbe(kind = 1, body = UInt8[0xaa]))) == "01 aa ff ff"
    @test hex13(encode_header(PadProbe(kind = 1, body = UInt8[0xaa, 0xaa, 0xaa]))) ==
          "01 aa aa aa"                                   # already on the boundary
    @test chunk_length(PadProbe(kind = 1, body = UInt8[0xaa])) == Bytes(4)
    @test chunk_length(PadProbe(kind = 1, body = UInt8[0xaa, 0xaa, 0xaa, 0xaa])) == Bytes(8)

    # The reader skips exactly what the writer wrote.
    probe = PadProbe(kind = 1, body = UInt8[0xaa, 0xbb, 0xcc])
    @test decode_header(PadProbe, encode_header(probe)) == probe
    # The struct stores nothing for it.
    @test sizeof(Pad{Bytes(4), 0xff}) == 0
end

@testset "measure_padding is the rule both codecs use" begin
    @test measure_padding(0, Bytes(4)) == 0
    @test measure_padding(8, Bytes(4)) == 24
    @test measure_padding(24, Bytes(4)) == 8
    @test measure_padding(32, Bytes(4)) == 0
    @test_throws ErrorException measure_padding(8, Bits(0))
end

# --- what a byte run is, and is not -----------------------------------------

@testset "a byte run is not a number, however short" begin
    @test !has_field_bits(Octets)
    @test !has_field_bits(Rest)
    @test is_variable_field(Octets)
    @test is_variable_field(Rest)
    @test is_variable_field(Pad{Bytes(4), 0x00})
    @test !is_variable_field(U16)

    @test format_field(Octets(UInt8[0xaa, 0xbb])) == "aa bb"
    @test occursin("(20 B)", format_field(Octets(fill(0x00, 20))))
    @test measure_value(Octets(UInt8[0xaa, 0xbb]), 0) == 16
    @test measure_value(Pad{Bytes(4), 0x00}(), 8) == 24
end

@testset "the layout of a variable header stops at the first variable field" begin
    layout = describe_layout(TailProbe)
    @test [f.name for f in layout.fields] == [:kind, :count]
    @test layout.length == Bytes(3)
end

@testset "the layout of an INSTANCE has the widths this header has" begin
    probe = TailProbe(kind = 1, count = 3, body = UInt8[0xaa, 0xbb, 0xcc])
    layout = describe_layout(probe)
    @test [f.name for f in layout.fields] == [:kind, :count, :body]
    @test [f.offset for f in layout.fields] == [0, 8, 24]
    @test [f.width for f in layout.fields] == [8, 16, 24]
    @test layout.length == Bytes(6)

    body = layout.fields[3]
    @test !has_bits(body)
    @test format_field(probe, body) == "aa bb cc"
    @test_throws ErrorException encode_field(probe, body)

    # Padding is in the instance layout too: a view must draw the bytes that
    # are there.
    padded = describe_layout(PadProbe(kind = 1, body = UInt8[0xaa]))
    @test [f.name for f in padded.fields] == [:kind, :body, :padding]
    @test [f.width for f in padded.fields] == [8, 8, 16]
    @test padded.length == Bytes(4)

    # A fixed header answers the same either way.
    @test describe_layout(UdpHeader).length ==
          describe_layout(UdpHeader(source_port = 1, destination_port = 2)).length
end
