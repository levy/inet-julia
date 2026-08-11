# ============================================================================
# Phase 21 — Wave 3: the link layer and the physical layer.
#
# The formats INET invented, the IEEE 802.1D bridge messages, 802.15.4, the
# wireless MAC protocols, gPTP and MRP.
# ============================================================================
using Test
using InetPacket.PacketModule

hex21(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

@testset "a header that states its own length, and fills the rest" begin
    # Five of INET's own headers share this shape, and it is the one thing the
    # language could not say until now. `until` says it: the filler runs to the
    # offset the length field names.
    header = AckingMacHeader(source = MacAddress("0a:00:00:00:00:01"),
                             destination = MacAddress("0a:00:00:00:00:02"),
                             network_protocol = 0x0800,
                             filler = build_filler(Bytes(40),
                                                   Bytes(ACKING_MAC_HEADER_BYTES)))
    @test chunk_length(header) == Bytes(40)
    bytes = encode_header(header)
    # 0x28 is forty: the length field counts octets in this one header.
    @test bytes[1] == 0x28
    # The source comes first, which is the opposite of IEEE 802.3.
    @test hex21(bytes[2:7]) == "0a 00 00 00 00 01"
    @test hex21(bytes[8:13]) == "0a 00 00 00 00 02"
    @test all(byte == SIMULATION_FILLER for byte in bytes[24:40])

    back = decode_header(AckingMacHeader, bytes)
    @test back.header_length == 40
    @test Base.length(back.filler.data) == 17
    @test back.destination == MacAddress("0a:00:00:00:00:02")
    @test encode_header(back) == bytes

    # The other four count bits, not octets.
    generic = GenericPhyHeader(payload_protocol = 0x0001,
                               filler = build_filler(Bytes(8), Bytes(4)))
    @test hex21(encode_header(generic)) == "00 40 00 01 3f 3f 3f 3f"
    @test decode_header(GenericPhyHeader, encode_header(generic)).header_length == 64

    for T in (ShortcutMacHeader, GenericPhyHeader, ShortcutPhyHeader)
        @test minimum_chunk_length(T) == Bytes(4)
    end
    @test minimum_chunk_length(ApskPhyHeader) == Bytes(8)

    # A filler that does not fit says so, rather than writing a short header.
    @test_throws ErrorException build_filler(Bytes(4), Bytes(23))
end

# --- IEEE 802.1D, the bridge protocol data units ------------------------------

@testset "BPDU — IEEE 802.1D clause 9, and its timers count 256ths" begin
    @test chunk_length(BpduCommon) == Bytes(4)
    @test chunk_length(BpduTopologyChangeNotification) == Bytes(4)
    @test chunk_length(BpduConfiguration) == Bytes(35)

    # A notification is the four shared octets and nothing else.
    @test hex21(encode_header(BpduTopologyChangeNotification())) == "00 00 00 80"

    configuration =
        BpduConfiguration(root_priority = UInt16(32768),
                          root_address = MacAddress("0a:00:00:00:00:01"),
                          bridge_priority = UInt16(32768),
                          bridge_address = MacAddress("0a:00:00:00:00:02"),
                          max_age = build_bpdu_ticks(20),
                          hello_time = build_bpdu_ticks(2),
                          forward_delay = build_bpdu_ticks(15))
    bytes = encode_header(configuration)
    # Two seconds is 512, which is 0x0200 — the standard counts 256ths.
    @test hex21(bytes[32:33]) == "02 00"
    @test measure_bpdu_seconds(configuration.hello_time) == 2.0
    @test measure_bpdu_seconds(configuration.max_age) == 20.0
    # The flags octet is zero while every flag is clear.
    @test bytes[5] == 0x00

    # IEEE 802.1D-2004 figure 9-4 names the four bits INET calls reserved.
    rapid = BpduConfiguration(root_priority = UInt16(0), root_address = MacAddress(0),
                              bridge_priority = UInt16(0), bridge_address = MacAddress(0),
                              max_age = UInt16(0), hello_time = UInt16(0),
                              forward_delay = UInt16(0),
                              agreement = true, forwarding = true, learning = true,
                              port_role = BPDU_PORT_ROLE_DESIGNATED)
    # agreement 0x40, forwarding 0x20, learning 0x10, and the port role in bits 3 and 2.
    @test encode_header(rapid)[5] == 0x7c

    for header in (configuration, BpduTopologyChangeNotification())
        got = decode_header(Bpdu, encode_header(header))
        @test !(got isa MarkedFields)
        @test got == header
    end
end

# --- IEEE 802.15.4, as INET writes it ----------------------------------------

@testset "IEEE 802.15.4 — little-endian, and three departures from the standard" begin
    header = Ieee802154MacHeader(destination = MacAddress("0a:00:00:00:00:02"),
                                 source = MacAddress("0a:00:00:00:00:01"),
                                 sequence_number = 7, network_protocol = 0x0800)
    @test chunk_length(header) == Bytes(23)
    @test byte_order(Ieee802154MacHeader) === :le

    bytes = encode_header(header)
    # The frame control field is pinned, and little-endian puts its low octet
    # first: 0xcc01 becomes 01 cc.
    @test hex21(bytes[1:2]) == "01 cc"
    @test bytes[3] == 0x07
    # An address goes out low octet first too.
    @test hex21(bytes[6:11]) == "02 00 00 00 00 0a"
    # Where the standard puts the source PAN identifier, INET puts the protocol.
    @test hex21(bytes[14:15]) == "00 08"

    back = decode_header(Ieee802154MacHeader, bytes)
    @test back == header
    @test back.source == MacAddress("0a:00:00:00:00:01")
    @test back.frame_control == IEEE802154_FRAME_CONTROL
end

# --- B-MAC, X-MAC and the CSMA/CA MAC ----------------------------------------

@testset "the wireless MAC frames — a type octet, a length, and filler" begin
    data = BMacDataFrameHeader(source = MacAddress("0a:00:00:00:00:01"),
                               destination = MacAddress("0a:00:00:00:00:02"),
                               sequence_id = UInt64(3), network_protocol = 0x0800)
    @test chunk_length(data) == Bytes(25)
    back = decode_header(BMacHeader, encode_header(data))
    @test back isa BMacDataFrameHeader
    # The length field counts bits in B-MAC and X-MAC.
    @test back.header_length == 200
    @test back.sequence_id == 3

    # A model that wants a longer header says so with filler, and the length
    # follows.
    padded = BMacControlFrame(source = MacAddress(0), destination = MacAddress(0),
                              filler = fill(SIMULATION_FILLER, 5))
    @test chunk_length(padded) == Bytes(20)
    @test decode_header(BMacControlFrame, encode_header(padded)).header_length == 160

    # A type nobody models keeps its octets and its length.
    unknown = decode_header(BMacHeader,
                            vcat(UInt8[0xc8, 0x00, 0x28], fill(SIMULATION_FILLER, 2)))
    @test unknown isa MarkedFields
    @test unknown.header isa BMacUnknownFrame
    @test unknown.header.header_length == 40

    # X-MAC has the same octets as B-MAC.
    @test fieldnames(XMacDataFrameHeader) == fieldnames(BMacDataFrameHeader)
    @test chunk_length(XMacDataFrameHeader(source = MacAddress(0),
                                           destination = MacAddress(0))) == Bytes(25)

    # The CSMA/CA MAC counts octets, and puts the receiver first.
    ack = CsmaCaMacAckHeader(receiver = MacAddress("0a:00:00:00:00:02"),
                             transmitter = MacAddress("0a:00:00:00:00:01"))
    @test chunk_length(ack) == Bytes(14)
    @test hex21(encode_header(ack)[3:8]) == "0a 00 00 00 00 02"
    @test decode_header(CsmaCaMacHeader, encode_header(ack)) isa CsmaCaMacAckHeader

    frame = CsmaCaMacDataHeader(receiver = MacAddress(0), transmitter = MacAddress(0),
                                network_protocol = 0x0800, priority = 3)
    @test chunk_length(frame) == Bytes(17)
    @test decode_header(CsmaCaMacHeader, encode_header(frame)) isa CsmaCaMacDataHeader
    @test chunk_length(CsmaCaMacTrailer) == Bytes(4)
end

# --- IEEE 802.1AS, the generalized precision time protocol --------------------

@testset "gPTP — one common header, and the message type says what follows" begin
    @test chunk_length(GptpCommon) == Bytes(GPTP_HEADER_BYTES)
    @test chunk_length(GptpTimestamp) == Bytes(10)
    @test chunk_length(GptpPortIdentity) == Bytes(10)
    @test chunk_length(GptpScaledNanoseconds) == Bytes(12)
    @test chunk_length(GptpFollowUpInformationTlv) == Bytes(32)

    for (T, bytes) in ((GptpSync, GPTP_SYNC_BYTES),
                       (GptpFollowUp, GPTP_FOLLOW_UP_BYTES),
                       (GptpPdelayReq, GPTP_PDELAY_REQUEST_BYTES),
                       (GptpPdelayResp, GPTP_PDELAY_RESPONSE_BYTES),
                       (GptpPdelayRespFollowUp, GPTP_PDELAY_RESPONSE_FOLLOW_UP_BYTES),
                       (GptpAnnounce, GPTP_ANNOUNCE_BYTES))
        @test chunk_length(T) == Bytes(bytes)
    end

    sync = GptpSync(base = GptpCommon(message_type = GPTP_TYPE_SYNC,
                                      message_length = GPTP_SYNC_BYTES,
                                      flags = GPTP_FLAG_TWO_STEP,
                                      sequence_id = UInt16(7),
                                      source_port_identity =
                                          GptpPortIdentity(clock_identity = UInt64(0x0a00),
                                                           port_number = UInt16(1))))
    bytes = encode_header(sync)
    # The first octet is the major SDO identifier over the message type, and a
    # Sync is type zero.
    @test bytes[1] == 0x10
    # The second is the minor version over the version, which is 1 over 2.
    @test bytes[2] == 0x12
    @test hex21(bytes[3:4]) == "00 2c"

    back = decode_header(GptpMessage, encode_header(sync))
    @test back isa GptpSync
    @test back == sync
    @test back.base.sequence_id == 7
    @test back.base.source_port_identity.port_number == 1

    # Each message comes back as itself.
    for header in (sync, GptpFollowUp(), GptpPdelayReq(), GptpPdelayResp(),
                   GptpPdelayRespFollowUp(), GptpAnnounce())
        got = decode_header(GptpMessage, encode_header(header))
        @test !(got isa MarkedFields)
        @test got == header
    end

    # A message type nobody models comes back as the common header, marked.
    unknown = encode_header(GptpCommon(message_type = 0x7))
    @test decode_header(GptpMessage, unknown) isa MarkedFields
end

# --- IEC 62439-2, the media redundancy protocol -------------------------------

@testset "MRP — a list of records, each padded to four octets" begin
    @test chunk_length(MrpVersion) == Bytes(2)
    @test chunk_length(MrpEnd) == Bytes(2)
    # Every record but End reaches a multiple of four. The Option record is the
    # one where the padding is what gets it there: six octets become eight.
    for (T, bytes) in ((MrpCommon, 20), (MrpTest, 20), (MrpTopologyChange, 12),
                       (MrpLinkDown, 12), (MrpLinkUp, 12), (MrpInTest, 20),
                       (MrpInTopologyChange, 12), (MrpInLinkDown, 16),
                       (MrpInLinkUp, 16), (MrpInLinkStatusPoll, 12), (MrpOption, 8))
        @test chunk_length(T) == Bytes(bytes)
        @test bits(chunk_length(T)) % 32 == 0
    end

    test = MrpTest(source = MacAddress("0a:00:00:00:00:01"), ring_state = 1,
                   transition = 2, timestamp = UInt32(1000))
    bytes = encode_header(test)
    @test bytes[1] == MRP_TLV_TEST
    @test bytes[2] == 18
    @test hex21(bytes[3:4]) == "80 00"
    @test hex21(bytes[5:10]) == "0a 00 00 00 00 01"
    @test decode_header(MrpTest, bytes) == test

    # Link Down and Link Up have one layout and two type octets.
    @test fieldnames(MrpLinkUp) == fieldnames(MrpLinkDown)
    @test option_code(MrpLinkDown) == MRP_TLV_LINK_DOWN
    @test option_code(MrpLinkUp) == MRP_TLV_LINK_UP

    # A frame is a version and then records, and End stops the list.
    frame = vcat(encode_header(MrpCommon(sequence_id = UInt16(1))),
                 encode_header(test),
                 encode_header(MrpEnd()))
    io = BitReader(frame)
    records = read_field(io, Options{MrpTlv}, 8 * Base.length(frame), :be)
    @test Base.length(records) == 3
    @test records[1] isa MrpCommon
    @test records[2] isa MrpTest
    @test records[3] isa MrpEnd
    @test records[1].sequence_id == 1

    # The sub-records of an Option are a family of their own.
    @test chunk_length(MrpAutoManager) == Bytes(2)
    @test chunk_length(MrpSubTlvTestPropagate) == Bytes(18)
    propagate = MrpSubTlvTestPropagate(source = MacAddress("0a:00:00:00:00:01"),
                                       other_manager_priority = UInt16(0x7000),
                                       other_manager_source = MacAddress("0a:00:00:00:00:02"))
    @test decode_header(MrpSubTlvTestPropagate, encode_header(propagate)) == propagate
end
