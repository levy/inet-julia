# ============================================================================
# Phase 25 — the IEEE 802.11 management frame bodies.
# ============================================================================
using Test
using InetPacket.PacketModule

hex25(bytes) = join((string(b, base = 16, pad = 2) for b in bytes), " ")

@testset "802.11 management — every body ends with a list of elements" begin
    # ---------- the elements, clause 9.4.2 ---------------------------------
    ssid = Ieee80211ElementSsid(ssid = Vector{UInt8}("net"))
    # The identifier is zero — the octet INET writes with "dummy, what is it?".
    @test hex25(encode_header(ssid)) == "00 03 6e 65 74"
    @test chunk_length(ssid) == Bytes(IEEE80211_ELEMENT_HEADER_BYTES + 3)

    # A rate octet counts 500 kbit/s units, and the top bit marks a basic rate.
    @test build_supported_rate(1; basic = true) == 0x82
    @test build_supported_rate(11) == 0x16
    @test measure_supported_rate(0x82) == 1.0
    @test measure_supported_rate(0x16) == 11.0
    @test is_basic_rate(0x82)
    @test !is_basic_rate(0x16)

    rates = Ieee80211ElementSupportedRates(
        rates = UInt8[build_supported_rate(1; basic = true),
                      build_supported_rate(11)])
    @test hex25(encode_header(rates)) == "01 02 82 16"

    channel = Ieee80211ElementDsParameterSet(channel = 6)
    @test hex25(encode_header(channel)) == "03 01 06"
    @test chunk_length(Ieee80211ElementIbssParameterSet) == Bytes(4)

    # ---------- a beacon, clause 9.3.3.3 -----------------------------------
    beacon = Ieee80211Beacon(timestamp = UInt64(0x1122334455667788),
                             beacon_interval = UInt16(100),
                             capability_information = UInt16(0x0001),
                             elements = [ssid, rates, channel])
    bytes = encode_header(beacon)
    @test hex25(bytes) ==
          "11 22 33 44 55 66 77 88 00 64 00 01 00 03 6e 65 74 01 02 82 16 03 01 06"
    @test chunk_length(beacon) == Bytes(12 + 5 + 4 + 3)

    beacon_back = decode_header(Ieee80211Beacon, bytes)
    @test map(typeof, beacon_back.elements.values) ==
          [Ieee80211ElementSsid, Ieee80211ElementSupportedRates,
           Ieee80211ElementDsParameterSet]
    @test String(copy(beacon_back.elements[1].ssid.data)) == "net"
    @test beacon_back.elements[3].channel == 6
    @test encode_header(beacon_back) == bytes

    # A beacon interval counts time units of 1024 microseconds, so the usual
    # hundred is 102400 microseconds and not 100000 — clause 3.1.
    @test measure_beacon_interval(beacon_back.beacon_interval) == 102400
    @test build_beacon_interval(102400) == 100

    # ---------- an element nothing models keeps its place ------------------
    # INET writes two elements inline and in a fixed order, so it reads its own
    # beacons and nothing else.
    mixed = Ieee80211ProbeResponse(
        elements = [ssid, Ieee80211ElementRaw(id = 42, value = UInt8[0x04]), rates])
    mixed_bytes = encode_header(mixed)
    mixed_back = decode_header(Ieee80211ProbeResponse, mixed_bytes)
    @test map(typeof, mixed_back.elements.values) ==
          [Ieee80211ElementSsid, Ieee80211ElementRaw,
           Ieee80211ElementSupportedRates]
    @test mixed_back.elements[2].id == 42
    @test mixed_back.elements[2].value == Octets(UInt8[0x04])
    @test encode_header(mixed_back) == mixed_bytes

    # ---------- the fixed fields of each body ------------------------------
    request = Ieee80211AssociationRequest(capability_information = UInt16(0x0001),
                                          listen_interval = UInt16(10),
                                          elements = [ssid, rates])
    @test hex25(encode_header(request)[1:4]) == "00 01 00 0a"
    @test decode_header(Ieee80211AssociationRequest,
                        encode_header(request)).listen_interval == 10

    response = Ieee80211AssociationResponse(status_code = IEEE80211_STATUS_SUCCESS,
                                            association_id = UInt16(0xc001),
                                            elements = [rates])
    # The association identifier is fourteen bits with the top two bits set.
    @test hex25(encode_header(response)[1:6]) == "00 00 00 00 c0 01"
    @test decode_header(Ieee80211AssociationResponse,
                        encode_header(response)).association_id == 0xc001

    reassociation = Ieee80211ReassociationRequest(
        current_access_point = MacAddress("0a:00:00:00:00:01"), elements = [ssid])
    @test chunk_length(reassociation) == Bytes(2 + 2 + 6 + 5)
    @test decode_header(Ieee80211ReassociationRequest,
                        encode_header(reassociation)).current_access_point ==
          MacAddress("0a:00:00:00:00:01")

    # A probe request has no fixed fields at all — clause 9.3.3.9.
    probe = Ieee80211ProbeRequest(elements = [ssid, rates])
    @test chunk_length(probe) == Bytes(5 + 4)
    @test Base.length(decode_header(Ieee80211ProbeRequest,
                                    encode_header(probe)).elements) == 2

    for (T, reason) in ((Ieee80211Disassociation, IEEE80211_REASON_LEAVING),
                        (Ieee80211Deauthentication, IEEE80211_REASON_INACTIVITY))
        small = T(reason_code = UInt16(reason))
        @test chunk_length(small) == Bytes(2)
        @test decode_header(T, encode_header(small)).reason_code == reason
    end

    # ---------- the algorithm INET does not keep, clause 9.3.3.12 ----------
    # INET writes a constant zero here, so a Shared Key frame comes back from
    # its serializer as an Open System one.
    shared = Ieee80211Authentication(algorithm = IEEE80211_AUTHENTICATION_SHARED_KEY,
                                     sequence_number = UInt16(2),
                                     elements = [Ieee80211ElementRaw(
                                         id = 16, value = fill(0xaa, 4))])
    @test hex25(encode_header(shared)[1:6]) == "00 01 00 02 00 00"
    shared_back = decode_header(Ieee80211Authentication, encode_header(shared))
    @test shared_back.algorithm == IEEE80211_AUTHENTICATION_SHARED_KEY
    @test shared_back.sequence_number == 2
    @test shared_back.elements[1].value == Octets(fill(0xaa, 4))
end
