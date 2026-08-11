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

# --- IEEE 802.11 --------------------------------------------------------------

@testset "IEEE 802.11 — a frame control field, and two fields of its own order" begin
    @test chunk_length(Ieee80211FrameControl) == Bytes(2)
    for (T, bytes) in ((Ieee80211Ack, IEEE80211_ACK_BYTES),
                       (Ieee80211Cts, IEEE80211_CTS_BYTES),
                       (Ieee80211Rts, IEEE80211_RTS_BYTES),
                       (Ieee80211PsPoll, IEEE80211_PS_POLL_BYTES),
                       (Ieee80211MgmtHeader, IEEE80211_MANAGEMENT_BYTES),
                       (Ieee80211BlockAckRequest, IEEE80211_BLOCK_ACK_REQUEST_BYTES),
                       (Ieee80211CompressedBlockAck, 28),
                       (Ieee80211BasicBlockAck, 148),
                       (Ieee80211MacTrailer, 4))
        @test chunk_length(T) == Bytes(bytes)
    end

    control(type, subtype; kwargs...) =
        Ieee80211FrameControl(; frame_type = type, subtype = subtype, kwargs...)

    ack = Ieee80211Ack(base = Ieee80211Common(
        frame_control = control(IEEE80211_TYPE_CONTROL, IEEE80211_SUBTYPE_ACK),
        duration = 0, receiver = MacAddress("0a:00:00:00:00:01")))
    # The first octet is subtype, type and version: 0xd, 1, 0 is 0xd4.
    @test hex21(encode_header(ack)) == "d4 00 00 00 0a 00 00 00 00 01"
    @test decode_header(Ieee80211MacHeader, encode_header(ack)) isa Ieee80211Ack

    # The duration is little-endian where the addresses are not.
    data = Ieee80211DataHeader(
        base = Ieee80211Common(
            frame_control = control(IEEE80211_TYPE_DATA, IEEE80211_SUBTYPE_DATA),
            duration = 100, receiver = MacAddress("0a:00:00:00:00:01")),
        transmitter = MacAddress("0a:00:00:00:00:02"),
        address3 = MacAddress("0a:00:00:00:00:03"),
        sequence_control = Ieee80211SequenceControl(fragment_number = 1,
                                                    sequence_number = 0x123))
    bytes = encode_header(data)
    @test chunk_length(data) == Bytes(24)
    @test hex21(bytes[3:4]) == "64 00"                    # duration, low octet first
    @test hex21(bytes[5:10]) == "0a 00 00 00 00 01"       # address, as it is
    # Sequence control packs the fragment low and the sequence high, then goes
    # out little-endian: 0x1231 becomes 31 12.
    @test hex21(bytes[23:24]) == "31 12"

    back = decode_header(Ieee80211MacHeader, bytes)
    @test back isa Ieee80211DataHeader
    @test back == data
    @test read_sequence_number(back.sequence_control) == 0x123
    @test read_fragment_number(back.sequence_control) == 1
    @test read_microseconds(back.base.duration) == 100

    # The fourth address is there only between two access points, and the
    # quality-of-service control only for a QoS subtype.
    both = Ieee80211DataHeader(
        base = Ieee80211Common(
            frame_control = control(IEEE80211_TYPE_DATA, IEEE80211_SUBTYPE_QOS_DATA,
                                    to_ds = true, from_ds = true),
            receiver = MacAddress(0)),
        transmitter = MacAddress(0), address3 = MacAddress(0),
        address4 = MacAddress("0a:00:00:00:00:04"), qos_control = UInt16(7))
    @test chunk_length(both) == Bytes(24 + 6 + 2)
    read_back = decode_header(Ieee80211MacHeader, encode_header(both))
    @test read_back == both
    @test read_back.address4 == MacAddress("0a:00:00:00:00:04")
    @test has_fourth_address(both.base.frame_control)
    @test has_qos_control(both.base.frame_control)

    # A PS-Poll reads its duration field as an association identifier.
    poll = Ieee80211PsPoll(base = Ieee80211Common(
        frame_control = control(IEEE80211_TYPE_CONTROL, IEEE80211_SUBTYPE_PS_POLL),
        duration = IEEE80211_AID_MARK | 42, receiver = MacAddress(0)),
        transmitter = MacAddress(0))
    @test is_association_id(poll.base.duration)
    @test read_association_id(poll.base.duration) == 42
    @test read_microseconds(poll.base.duration) === nothing

    # The block acknowledgement request is the standard's twenty octets.
    request = Ieee80211BlockAckRequest(
        base = Ieee80211Common(
            frame_control = control(IEEE80211_TYPE_CONTROL,
                                    IEEE80211_SUBTYPE_BLOCK_ACK_REQUEST),
            receiver = MacAddress(0)),
        transmitter = MacAddress(0), starting_sequence = 0x123)
    @test chunk_length(request) == Bytes(20)
    @test decode_header(Ieee80211MacHeader, encode_header(request)) == request

    # An action frame this library does not model keeps its body.
    other = Ieee80211ActionOther(
        header = Ieee80211MgmtHeader(
            base = Ieee80211Common(
                frame_control = control(IEEE80211_TYPE_MANAGEMENT,
                                        IEEE80211_SUBTYPE_ACTION),
                receiver = MacAddress(0)),
            transmitter = MacAddress(0), bssid = MacAddress(0)),
        body = UInt8[0x7f, 1, 2, 3])
    @test chunk_length(other) == Bytes(28)
    @test decode_header(Ieee80211ActionOther, encode_header(other)) == other
end

@testset "FixedOctets — a run the standard states, not one a field decides" begin
    # A field of a stated width is not variable, so the header stays fixed.
    @test measure_field(FixedOctets{128}) == 1024
    @test !is_variable_field(FixedOctets{128})
    @test chunk_length(Ieee80211BasicBlockAck) == Bytes(148)
    @test chunk_length(GptpPdelayReq) == Bytes(54)
    @test_throws ErrorException FixedOctets{4}(UInt8[1, 2])
end

@testset "a header's length is what it writes, not what it holds" begin
    # A `when` clause can say a field is absent while the struct still holds a
    # value. The length has to follow the clause, or a packet would reserve room
    # for octets that never go out.
    header = Ieee80211DataHeader(
        base = Ieee80211Common(
            frame_control = Ieee80211FrameControl(frame_type = IEEE80211_TYPE_DATA,
                                                  subtype = IEEE80211_SUBTYPE_DATA),
            receiver = MacAddress(0)),
        transmitter = MacAddress(0), address3 = MacAddress(0),
        address4 = MacAddress("0a:00:00:00:00:04"))
    @test !has_fourth_address(header.base.frame_control)
    @test chunk_length(header) == Bytes(24)
    @test Base.length(encode_header(header)) == 24
end
