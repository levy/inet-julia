# ============================================================================
# Phase 18 — Wave 1: the link layer and the protocol elements.
#
# Each format is checked three ways: the length it declares, the exact bytes it
# encodes to, and the value it comes back as. The byte strings are what make
# "accurate" a check rather than a claim.
# ============================================================================
using Test
using InetPacket.PacketModule

hex18(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

@testset "declared lengths" begin
    @test chunk_length(EthernetMacAddressFields)  == Bytes(12)
    @test chunk_length(EthernetTypeOrLengthField) == Bytes(2)
    @test chunk_length(EthernetControlFrame)      == Bytes(2)
    @test chunk_length(EthernetPauseFrame)        == Bytes(4)
    @test chunk_length(Ieee8021qTagTpidHeader)    == Bytes(4)
    @test chunk_length(Ieee8021qTagEpdHeader)     == Bytes(4)
    @test chunk_length(Ieee8021aeTagTpidHeader)   == Bytes(8)
    @test chunk_length(Ieee8021aeTagEpdHeader)    == Bytes(8)
    @test chunk_length(Ieee8021rTagTpidHeader)    == Bytes(6)
    @test chunk_length(Ieee8021rTagEpdHeader)     == Bytes(6)
    @test chunk_length(Ieee802EpdHeader)          == Bytes(2)
    @test chunk_length(Ieee8022SnapHeader)        == Bytes(5)
    @test chunk_length(PppHeader)                 == Bytes(5)
    @test chunk_length(PppTrailer)                == Bytes(2)
    @test chunk_length(MplsHeader)                == Bytes(4)
    @test chunk_length(SequenceNumberHeader)      == Bytes(2)
    @test chunk_length(FragmentNumberHeader)      == Bytes(1)
    @test chunk_length(ChecksumHeader)            == Bytes(2)
end

@testset "802.1Q — the VLAN tag, both shapes" begin
    tpid = Ieee8021qTagTpidHeader(pcp = 3, dei = true, vid = 100)
    # tpid(16) | pcp(3) dei(1) vid(12)
    @test hex18(encode_header(tpid)) == "81 00 70 64"
    @test decode_header(Ieee8021qTagTpidHeader, encode_header(tpid)) == tpid

    epd = Ieee8021qTagEpdHeader(pcp = 3, dei = true, vid = 100,
                                type_or_length = ETHERTYPE_IPV4)
    @test hex18(encode_header(epd)) == "70 64 08 00"
    @test decode_header(Ieee8021qTagEpdHeader, encode_header(epd)) == epd
end

@testset "802.1AE and 802.1CB — the tags name themselves" begin
    macsec = Ieee8021aeTagTpidHeader(tci_an = 0x0c, sl = 0, pn = 1)
    @test hex18(encode_header(macsec)) == "88 e5 0c 00 00 00 00 01"

    rtag = Ieee8021rTagTpidHeader(sequence_number = 0x1234)
    @test hex18(encode_header(rtag)) == "f1 c1 00 00 12 34"
    # The identifier and the reserved octets are constants, so they are on the
    # wire and not in the struct.
    @test header_fields(Ieee8021rTagTpidHeader) == (:tpid, :reserved, :sequence_number)
    @test rtag.tpid == 0xF1C1
end

@testset "802.2 — the control field is one octet or two" begin
    # Clause 3.2: two octets unless the low two bits are both set.
    short = Ieee8022LlcHeader(dsap = LLC_SAP_SNAP, ssap = LLC_SAP_SNAP,
                              control = LLC_CONTROL_UNNUMBERED_INFORMATION)
    @test chunk_length(short) == Bytes(3)
    @test hex18(encode_header(short)) == "aa aa 03"
    @test !is_present(getfield(short, :control_high))

    long = Ieee8022LlcHeader(dsap = 0x42, ssap = 0x42, control = 0x00,
                             control_high = 0x99)
    @test chunk_length(long) == Bytes(4)
    @test hex18(encode_header(long)) == "42 42 00 99"
    @test decode_header(Ieee8022LlcHeader, encode_header(long)) == long
    @test decode_header(Ieee8022LlcHeader, encode_header(short)) == short

    # The header is variable-length, and says so.
    @test !is_fixed_length(Ieee8022LlcHeader)
    @test minimum_chunk_length(Ieee8022LlcHeader) == Bytes(3)
end

@testset "802.2 SNAP — an embedded LLC header, not a second declaration" begin
    snap = Ieee8022LlcSnapHeader(oui = 0, protocol_id = 0x0800)
    @test chunk_length(snap) == Bytes(8)
    @test hex18(encode_header(snap)) == "aa aa 03 00 00 00 08 00"
    @test decode_header(Ieee8022LlcSnapHeader, encode_header(snap)) == snap
    @test snap.llc.dsap == LLC_SAP_SNAP
    @test fieldtype(Ieee8022LlcSnapHeader, :llc) === Ieee8022LlcHeader
end

@testset "PPP — RFC 1662, in the shape INET serializes" begin
    header = PppHeader(protocol = PPP_PROTOCOL_IPV4)
    @test hex18(encode_header(header)) == "7e ff 03 00 21"
    @test decode_header(PppHeader, encode_header(header)) == header
    # INET's trailer is two bytes: it does not carry the closing flag.
    @test hex18(encode_header(PppTrailer(fcs = 0xbeef))) == "be ef"
end

@testset "MPLS — RFC 3032, one label stack entry" begin
    entry = MplsHeader(label = 16, tc = 0, bottom_of_stack = true, time_to_live = 64)
    # label(20) tc(3) s(1) ttl(8)
    @test hex18(encode_header(entry)) == "00 01 01 40"
    @test decode_header(MplsHeader, encode_header(entry)) == entry
    @test MplsHeader(label = 16, bottom_of_stack = false, time_to_live = 64).bottom_of_stack ==
          false
end

@testset "the Ethernet control frames are a variant" begin
    pause = EthernetPauseFrame(pause_time = 0xffff)
    @test hex18(encode_header(pause)) == "00 01 ff ff"
    decoded = decode_header(EthernetControlMessage, encode_header(pause))
    @test decoded isa EthernetPauseFrame
    @test decoded.pause_time == 0xffff
    @test decoded.base.op_code == ETHERNET_CONTROL_PAUSE

    # An opcode nobody models comes back as the base, marked.
    marked = decode_header(EthernetControlMessage, UInt8[0x00, 0x02])
    @test marked isa MarkedFields && marked.header isa EthernetControlFrame
    @test quality(marked) == Q_MISREPRESENTED
end

@testset "the protocol elements carry one fact each" begin
    @test hex18(encode_header(SequenceNumberHeader(sequence_number = 0x1234))) == "12 34"
    # Seven bits of number and the last-fragment bit.
    @test hex18(encode_header(FragmentNumberHeader(fragment_number = 3,
                                                   last_fragment = true))) == "07"
    @test hex18(encode_header(FragmentNumberHeader(fragment_number = 3))) == "06"
    @test hex18(encode_header(ChecksumHeader(checksum = 0xabcd))) == "ab cd"
    @test ChecksumHeader(checksum = 0).checksum_mode == CHECKSUM_DECLARED
end

@testset "Wave 1 is in the corpus" begin
    corpus = Set(filter(H -> parentmodule(H) === PacketModule, list_headers()))
    for H in (EthernetMacAddressFields, EthernetTypeOrLengthField, EthernetControlFrame,
              EthernetPauseFrame, Ieee8021qTagTpidHeader, Ieee8021qTagEpdHeader,
              Ieee8021aeTagTpidHeader, Ieee8021aeTagEpdHeader, Ieee8021rTagTpidHeader,
              Ieee8021rTagEpdHeader, Ieee802EpdHeader, Ieee8022LlcHeader,
              Ieee8022SnapHeader, Ieee8022LlcSnapHeader, PppHeader, PppTrailer,
              MplsHeader, SequenceNumberHeader, FragmentNumberHeader, ChecksumHeader)
        @test H in corpus
        @test check_round_trip(H)
    end
end
