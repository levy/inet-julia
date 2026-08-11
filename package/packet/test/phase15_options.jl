# ============================================================================
# Phase 15 — an ordered list of type-length-value options.
#
# This is IPv4 options, TCP options, the IPv6 hop-by-hop and destination
# options, DHCP options, SCTP INIT parameters, MIPv6 mobility options, BGP path
# attributes and the 802.11 information elements — one shape, nine protocols.
#
# It is also the largest gap in INET itself. `SERIALIZER_REMAINING_GAPS.md`
# names four families that lose bytes for want of it, all with the same cause:
# a fixed struct of known options cannot preserve the order the sender used and
# cannot hold a code it does not know. Both losses break a byte round trip, so
# the tests below press exactly those two properties.
#
# The family below is TCP's in miniature, under names of its own: the library
# declares the real one in `protocol/TcpOption.jl`, and a fixture that took its
# names would shadow it.
# ============================================================================
using Test
using InetPacket.PacketModule

hex15(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

const PROBE_END = 0x00
const PROBE_NOP = 0x01
const PROBE_MSS = 0x02

abstract type ProbeOption <: Fields end

@header ProbeOptionEnd <: ProbeOption begin
    kind :: Constant{U8, PROBE_END}
end

@header ProbeOptionNop <: ProbeOption begin
    kind :: Constant{U8, PROBE_NOP}
end

@header ProbeOptionMss <: ProbeOption begin
    kind             :: Constant{U8, PROBE_MSS}
    length           :: Constant{U8, 0x04}
    max_segment_size :: U16
end

# The catch-all. Without one, an option the library does not know would be
# dropped and the list would not round-trip.
@header ProbeOptionRaw <: ProbeOption begin
    kind   :: U8
    length :: U8
        derive(Base.length(data) + 2)
    data   :: Octets
        length(Bytes(length - 2))
end

PacketModule.list_options(::Type{ProbeOption}) = (ProbeOptionEnd, ProbeOptionNop, ProbeOptionMss)
PacketModule.find_raw_option(::Type{ProbeOption}) = ProbeOptionRaw
PacketModule.ends_option_list(::Type{ProbeOption}, code) = code == PROBE_END

@header SegmentProbe begin
    data_offset :: U4
        derive(cld(measure_header(h), 32))
    reserved    :: U4 = 0
    options     :: Options{ProbeOption}
        until(Bytes(4) * data_offset)
    padding     :: Pad{Bytes(4), 0x00}
end

# --- the family --------------------------------------------------------------

@testset "a member states its own code, through its first constant" begin
    @test option_code(ProbeOptionEnd) == PROBE_END
    @test option_code(ProbeOptionMss) == PROBE_MSS
    @test find_option_type(ProbeOption, PROBE_MSS) === ProbeOptionMss
    @test find_option_type(ProbeOption, 0x07) === ProbeOptionRaw
    @test ends_option_list(ProbeOption, PROBE_END)
    @test !ends_option_list(ProbeOption, PROBE_NOP)
    @test measure_option_code(ProbeOption) == 8

    # A member is a header of its family, and a header of the library.
    @test ProbeOptionMss <: ProbeOption
    @test ProbeOptionMss <: Fields
    @test chunk_length(ProbeOptionMss) == Bytes(4)
    @test chunk_length(ProbeOptionEnd) == Bytes(1)
end

# --- a list the library knows ------------------------------------------------

@testset "a list of known options round-trips, in order" begin
    probe = SegmentProbe(data_offset = 0,
                         options = ProbeOption[ProbeOptionMss(max_segment_size = 1460),
                                             ProbeOptionNop(),
                                             ProbeOptionEnd()])
    bytes = encode_header(probe)
    @test hex15(bytes) == "20 02 04 05 b4 01 00 00"
    @test chunk_length(probe) == Bytes(8)
    @test bytes[1] >> 4 == 2                       # data_offset, derived

    read_back = decode_header(SegmentProbe, bytes)
    @test [nameof(typeof(o)) for o in read_back.options] ==
          [:ProbeOptionMss, :ProbeOptionNop, :ProbeOptionEnd]
    @test read_back.options[1].max_segment_size == 1460
    @test encode_header(read_back) == bytes
end

@testset "the ORDER is the sender's, not the library's" begin
    # The property INET's DHCP, SCTP and MIPv6 models lack: two lists with the
    # same options in a different order are two different lists.
    one = SegmentProbe(data_offset = 0,
                       options = ProbeOption[ProbeOptionNop(),
                                           ProbeOptionMss(max_segment_size = 536)])
    other = SegmentProbe(data_offset = 0,
                         options = ProbeOption[ProbeOptionMss(max_segment_size = 536),
                                             ProbeOptionNop()])
    @test encode_header(one) != encode_header(other)
    # The padding after the options is zeros, and a zero IS an End of Option
    # List — so the list reads back with the terminator the padding spelled.
    # What matters is that the ORDER survived.
    @test [nameof(typeof(o)) for o in decode_header(SegmentProbe,
                                                    encode_header(one)).options] ==
          [:ProbeOptionNop, :ProbeOptionMss, :ProbeOptionEnd]
    @test encode_header(decode_header(SegmentProbe, encode_header(one))) ==
          encode_header(one)
end

# --- a list the library does not know ----------------------------------------

@testset "an option nobody knows survives, in place" begin
    # kind 7, length 4, two bytes of payload — then a NOP and the end.
    wire = UInt8[0x20,  0x07, 0x04, 0xde, 0xad,  0x01, 0x00,  0x00]
    read_back = decode_header(SegmentProbe, wire)

    @test [nameof(typeof(o)) for o in read_back.options] ==
          [:ProbeOptionRaw, :ProbeOptionNop, :ProbeOptionEnd]
    @test read_back.options[1].kind == 0x07
    @test read_back.options[1].data == Octets(UInt8[0xde, 0xad])

    # Byte for byte, which is the whole point.
    @test encode_header(read_back) == wire
end

@testset "the list stops at an ending code, and skips the padding" begin
    # An END in the middle: what follows is padding, not an option, so the list
    # has two entries and not seven.
    wire = UInt8[0x20,  0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00]
    read_back = decode_header(SegmentProbe, wire)
    @test [nameof(typeof(o)) for o in read_back.options] ==
          [:ProbeOptionNop, :ProbeOptionEnd]

    # It does NOT come back byte for byte, and that is worth stating plainly.
    # `data_offset` is derived, so re-encoding writes the header the options
    # need — four bytes — rather than the eight this sender chose. A capture
    # whose padding is not minimal therefore normalises. Preserving it needs
    # `data_offset` read from the wire instead of derived, which is the same
    # choice `total_length` already makes.
    @test encode_header(read_back) == UInt8[0x10, 0x01, 0x00, 0x00]
    @test [nameof(typeof(o)) for o in
           decode_header(SegmentProbe, encode_header(read_back)).options] ==
          [:ProbeOptionNop, :ProbeOptionEnd]
end

@testset "an empty list still meets the padding" begin
    probe = SegmentProbe(data_offset = 0, options = ProbeOption[])
    @test hex15(encode_header(probe)) == "10 00 00 00"
    # Three zero bytes of padding, and a zero is an End of Option List — so the
    # list reads back with one entry, and the bytes are unchanged.
    read_back = decode_header(SegmentProbe, encode_header(probe))
    @test [nameof(typeof(o)) for o in read_back.options] == [:ProbeOptionEnd]
    @test encode_header(read_back) == encode_header(probe)
end

# --- what the list refuses ---------------------------------------------------

# A family whose only member reads nothing. It exists to press the loop guard,
# which is the defect the C++ branch fixed twice — in the IPv6 TLV reader and in
# the BGP length reader — after each spun forever on malformed input.
abstract type EmptyOption <: Fields end

@header EmptyOptionMember <: EmptyOption begin
    nothing_at_all :: Model{U8} = 0
end

PacketModule.list_options(::Type{EmptyOption}) = ()
PacketModule.find_raw_option(::Type{EmptyOption}) = EmptyOptionMember

@header EmptyProbe begin
    length  :: U8
    options :: Options{EmptyOption}
        until(Bytes(length))
end

@testset "an option that reads nothing would never end, so the loop refuses" begin
    @test chunk_length(EmptyOptionMember) == Bits(0)
    @test_throws ErrorException decode_header(EmptyProbe, UInt8[0x04, 0x07, 0x00, 0x00])
end

@testset "what an Options field says about itself" begin
    @test is_variable_field(Options{ProbeOption})
    @test !has_field_bits(Options{ProbeOption})
    @test classify_display(Options{ProbeOption}) === :composite
    @test eltype(Options{ProbeOption}) === ProbeOption
    @test !is_fixed_length(SegmentProbe)
    @test minimum_chunk_length(SegmentProbe) == Bytes(1)

    list = Options{ProbeOption}(ProbeOption[ProbeOptionNop(), ProbeOptionEnd()])
    @test measure_value(list, 0) == 16
    @test Base.length(list) == 2
    @test format_field(list) == "[ProbeOptionNop, ProbeOptionEnd]"
end
