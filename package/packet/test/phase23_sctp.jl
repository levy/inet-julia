# ============================================================================
# Phase 23 — SCTP: type-length-value at three levels.
# ============================================================================
using Test
using InetPacket.PacketModule

hex23(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

@testset "SCTP — a length and a width are different numbers" begin
    @test minimum_chunk_length(SctpHeader) == Bytes(SCTP_COMMON_HEADER_BYTES)
    @test chunk_length(SctpShutdown) == Bytes(8)
    @test chunk_length(SctpShutdownAck) == Bytes(4)
    @test chunk_length(SctpCookieAck) == Bytes(4)
    @test chunk_length(SctpShutdownComplete) == Bytes(4)
    @test chunk_length(SctpGapAckBlock) == Bytes(4)

    # ---------- a DATA chunk, RFC 4960 clause 3.3.1 -------------------------
    data = SctpData(tsn = UInt32(100), stream_identifier = UInt16(1),
                    data = UInt8[1, 2, 3])
    bytes = encode_header(data)
    # Three octets of data make the chunk nineteen long and twenty wide.
    @test hex23(bytes) ==
          "00 03 00 13 00 00 00 64 00 01 00 00 00 00 00 00 01 02 03 00"
    @test chunk_length(data) == Bytes(20)
    # The stored field keeps its default; the writer derives what reaches the
    # wire, and a reader gets that back.
    @test data.length == 16
    # B and E are the low two bits, and a message that fits in one chunk sets
    # both. I is the bit above them — RFC 7053.
    @test bytes[2] == 0x03
    @test encode_header(SctpData(unordered = true, immediate = true))[2] == 0x0f

    data_back = decode_header(SctpChunk, bytes)
    @test data_back isa SctpData
    @test data_back.beginning && data_back.ending
    @test data_back.length == 19
    @test data_back.tsn == 100
    @test data_back.data == Octets(UInt8[1, 2, 3])
    @test encode_header(data_back) == bytes

    # ---------- an INIT and its parameters, clause 3.3.2 --------------------
    init = SctpInit(initiate_tag = UInt32(0x12345678),
                    parameters = [SctpParameterIpv4Address(
                                      address = Ipv4Address("10.0.0.1")),
                                  SctpParameterForwardTsn(),
                                  SctpParameterSupportedAddresses(
                                      families = UInt16[SCTP_ADDRESS_IPV4])])
    init_bytes = encode_header(init)
    @test Base.length(init_bytes) == 40
    @test hex23(init_bytes[1:4]) == "01 00 00 28"
    @test hex23(init_bytes[5:8]) == "12 34 56 78"
    @test hex23(init_bytes[9:12]) == "00 00 ff ff"     # the receiver window
    # The IPv4 address parameter, then Forward-TSN-Supported.
    @test hex23(init_bytes[21:28]) == "00 05 00 08 0a 00 00 01"
    @test hex23(init_bytes[29:32]) == "c0 00 00 04"
    # The last parameter is the point: RFC 4960 clause 3.2.1 says the length
    # does not count the padding, so it says six where it occupies eight.
    @test hex23(init_bytes[33:40]) == "00 0c 00 06 00 05 00 00"

    init_back = decode_header(SctpChunk, init_bytes)
    @test init_back isa SctpInit
    @test map(typeof, init_back.parameters.values) ==
          [SctpParameterIpv4Address, SctpParameterForwardTsn,
           SctpParameterSupportedAddresses]
    @test init_back.parameters[1].address == Ipv4Address("10.0.0.1")
    @test init_back.parameters[3].families.values == UInt16[SCTP_ADDRESS_IPV4]
    @test encode_header(init_back) == init_bytes

    # A state cookie is opaque, and it pads like every other parameter.
    cookie = SctpParameterStateCookie(cookie = UInt8[1, 2, 3, 4, 5])
    @test cookie.length == SCTP_PARAMETER_HEADER_BYTES   # the default
    @test chunk_length(cookie) == Bytes(12)              # nine, padded to twelve
    @test encode_header(cookie)[3:4] == UInt8[0x00, 0x09]
    init_ack = SctpInitAck(parameters = [cookie])
    @test decode_header(SctpChunk, encode_header(init_ack)) isa SctpInitAck

    # ---------- a SACK, clause 3.3.4 ---------------------------------------
    # Both numbers of a gap block are offsets from the cumulative TSN.
    sack = SctpSack(cumulative_tsn_ack = UInt32(50),
                    gaps = [SctpGapAckBlock(start_offset = UInt16(2),
                                            end_offset = UInt16(4))],
                    duplicates = UInt32[7])
    @test chunk_length(sack) == Bytes(16 + 4 + 4)
    sack_bytes = encode_header(sack)
    @test hex23(sack_bytes[13:16]) == "00 01 00 01"   # one gap, one duplicate
    sack_back = decode_header(SctpChunk, sack_bytes)
    @test sack_back isa SctpSack
    @test sack_back.number_of_gaps == 1               # the writer counted them
    @test sack_back.gaps[1].end_offset == 4
    @test sack_back.duplicates.values == UInt32[7]

    # ---------- an ABORT and its causes, clause 3.3.10 ---------------------
    aborted = SctpAbort(verification_tag_reflected = true,
                        causes = [SctpCauseInvalidStream(stream_identifier = UInt16(3)),
                                  SctpCauseRaw(code = UInt16(200), value = UInt8[9])])
    abort_bytes = encode_header(aborted)
    @test hex23(abort_bytes) ==
          "06 01 00 14 00 01 00 08 00 03 00 00 00 c8 00 05 09 00 00 00"
    # The T bit is the low bit of the flags octet.
    @test abort_bytes[2] == 0x01
    abort_back = decode_header(SctpChunk, abort_bytes)
    @test abort_back isa SctpAbort
    @test abort_back.verification_tag_reflected
    @test map(typeof, abort_back.causes.values) ==
          [SctpCauseInvalidStream, SctpCauseRaw]
    @test abort_back.causes[2].value == Octets(UInt8[9])

    # ---------- the chunks with nothing in them ----------------------------
    for (T, type_code) in ((SctpCookieAck, SCTP_COOKIE_ACK),
                           (SctpShutdownAck, SCTP_SHUTDOWN_ACK),
                           (SctpShutdownComplete, SCTP_SHUTDOWN_COMPLETE))
        small = T()
        @test chunk_length(small) == Bytes(4)
        @test encode_header(small)[1] == type_code
        @test decode_header(SctpChunk, encode_header(small)) isa T
    end

    # ---------- FORWARD TSN, RFC 3758 clause 3.2 ---------------------------
    forward = SctpForwardTsn(new_cumulative_tsn = UInt32(200),
                             streams = [SctpForwardTsnStream(
                                 stream_identifier = UInt16(1),
                                 stream_sequence = UInt16(9))])
    @test chunk_length(forward) == Bytes(12)
    forward_back = decode_header(SctpChunk, encode_header(forward))
    @test forward_back isa SctpForwardTsn
    @test forward_back.streams[1].stream_sequence == 9

    # ---------- a whole packet, clause 3.1 ---------------------------------
    # Nothing counts the chunks: each one says its own length, so a chunk of a
    # type nothing models still leaves the next one where it should start.
    packet = SctpHeader(source_port = 1000, destination_port = 2000,
                        verification_tag = UInt32(7),
                        chunks = [init, data, SctpCookieAck(),
                                  SctpChunkRaw(base = SctpChunkHeader(type = 250),
                                               value = UInt8[1, 2, 3, 4, 5])])
    packet_bytes = encode_header(packet)
    @test Base.length(packet_bytes) == 12 + 40 + 20 + 4 + 12
    @test hex23(packet_bytes[1:4]) == "03 e8 07 d0"
    packet_back = decode_header(SctpHeader, packet_bytes)
    @test map(typeof, packet_back.chunks.values) ==
          [SctpInit, SctpData, SctpCookieAck, SctpChunkRaw]
    @test packet_back.chunks[4].base.type == 250
    @test packet_back.chunks[4].value == Octets(UInt8[1, 2, 3, 4, 5])
    @test encode_header(packet_back) == packet_bytes

    # ---------- a parameter code is two octets, clause 3.2.1 ---------------
    # Every other option family in the inventory reads eight bits to choose.
    @test measure_option_code(SctpParameter) == 16
    @test measure_option_code(SctpCause) == 16
end

@testset "SCTP extensions — seven chunks and eleven more parameters" begin
    # ---------- AUTH, RFC 4895 clause 4.1 -----------------------------------
    auth = SctpAuth(hmac = zeros(UInt8, 20))
    @test chunk_length(auth) == Bytes(SCTP_AUTH_CHUNK_BYTES + 20)
    auth_back = decode_header(SctpChunk, encode_header(auth))
    @test auth_back isa SctpAuth
    @test auth_back.length == SCTP_AUTH_CHUNK_BYTES + 20
    @test Base.length(auth_back.hmac) == 20

    # ---------- ASCONF, RFC 5061 clause 4.1 ---------------------------------
    # The address parameter and the requests are all parameters of the one
    # family, so they are one list — and a request nests an address parameter.
    asconf = SctpAsconf(
        serial_number = UInt32(5),
        parameters = [SctpParameterIpv4Address(address = Ipv4Address("10.0.0.1")),
                      SctpParameterAddIpAddress(
                          correlation_id = UInt32(1),
                          address = [SctpParameterIpv4Address(
                              address = Ipv4Address("10.0.0.2"))])])
    asconf_bytes = encode_header(asconf)
    @test hex23(asconf_bytes) ==
          "c1 00 00 20 00 00 00 05 00 05 00 08 0a 00 00 01 " *
          "c0 01 00 10 00 00 00 01 00 05 00 08 0a 00 00 02"
    asconf_back = decode_header(SctpChunk, asconf_bytes)
    @test asconf_back isa SctpAsconf
    @test asconf_back.serial_number == 5
    @test map(typeof, asconf_back.parameters.values) ==
          [SctpParameterIpv4Address, SctpParameterAddIpAddress]
    # The nested address parameter came back as a parameter, not as octets.
    @test asconf_back.parameters[2].address[1] isa SctpParameterIpv4Address
    @test asconf_back.parameters[2].address[1].address == Ipv4Address("10.0.0.2")
    @test encode_header(asconf_back) == asconf_bytes

    acknowledged = SctpAsconfAck(
        serial_number = UInt32(5),
        parameters = [SctpParameterSuccess(correlation_id = UInt32(1))])
    acknowledged_back = decode_header(SctpChunk, encode_header(acknowledged))
    @test acknowledged_back isa SctpAsconfAck
    @test acknowledged_back.parameters[1] isa SctpParameterSuccess

    # ---------- RE-CONFIG, RFC 6525 -----------------------------------------
    reset = SctpParameterOutgoingReset(request_sequence = UInt32(1),
                                       streams = UInt16[3, 4])
    @test chunk_length(reset) == Bytes(16 + 4)

    # The response is twelve octets or twenty, and only its length says which.
    # It is the one length in the inventory that is not derived: a derive runs
    # on the way out and the `when` clause reads the stored field, so the two
    # would disagree.
    long = build_reset_response(response_sequence = 1, sender_next_tsn = UInt32(9),
                                receiver_next_tsn = UInt32(10))
    @test long.length == 20
    @test chunk_length(long) == Bytes(20)
    short = build_reset_response(response_sequence = 2)
    @test short.length == 12
    @test chunk_length(short) == Bytes(12)
    @test decode_header(SctpParameterResetResponse,
                        encode_header(short)).sender_next_tsn === nothing
    # Both TSNs or neither — RFC 6525 clause 4.4.
    @test_throws Exception build_reset_response(sender_next_tsn = UInt32(9))
    # A length that disagrees with what the parameter carries is a header the
    # model built wrong, and the writer says so.
    @test_throws Exception encode_header(
        SctpParameterResetResponse(length = UInt16(12), sender_next_tsn = UInt32(9),
                                   receiver_next_tsn = UInt32(10)))

    reconfig = SctpReConfig(parameters = [reset, long])
    reconfig_bytes = encode_header(reconfig)
    @test Base.length(reconfig_bytes) == 4 + 20 + 20
    reconfig_back = decode_header(SctpChunk, reconfig_bytes)
    @test reconfig_back isa SctpReConfig
    @test map(typeof, reconfig_back.parameters.values) ==
          [SctpParameterOutgoingReset, SctpParameterResetResponse]
    @test reconfig_back.parameters[1].streams.values == UInt16[3, 4]
    @test reconfig_back.parameters[2].sender_next_tsn == 9
    @test encode_header(reconfig_back) == reconfig_bytes

    # ---------- NR-SACK, which has no RFC -----------------------------------
    # Two lists of gap blocks: the first may still be given back and the second
    # may not. INET's serializer is the specification here.
    nr_sack = SctpNrSack(
        gaps = [SctpGapAckBlock(start_offset = UInt16(1), end_offset = UInt16(2))],
        non_renegable_gaps = [SctpGapAckBlock(start_offset = UInt16(5),
                                              end_offset = UInt16(6))],
        duplicates = UInt32[7])
    @test chunk_length(nr_sack) == Bytes(SCTP_NR_SACK_CHUNK_BYTES + 4 + 4 + 4)
    nr_back = decode_header(SctpChunk, encode_header(nr_sack))
    @test nr_back isa SctpNrSack
    @test nr_back.number_of_gaps == 1
    @test nr_back.number_of_non_renegable_gaps == 1
    @test nr_back.non_renegable_gaps[1].start_offset == 5
    @test nr_back.duplicates.values == UInt32[7]

    # ---------- PKTDROP, which has no RFC either ----------------------------
    dropped = SctpPacketDrop(truncated = true, dropped = UInt8[1, 2, 3])
    drop_bytes = encode_header(dropped)
    @test hex23(drop_bytes[1:4]) == "81 04 00 13"      # T is the third bit
    drop_back = decode_header(SctpChunk, drop_bytes)
    @test drop_back isa SctpPacketDrop
    @test drop_back.truncated
    @test !drop_back.corrupted
    @test drop_back.dropped == Octets(UInt8[1, 2, 3])

    # ---------- I-FORWARD-TSN, RFC 8260 clause 2.3.1 ------------------------
    # Eight octets per stream where the FORWARD-TSN of RFC 3758 spends four: a
    # message identifier is thirty-two bits and a stream sequence number is
    # sixteen.
    @test chunk_length(SctpIforwardTsnStream) == Bytes(8)
    @test chunk_length(SctpForwardTsnStream) == Bytes(4)
    iforward = SctpIforwardTsn(
        streams = [SctpIforwardTsnStream(stream_identifier = UInt16(1),
                                         unordered = true,
                                         message_identifier = UInt32(99))])
    @test chunk_length(iforward) == Bytes(8 + 8)
    iforward_back = decode_header(SctpChunk, encode_header(iforward))
    @test iforward_back isa SctpIforwardTsn
    @test iforward_back.streams[1].unordered
    @test iforward_back.streams[1].message_identifier == 99

    # ---------- every extension chunk is reachable through the family -------
    for (T, type_code) in ((SctpAuth, SCTP_AUTH), (SctpNrSack, SCTP_NR_SACK),
                           (SctpPacketDrop, SCTP_PACKET_DROP),
                           (SctpAsconf, SCTP_ASCONF),
                           (SctpAsconfAck, SCTP_ASCONF_ACK),
                           (SctpReConfig, SCTP_RE_CONFIG),
                           (SctpIforwardTsn, SCTP_IFORWARD_TSN))
        @test encode_header(T())[1] == type_code
        @test decode_header(SctpChunk, encode_header(T())) isa T
    end
end
