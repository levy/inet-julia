# ============================================================================
# Phase 20 — Wave 2, the rest: the IPv6 extension headers, ICMPv6 and IGMP.
#
# Three things are new here and none of them existed in Wave 1:
#
# * a repeated element that decides its own length — the IGMPv3 group record
#   and the MLDv2 multicast address record,
# * an option list with no window, which runs to the end of the message — the
#   neighbour discovery options,
# * a variant whose members share a type octet and are told apart by length —
#   the three IGMP queries and the two MLD queries.
# ============================================================================
using Test
using InetPacket.PacketModule

hex20(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

# --- the IPv6 extension headers ----------------------------------------------

@testset "Ipv6HopByHopOptionsHeader — RFC 8200 section 4.3" begin
    # Two octets of header and a PadN that fills the rest: eight octets, which
    # is the smallest an extension header of this shape can be.
    header = Ipv6HopByHopOptionsHeader(next_header = IP_PROTOCOL_TCP,
                                       options = [Ipv6OptionPadN(padding = zeros(UInt8, 4))])
    @test hex20(encode_header(header)) == "06 00 01 04 00 00 00 00"
    @test chunk_length(header) == Bytes(8)

    back = decode_header(Ipv6HopByHopOptionsHeader, encode_header(header))
    # The length octet counts eight-octet units after the first eight, so an
    # eight-octet header carries zero.
    @test back.header_length == 0
    @test back.next_header == IP_PROTOCOL_TCP
    @test encode_header(back) == encode_header(header)

    # A header with no option at all still reaches eight octets, and the six
    # zero octets that get it there read back as six Pad1 options. That is what
    # RFC 8200 says padding is, so the bytes are unchanged.
    empty = Ipv6HopByHopOptionsHeader(next_header = IP_PROTOCOL_TCP)
    @test chunk_length(empty) == Bytes(8)
    read_back = decode_header(Ipv6HopByHopOptionsHeader, encode_header(empty))
    @test Base.length(read_back.options) == 6
    @test all(option isa Ipv6OptionPad1 for option in read_back.options)
    @test encode_header(read_back) == encode_header(empty)
end

@testset "Ipv6DestinationOptionsHeader is the hop-by-hop header's twin" begin
    @test fieldnames(Ipv6DestinationOptionsHeader) ==
          fieldnames(Ipv6HopByHopOptionsHeader)
    @test minimum_chunk_length(Ipv6DestinationOptionsHeader) ==
          minimum_chunk_length(Ipv6HopByHopOptionsHeader)
end

@testset "Ipv6FragmentHeader — RFC 8200 section 4.5, eight octets" begin
    @test chunk_length(Ipv6FragmentHeader) == Bytes(8)

    # A fragment that starts at byte 1480 carries 185, because the field counts
    # eight-octet units.
    fragment = Ipv6FragmentHeader(next_header = IP_PROTOCOL_UDP,
                                  fragment_offset = 185, more_fragments = true,
                                  identification = UInt32(0xdeadbeef))
    @test hex20(encode_header(fragment)) == "11 00 05 c9 de ad be ef"
    @test measure_fragment_offset(fragment) == 1480

    back = decode_header(Ipv6FragmentHeader, encode_header(fragment))
    @test back == fragment
    @test back.more_fragments
    @test back.identification == 0xdeadbeef

    # The last fragment clears the one bit, and only that bit.
    last = Ipv6FragmentHeader(next_header = IP_PROTOCOL_UDP, fragment_offset = 185,
                              more_fragments = false, identification = UInt32(0xdeadbeef))
    @test encode_header(last)[4] == 0xc8
    @test encode_header(last)[[1:3; 5:8]] == encode_header(fragment)[[1:3; 5:8]]
end

@testset "Ipv6RoutingHeader — RFC 8754's segment routing header" begin
    header = Ipv6RoutingHeader(next_header = IP_PROTOCOL_TCP, segments_left = 2,
                               addresses = [Ipv6Address("2001:db8::1"),
                                            Ipv6Address("2001:db8::2")])
    @test chunk_length(header) == Bytes(8 + 2 * 16)

    back = decode_header(Ipv6RoutingHeader, encode_header(header))
    # `header_length` is derived, so the struct that was built holds the zero it
    # was given and the one that was read holds what the writer computed. The
    # bytes are what must agree.
    @test encode_header(back) == encode_header(header)
    # Eight octets of header and two addresses is forty, which is four
    # eight-octet units after the first eight.
    @test back.header_length == 4
    @test back.routing_type == IPV6_ROUTING_TYPE_SEGMENT
    @test Base.length(back.addresses) == 2
    @test back.addresses[2] == Ipv6Address("2001:db8::2")
end

@testset "Ipv6AuthenticationHeader — RFC 4302, and its length is in words" begin
    # INET's version of this header is a stub that writes zero octets. This one
    # is RFC 4302 section 2, so it has the two fields that make AH work.
    header = Ipv6AuthenticationHeader(next_header = IP_PROTOCOL_TCP,
                                      spi = UInt32(0x11223344),
                                      sequence_number = UInt32(7),
                                      integrity_check_value = collect(0x01:0x0c))
    @test chunk_length(header) == Bytes(24)

    back = decode_header(Ipv6AuthenticationHeader, encode_header(header))
    # The field counts four-octet units and then subtracts two: 24 / 4 - 2.
    @test back.payload_length == 4
    @test back.spi == 0x11223344
    @test back.sequence_number == 7
    @test encode_header(back) == encode_header(header)
end

@testset "Ipv6EncapsulatingSecurityPayloadHeader — RFC 4303, and no next header" begin
    # ESP names no next header at the front. The next-header octet travels in
    # the trailer so that it is encrypted with the payload.
    @test chunk_length(Ipv6EncapsulatingSecurityPayloadHeader) == Bytes(8)
    @test fieldnames(Ipv6EncapsulatingSecurityPayloadHeader) ==
          (:spi, :sequence_number)

    esp = Ipv6EncapsulatingSecurityPayloadHeader(spi = UInt32(0x11223344),
                                                 sequence_number = UInt32(1))
    @test hex20(encode_header(esp)) == "11 22 33 44 00 00 00 01"
end

# --- ICMPv6 -------------------------------------------------------------------

@testset "ICMPv6 — RFC 4443's four octets, and what follows them" begin
    @test chunk_length(Icmpv6Common) == Bytes(4)
    @test chunk_length(Icmpv6Header) == Bytes(8)

    request = Icmpv6EchoRequest(identifier = UInt16(0x1234), sequence_number = UInt16(1))
    @test hex20(encode_header(request)) == "80 00 00 00 12 34 00 01"
    @test decode_header(Icmpv6EchoRequest, encode_header(request)) == request

    too_big = Icmpv6PacketTooBig(mtu = UInt32(1280))
    @test hex20(encode_header(too_big)) == "02 00 00 00 00 00 05 00"

    # Each message comes back as itself when the family reads it.
    for header in (request, Icmpv6EchoReply(identifier = UInt16(1), sequence_number = UInt16(1)),
                   too_big, Icmpv6TimeExceeded(), Icmpv6ParameterProblem(pointer = UInt32(40)),
                   Icmpv6DestinationUnreachable())
        back = decode_header(Icmpv6Message, encode_header(header))
        @test !(back isa MarkedFields)
        @test back == header
    end

    # A type no member claims comes back as the eight-byte fallback, marked,
    # with its bytes intact.
    unknown = decode_header(Icmpv6Message, UInt8[0x64, 0x00, 0x00, 0x00, 1, 2, 3, 4])
    @test unknown isa MarkedFields
    @test quality(unknown) == Q_MISREPRESENTED
    @test unknown.header isa Icmpv6Header
    @test encode_header(unknown.header) == UInt8[0x64, 0x00, 0x00, 0x00, 1, 2, 3, 4]
end

@testset "neighbour discovery — RFC 4861, and options with no window" begin
    solicitation =
        Ipv6NeighborSolicitation(target = Ipv6Address("fe80::1"),
                                 options = [Ipv6NdSourceLinkLayerAddress(
                                     address = MacAddress("0a:00:00:00:00:01"))])
    bytes = encode_header(solicitation)
    # Twenty-four octets of message and one eight-octet option.
    @test Base.length(bytes) == 32
    @test hex20(bytes[25:32]) == "01 01 0a 00 00 00 00 01"

    back = decode_header(Ipv6NeighborSolicitation, bytes)
    @test back == solicitation
    @test Base.length(back.options) == 1
    @test back.options[1] isa Ipv6NdSourceLinkLayerAddress
    @test back.options[1].address == MacAddress("0a:00:00:00:00:01")

    # An advertisement carries its three flags in the octet after the checksum.
    advertisement = Ipv6NeighborAdvertisement(target = Ipv6Address("fe80::1"),
                                              router = true, solicited = true,
                                              override = false)
    @test encode_header(advertisement)[5] == 0xc0
    @test decode_header(Icmpv6Message, encode_header(advertisement)) == advertisement

    # A prefix information option is thirty-two octets, and its length octet
    # counts them in eight-octet units.
    prefix = Ipv6NdPrefixInformation(prefix = Ipv6Address("2001:db8::"),
                                     prefix_length = 64, on_link = true,
                                     autonomous = true, valid_lifetime = UInt32(2592000),
                                     preferred_lifetime = UInt32(604800))
    @test chunk_length(prefix) == Bytes(32)
    @test encode_header(prefix)[2] == 0x04
    @test encode_header(prefix)[4] == 0xc0

    router = Ipv6RouterAdvertisement(hop_limit = 64, managed = true,
                                     router_lifetime = UInt16(1800),
                                     options = [prefix, Ipv6NdMtu(mtu = UInt32(1500))])
    @test chunk_length(router) == Bytes(16 + 32 + 8)
    read_back = decode_header(Icmpv6Message, encode_header(router))
    @test read_back == router
    @test Base.length(read_back.options) == 2
    @test read_back.options[2].mtu == 1500

    # An option this library does not model keeps its bytes.
    raw = decode_header(Ipv6RouterSolicitation,
                        vcat(encode_header(Ipv6RouterSolicitation()),
                             UInt8[0x1f, 0x01, 1, 2, 3, 4, 5, 6]))
    @test Base.length(raw.options) == 1
    @test raw.options[1] isa Ipv6NdOptionRaw
    @test raw.options[1].type == 0x1f
    @test raw.options[1].data == Octets(UInt8[1, 2, 3, 4, 5, 6])
end

@testset "MLD — two queries share a type octet, and the length decides" begin
    # RFC 2710: an MLDv1 message is twenty-four octets.
    for T in (MldQuery, MldReport, MldDone)
        @test chunk_length(T) == Bytes(MLD_MESSAGE_BYTES)
    end

    query = MldQuery(maximum_response_delay = UInt16(10000),
                     multicast_address = IPV6_UNSPECIFIED)
    @test decode_header(Icmpv6Message, encode_header(query)) == query

    # RFC 3810: the version 2 query is longer, and that is the only thing that
    # tells the reader which of the two arrived.
    query2 = Mldv2Query(multicast_address = IPV6_UNSPECIFIED, robustness = 2,
                        query_interval_code = 125,
                        sources = [Ipv6Address("2001:db8::1")])
    @test chunk_length(query2) == Bytes(28 + 16)
    back = decode_header(Icmpv6Message, encode_header(query2))
    @test back isa Mldv2Query
    @test encode_header(back) == encode_header(query2)
    @test back.number_of_sources == 1
    @test back.robustness == 2

    # A version 2 report holds records that are not all the same width.
    report = Mldv2Report(records =
        [Mldv2MulticastAddressRecord(record_type = 2,
                                     multicast_address = Ipv6Address("ff02::1"),
                                     sources = [Ipv6Address("2001:db8::1")]),
         Mldv2MulticastAddressRecord(record_type = 1,
                                     multicast_address = Ipv6Address("ff02::2"))])
    @test chunk_length(report) == Bytes(8 + (20 + 16) + 20)
    read_back = decode_header(Icmpv6Message, encode_header(report))
    @test encode_header(read_back) == encode_header(report)
    @test read_back.number_of_records == 2
    @test Base.length(read_back.records) == 2
    @test Base.length(read_back.records[1].sources) == 1
    @test Base.length(read_back.records[2].sources) == 0
end

# --- IGMP ---------------------------------------------------------------------

@testset "IGMP — three queries share a type octet, and the length decides" begin
    @test chunk_length(IgmpCommon) == Bytes(4)
    for T in (Igmpv1Query, Igmpv2Query, Igmpv1Report, Igmpv2Report, Igmpv2Leave,
              RgmpHello, IgmpHeader)
        @test chunk_length(T) == Bytes(IGMP_MESSAGE_BYTES)
    end

    # RFC 3376 section 7.1: at eight octets a query is version 1 when its
    # second octet is zero and version 2 when it is not.
    v1 = Igmpv1Query(group_address = Ipv4Address("224.0.0.1"))
    v2 = Igmpv2Query(base = IgmpCommon(type = IGMP_MEMBERSHIP_QUERY,
                                       max_response_time = 100),
                     group_address = Ipv4Address("239.1.1.1"))
    @test decode_header(IgmpMessage, encode_header(v1)) isa Igmpv1Query
    @test decode_header(IgmpMessage, encode_header(v2)) isa Igmpv2Query
    @test hex20(encode_header(v2)) == "11 64 00 00 ef 01 01 01"

    # A longer query is version 3, whatever its second octet says.
    v3 = Igmpv3Query(base = IgmpCommon(type = IGMP_MEMBERSHIP_QUERY,
                                       max_response_time = 100),
                     group_address = Ipv4Address("239.1.1.1"), robustness = 2,
                     query_interval_code = 125,
                     sources = [Ipv4Address("10.0.0.1")])
    @test hex20(encode_header(v3)) == "11 64 00 00 ef 01 01 01 02 7d 00 01 0a 00 00 01"
    back = decode_header(IgmpMessage, encode_header(v3))
    @test back isa Igmpv3Query
    @test encode_header(back) == encode_header(v3)
    @test back.robustness == 2
    @test back.query_interval_code == 125
    @test Base.length(back.sources) == 1
end

@testset "IGMP — the reports, the leave, and RGMP" begin
    for (header, code) in ((Igmpv1Report(group_address = Ipv4Address("239.1.1.1")),
                            IGMPV1_MEMBERSHIP_REPORT),
                           (Igmpv2Report(group_address = Ipv4Address("239.1.1.1")),
                            IGMPV2_MEMBERSHIP_REPORT),
                           (Igmpv2Leave(group_address = Ipv4Address("224.0.0.2")),
                            IGMPV2_LEAVE_GROUP),
                           (RgmpHello(group_address = Ipv4Address("224.0.0.25")),
                            RGMP_HELLO))
        @test encode_header(header)[1] == code
        got = decode_header(IgmpMessage, encode_header(header))
        @test !(got isa MarkedFields)
        @test got == header
    end

    # A version 3 report holds group records of differing widths, so the count
    # is what the writer derives and the list fills the message.
    report = Igmpv3Report(group_records =
        [Igmpv3GroupRecord(record_type = IGMP_MODE_IS_EXCLUDE,
                           group_address = Ipv4Address("239.1.1.1"),
                           sources = [Ipv4Address("10.0.0.1"), Ipv4Address("10.0.0.2")]),
         Igmpv3GroupRecord(record_type = IGMP_MODE_IS_INCLUDE,
                           group_address = Ipv4Address("239.1.1.2"))])
    @test chunk_length(report) == Bytes(8 + (8 + 8) + 8)
    back = decode_header(IgmpMessage, encode_header(report))
    @test back isa Igmpv3Report
    @test encode_header(back) == encode_header(report)
    @test back.number_of_group_records == 2
    @test Base.length(back.group_records[1].sources) == 2
    @test back.group_records[1].sources[2] == Ipv4Address("10.0.0.2")
    @test Base.length(back.group_records[2].sources) == 0

    # A type no member claims comes back as the fallback, marked.
    unknown = decode_header(IgmpMessage, UInt8[0x99, 0x00, 0x00, 0x00, 1, 2, 3, 4])
    @test unknown isa MarkedFields
    @test quality(unknown) == Q_MISREPRESENTED
    @test unknown.header isa IgmpHeader
end

# --- the corpus ---------------------------------------------------------------

@testset "every declared wire format still round-trips" begin
    # The library's own formats, not the probes an earlier phase declared.
    for T in filter(H -> parentmodule(H) === PacketModule, list_headers())
        @test check_round_trip(T)
    end
end
