# ============================================================================
# Phase 14 — many of the same thing, and a header inside a header.
#
# `Repeated{T}` is the IGMPv3 source list, the IPv4 record-route addresses, the
# RIP entries and the OSPF LSA headers: the standard gives a count and then
# that many of the same thing.
#
# An embedded header falls out of the same three methods, and it is what
# replaces inheritance — Julia has no struct inheritance, and the five-level
# 802.11 chain is four levels of embedding.
# ============================================================================
using Test
using InetPacket.PacketModule

hex14(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

# --- a counted vector --------------------------------------------------------

@header SourceListProbe begin
    group_address     :: Ipv4Address
    number_of_sources :: U16
        derive(Base.length(source_list))
    source_list       :: Repeated{Ipv4Address}
        count(number_of_sources)
end

@testset "Repeated — a count, and then that many" begin
    probe = SourceListProbe(group_address = "224.0.0.1", number_of_sources = 0,
                            source_list = [Ipv4Address("10.0.0.1"),
                                           Ipv4Address("10.0.0.2")])
    @test !is_fixed_length(SourceListProbe)
    @test minimum_chunk_length(SourceListProbe) == Bytes(6)
    @test chunk_length(probe) == Bytes(14)
    @test hex14(encode_header(probe)) ==
          "e0 00 00 01 00 02 0a 00 00 01 0a 00 00 02"

    # The count is derived, so the struct's 0 never reaches the wire.
    read_back = decode_header(SourceListProbe, encode_header(probe))
    @test read_back.number_of_sources == 2
    @test Base.length(read_back.source_list) == 2
    @test read_back.source_list[1] == Ipv4Address("10.0.0.1")
    @test encode_header(read_back) == encode_header(probe)
end

@testset "Repeated — an empty list is a list" begin
    empty = SourceListProbe(group_address = "224.0.0.1", number_of_sources = 0,
                            source_list = Ipv4Address[])
    @test chunk_length(empty) == Bytes(6)
    @test hex14(encode_header(empty)) == "e0 00 00 01 00 00"
    @test Base.length(decode_header(SourceListProbe, encode_header(empty)).source_list) == 0
end

@testset "Repeated — what the type says about itself" begin
    @test is_variable_field(Repeated{Ipv4Address})
    @test !has_field_bits(Repeated{Ipv4Address})
    @test classify_display(Repeated{Ipv4Address}) === :composite
    @test eltype(Repeated{Ipv4Address}) === Ipv4Address

    list = Repeated{Ipv4Address}([Ipv4Address("10.0.0.1")])
    @test measure_value(list, 0) == 32
    @test format_field(list) == "[10.0.0.1]"
    @test Base.length(list) == 1
    @test collect(list) == [Ipv4Address("10.0.0.1")]

    # A whole number of elements, or the reader says so rather than guessing.
    @test_throws ErrorException read_field(BitReader(UInt8[0, 0, 0]),
                                           Repeated{Ipv4Address}, 24, :be)
end

# --- an embedded header ------------------------------------------------------

struct AddressPair <: Fields
    destination :: MacAddress
    source      :: MacAddress
end

@header EmbeddedProbe begin
    addresses      :: AddressPair
    type_or_length :: EtherTypeOrLength
end

@testset "an embedded header runs its codec in place" begin
    # This is `EthernetMacHeader` as INET declares it — an address pair and a
    # type field — and it must give the same bytes as the flat one.
    embedded = EmbeddedProbe(addresses = AddressPair("0a:00:00:00:00:02",
                                                     "0a:00:00:00:00:01"),
                             type_or_length = ETHERTYPE_IPV4)
    flat = EthernetMacHeader("0a:00:00:00:00:02", "0a:00:00:00:00:01", ETHERTYPE_IPV4)

    @test chunk_length(EmbeddedProbe) == Bytes(14)
    @test is_fixed_length(EmbeddedProbe)
    @test encode_header(embedded) == encode_header(flat)
    @test decode_header(EmbeddedProbe, encode_header(embedded)) == embedded
    @test embedded.addresses.destination == MacAddress("0a:00:00:00:00:02")

    @test measure_field(AddressPair) == 96
    @test !has_field_bits(AddressPair)
    @test classify_display(AddressPair) === :composite
end

@header LsaListProbe begin
    count   :: U16
        derive(Base.length(entries))
    entries :: Repeated{AddressPair}
        count(count)
end

@testset "Repeated of a header — an OSPF LSA list needs nothing more" begin
    probe = LsaListProbe(count = 0,
                         entries = [AddressPair(MAC_BROADCAST, MacAddress(1)),
                                    AddressPair(MacAddress(2), MacAddress(3))])
    @test chunk_length(probe) == Bytes(2 + 24)
    read_back = decode_header(LsaListProbe, encode_header(probe))
    @test read_back.count == 2
    @test read_back.entries[1].destination == MAC_BROADCAST
    @test encode_header(read_back) == encode_header(probe)
end
